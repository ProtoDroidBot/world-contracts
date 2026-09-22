/// Bounded Smart Assembly workflows advanced by an authorized keeper.
///
/// Sui records definitions, dependency state, deadlines, retry policy, and
/// signal predicates. Time passing never executes a step by itself: a world
/// server/keeper must evaluate a signal and explicitly advance the workflow.
module world_automation::automation;

use std::option::{Self, Option};
use std::hash;
use sui::{clock::Clock, derived_object, event};
use world::access::{Self, OwnerCap, ServerAddressRegistry};
use world_action_queue::action_queue::{Self, Action, AssemblyActionQueue};

#[error(code = 0)]
const ENotAssemblyOwner: vector<u8> = b"OwnerCap does not authorize this automation root";
#[error(code = 1)]
const EAutomationInvalid: vector<u8> = b"Automation definition or identifier is invalid";
#[error(code = 2)]
const EStepInvalid: vector<u8> = b"Automation step, dependency, deadline, or retry policy is invalid";
#[error(code = 3)]
const EStateInvalid: vector<u8> = b"Automation or step is not in the required state";
#[error(code = 4)]
const ESignalUnsatisfied: vector<u8> = b"Automation signal predicate is not satisfied";
#[error(code = 5)]
const EActionMismatch: vector<u8> = b"Automation step does not match the supplied Action";
#[error(code = 6)]
const EServerUnauthorized: vector<u8> = b"Automation advancement requires an authorized world server";
#[error(code = 7)]
const ERootMismatch: vector<u8> = b"Automation and action roots do not describe the same assembly";

const AUTOMATION_ID_LENGTH: u64 = 16;
const COMMITMENT_LENGTH: u64 = 32;
const MAX_STEPS: u64 = 32;
const MAX_DEPENDENCIES: u64 = 16;
const MAX_ACTION_TYPE_LENGTH: u64 = 96;
const MAX_PAYLOAD_LENGTH: u64 = 16_384;
const MAX_SIGNAL_TYPE_LENGTH: u64 = 96;
const MAX_ATTEMPTS: u8 = 10;
const MAX_DURATION_MS: u64 = 30 * 24 * 60 * 60 * 1000;

const PREDICATE_NONE: u8 = 0;
const PREDICATE_EXISTS: u8 = 1;
const PREDICATE_EQUALS: u8 = 2;
const PREDICATE_GTE: u8 = 3;

const AUTOMATION_DRAFT: u8 = 0;
const AUTOMATION_ACTIVE: u8 = 1;
const AUTOMATION_PAUSED: u8 = 2;
const AUTOMATION_SUCCEEDED: u8 = 3;
const AUTOMATION_FAILED: u8 = 4;
const AUTOMATION_CANCELLED: u8 = 5;

const STEP_PENDING: u8 = 0;
const STEP_QUEUED: u8 = 1;
const STEP_RETRY_WAIT: u8 = 2;
const STEP_SUCCEEDED: u8 = 3;
const STEP_FAILED: u8 = 4;

public struct AssemblyAutomationRootKey has copy, drop, store { assembly_id: ID }
public struct AutomationKey has copy, drop, store { automation_id: vector<u8> }

public struct AutomationRegistry has key { id: UID }

public struct AssemblyAutomationRoot has key {
    id: UID,
    registry_id: ID,
    assembly_id: ID,
}

public struct SignalPredicate has drop, store {
    kind: u8,
    signal_type: vector<u8>,
    value_commitment: vector<u8>,
    threshold: u64,
}

public struct AutomationStep has drop, store {
    target_assembly_id: ID,
    action_type: vector<u8>,
    payload: vector<u8>,
    payload_commitment: vector<u8>,
    dependencies: vector<u8>,
    not_before_offset_ms: u64,
    deadline_offset_ms: u64,
    max_attempts: u8,
    retry_delay_ms: u64,
    predicate: SignalPredicate,
    priority: u64,
    priority_flags: u64,
}

public struct StepRuntime has drop, store {
    status: u8,
    attempts: u8,
    next_eligible_at_ms: u64,
    action_id: Option<ID>,
}

public struct Automation has key {
    id: UID,
    registry_id: ID,
    root_id: ID,
    assembly_id: ID,
    automation_id: vector<u8>,
    creator: address,
    duration_ms: u64,
    created_at_ms: u64,
    started_at_ms: u64,
    deadline_at_ms: u64,
    status: u8,
    revision: u64,
    steps: vector<AutomationStep>,
    runtime: vector<StepRuntime>,
}

public struct AssemblyAutomationRootCreated has copy, drop {
    root_id: ID,
    registry_id: ID,
    assembly_id: ID,
    creator: address,
}

public struct AutomationCreated has copy, drop {
    automation_object_id: ID,
    assembly_id: ID,
    automation_id: vector<u8>,
    step_count: u64,
    duration_ms: u64,
}

public struct AutomationTransitioned has copy, drop {
    automation_object_id: ID,
    actor: address,
    status: u8,
    revision: u64,
    at_ms: u64,
}

public struct AutomationStepQueued has copy, drop {
    automation_object_id: ID,
    step_index: u64,
    action_object_id: ID,
    attempt: u8,
    actor: address,
    at_ms: u64,
}

public struct AutomationStepTransitioned has copy, drop {
    automation_object_id: ID,
    step_index: u64,
    action_object_id: ID,
    status: u8,
    attempt: u8,
    actor: address,
    at_ms: u64,
}

fun init(ctx: &mut TxContext) {
    transfer::share_object(AutomationRegistry { id: object::new(ctx) });
}

#[test_only]
public fun init_for_testing(ctx: &mut TxContext) { init(ctx); }

public fun root_key(assembly_id: ID): AssemblyAutomationRootKey {
    AssemblyAutomationRootKey { assembly_id }
}

public fun automation_key(automation_id: vector<u8>): AutomationKey {
    AutomationKey { automation_id }
}

public fun root_object_id(registry: &AutomationRegistry, assembly_id: ID): ID {
    object::id_from_address(derived_object::derive_address(object::id(registry), root_key(assembly_id)))
}

public fun automation_object_id(root: &AssemblyAutomationRoot, automation_id: vector<u8>): ID {
    object::id_from_address(derived_object::derive_address(object::id(root), automation_key(automation_id)))
}

public fun create_root<T: key>(
    registry: &mut AutomationRegistry,
    assembly_id: ID,
    owner_cap: &OwnerCap<T>,
    ctx: &mut TxContext,
) {
    assert!(access::is_authorized(owner_cap, assembly_id), ENotAssemblyOwner);
    let registry_id = object::id(registry);
    let uid = derived_object::claim(&mut registry.id, root_key(assembly_id));
    let root_id = object::uid_to_inner(&uid);
    event::emit(AssemblyAutomationRootCreated {
        root_id,
        registry_id,
        assembly_id,
        creator: ctx.sender(),
    });
    transfer::share_object(AssemblyAutomationRoot { id: uid, registry_id, assembly_id });
}

public fun no_signal(): SignalPredicate {
    SignalPredicate { kind: PREDICATE_NONE, signal_type: vector[], value_commitment: vector[], threshold: 0 }
}

public fun signal_exists(signal_type: vector<u8>): SignalPredicate {
    let predicate = SignalPredicate {
        kind: PREDICATE_EXISTS,
        signal_type,
        value_commitment: vector[],
        threshold: 0,
    };
    validate_predicate(&predicate);
    predicate
}

public fun signal_equals(signal_type: vector<u8>, value_commitment: vector<u8>): SignalPredicate {
    let predicate = SignalPredicate {
        kind: PREDICATE_EQUALS,
        signal_type,
        value_commitment,
        threshold: 0,
    };
    validate_predicate(&predicate);
    predicate
}

public fun signal_gte(signal_type: vector<u8>, threshold: u64): SignalPredicate {
    let predicate = SignalPredicate {
        kind: PREDICATE_GTE,
        signal_type,
        value_commitment: vector[],
        threshold,
    };
    validate_predicate(&predicate);
    predicate
}

public fun new_step(
    target_assembly_id: ID,
    action_type: vector<u8>,
    payload: vector<u8>,
    dependencies: vector<u8>,
    not_before_offset_ms: u64,
    deadline_offset_ms: u64,
    max_attempts: u8,
    retry_delay_ms: u64,
    predicate: SignalPredicate,
    priority: u64,
    priority_flags: u64,
): AutomationStep {
    let payload_commitment = hash::sha2_256(copy payload);
    AutomationStep {
        target_assembly_id,
        action_type,
        payload,
        payload_commitment,
        dependencies,
        not_before_offset_ms,
        deadline_offset_ms,
        max_attempts,
        retry_delay_ms,
        predicate,
        priority,
        priority_flags,
    }
}

public fun create_automation<T: key>(
    root: &mut AssemblyAutomationRoot,
    owner_cap: &OwnerCap<T>,
    automation_id: vector<u8>,
    duration_ms: u64,
    steps: vector<AutomationStep>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(access::is_authorized(owner_cap, root.assembly_id), ENotAssemblyOwner);
    assert!(
        automation_id.length() == AUTOMATION_ID_LENGTH && duration_ms > 0 &&
            duration_ms <= MAX_DURATION_MS && !steps.is_empty() && steps.length() <= MAX_STEPS,
        EAutomationInvalid,
    );
    validate_steps(&steps, duration_ms);
    let step_count = steps.length();
    let mut runtime = vector[];
    let mut i = 0;
    while (i < step_count) {
        runtime.push_back(StepRuntime {
            status: STEP_PENDING,
            attempts: 0,
            next_eligible_at_ms: 0,
            action_id: option::none(),
        });
        i = i + 1;
    };
    let uid = derived_object::claim(&mut root.id, automation_key(copy automation_id));
    let automation_object_id = object::uid_to_inner(&uid);
    let created_at_ms = clock.timestamp_ms();
    event::emit(AutomationCreated {
        automation_object_id,
        assembly_id: root.assembly_id,
        automation_id: copy automation_id,
        step_count,
        duration_ms,
    });
    transfer::share_object(Automation {
        id: uid,
        registry_id: root.registry_id,
        root_id: object::id(root),
        assembly_id: root.assembly_id,
        automation_id,
        creator: ctx.sender(),
        duration_ms,
        created_at_ms,
        started_at_ms: 0,
        deadline_at_ms: 0,
        status: AUTOMATION_DRAFT,
        revision: 1,
        steps,
        runtime,
    });
}

public fun activate<T: key>(
    automation: &mut Automation,
    owner_cap: &OwnerCap<T>,
    clock: &Clock,
    ctx: &TxContext,
) {
    assert_owner(automation, owner_cap);
    assert!(automation.status == AUTOMATION_DRAFT, EStateInvalid);
    let now = clock.timestamp_ms();
    automation.started_at_ms = now;
    automation.deadline_at_ms = now + automation.duration_ms;
    automation.status = AUTOMATION_ACTIVE;
    transition(automation, now, ctx.sender());
}

public fun pause<T: key>(automation: &mut Automation, owner_cap: &OwnerCap<T>, clock: &Clock, ctx: &TxContext) {
    assert_owner(automation, owner_cap);
    assert!(automation.status == AUTOMATION_ACTIVE, EStateInvalid);
    automation.status = AUTOMATION_PAUSED;
    transition(automation, clock.timestamp_ms(), ctx.sender());
}

public fun resume<T: key>(automation: &mut Automation, owner_cap: &OwnerCap<T>, clock: &Clock, ctx: &TxContext) {
    assert_owner(automation, owner_cap);
    assert!(automation.status == AUTOMATION_PAUSED && clock.timestamp_ms() <= automation.deadline_at_ms, EStateInvalid);
    automation.status = AUTOMATION_ACTIVE;
    transition(automation, clock.timestamp_ms(), ctx.sender());
}

public fun cancel<T: key>(automation: &mut Automation, owner_cap: &OwnerCap<T>, clock: &Clock, ctx: &TxContext) {
    assert_owner(automation, owner_cap);
    assert!(automation.status == AUTOMATION_DRAFT || automation.status == AUTOMATION_ACTIVE || automation.status == AUTOMATION_PAUSED, EStateInvalid);
    automation.status = AUTOMATION_CANCELLED;
    transition(automation, clock.timestamp_ms(), ctx.sender());
}

/// Evaluate one ready step and queue it. A keeper must call this function;
/// deadlines and delays are constraints, not autonomous timers.
public fun advance(
    automation: &mut Automation,
    queue: &mut AssemblyActionQueue,
    server_registry: &ServerAddressRegistry,
    step_index: u64,
    action_id: vector<u8>,
    observed_signal_type: vector<u8>,
    observed_value_commitment: vector<u8>,
    observed_value: u64,
    expires_at_ms: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert_server(server_registry, ctx);
    assert!(automation.status == AUTOMATION_ACTIVE, EStateInvalid);
    assert!(action_queue::queue_assembly_id(queue) == automation.assembly_id, ERootMismatch);
    let now = clock.timestamp_ms();
    assert!(now <= automation.deadline_at_ms && step_index < automation.steps.length(), EStepInvalid);
    let step = automation.steps.borrow(step_index);
    let runtime = automation.runtime.borrow(step_index);
    assert!(runtime.status == STEP_PENDING || runtime.status == STEP_RETRY_WAIT, EStateInvalid);
    assert!(runtime.attempts < step.max_attempts && now >= runtime.next_eligible_at_ms, EStateInvalid);
    assert!(
        now >= automation.started_at_ms + step.not_before_offset_ms &&
            now <= automation.started_at_ms + step.deadline_offset_ms &&
            expires_at_ms <= automation.started_at_ms + step.deadline_offset_ms &&
            expires_at_ms <= automation.deadline_at_ms,
        EStepInvalid,
    );
    assert_dependencies(automation, step);
    assert_signal(step, observed_signal_type, observed_value_commitment, observed_value);
    let action_object_id = action_queue::action_object_id(queue, copy action_id);
    action_queue::queue_server_action(
        queue,
        server_registry,
        step.target_assembly_id,
        action_id,
        copy step.action_type,
        copy step.payload,
        copy step.payload_commitment,
        step.priority,
        step.priority_flags,
        expires_at_ms,
        clock,
        ctx,
    );
    let automation_object_id = object::id(automation);
    let runtime = automation.runtime.borrow_mut(step_index);
    runtime.status = STEP_QUEUED;
    runtime.attempts = runtime.attempts + 1;
    runtime.action_id = option::some(action_object_id);
    automation.revision = automation.revision + 1;
    event::emit(AutomationStepQueued {
        automation_object_id,
        step_index,
        action_object_id,
        attempt: runtime.attempts,
        actor: ctx.sender(),
        at_ms: now,
    });
}

/// Project the final common Action status back into the workflow. Failed steps
/// become retryable only within their attempt and deadline bounds.
public fun record_step_result(
    automation: &mut Automation,
    step_index: u64,
    action: &Action,
    server_registry: &ServerAddressRegistry,
    clock: &Clock,
    ctx: &TxContext,
) {
    assert_server(server_registry, ctx);
    assert!(automation.status == AUTOMATION_ACTIVE && step_index < automation.steps.length(), EStateInvalid);
    let now = clock.timestamp_ms();
    let automation_object_id = object::id(automation);
    let step = automation.steps.borrow(step_index);
    let runtime = automation.runtime.borrow_mut(step_index);
    assert!(runtime.status == STEP_QUEUED && runtime.action_id.contains(&object::id(action)), EActionMismatch);
    let action_status = action_queue::status(action);
    assert!(
        action_status == action_queue::fulfilled_status() || action_status == action_queue::failed_status(),
        EStateInvalid,
    );
    if (action_status == action_queue::fulfilled_status()) {
        runtime.status = STEP_SUCCEEDED;
    } else if (
        runtime.attempts < step.max_attempts &&
            now + step.retry_delay_ms <= automation.started_at_ms + step.deadline_offset_ms &&
            now + step.retry_delay_ms <= automation.deadline_at_ms
    ) {
        runtime.status = STEP_RETRY_WAIT;
        runtime.next_eligible_at_ms = now + step.retry_delay_ms;
        runtime.action_id = option::none();
    } else {
        runtime.status = STEP_FAILED;
        automation.status = AUTOMATION_FAILED;
    };
    automation.revision = automation.revision + 1;
    event::emit(AutomationStepTransitioned {
        automation_object_id,
        step_index,
        action_object_id: object::id(action),
        status: runtime.status,
        attempt: runtime.attempts,
        actor: ctx.sender(),
        at_ms: now,
    });
    if (automation.status == AUTOMATION_ACTIVE && all_succeeded(&automation.runtime)) {
        automation.status = AUTOMATION_SUCCEEDED;
        transition(automation, now, ctx.sender());
    };
}

public fun expire(
    automation: &mut Automation,
    server_registry: &ServerAddressRegistry,
    clock: &Clock,
    ctx: &TxContext,
) {
    assert_server(server_registry, ctx);
    assert!(
        (automation.status == AUTOMATION_ACTIVE || automation.status == AUTOMATION_PAUSED) &&
            clock.timestamp_ms() > automation.deadline_at_ms,
        EStateInvalid,
    );
    automation.status = AUTOMATION_FAILED;
    transition(automation, clock.timestamp_ms(), ctx.sender());
}

fun validate_steps(steps: &vector<AutomationStep>, duration_ms: u64) {
    let mut i = 0;
    while (i < steps.length()) {
        let step = steps.borrow(i);
        assert!(
            !step.action_type.is_empty() && step.action_type.length() <= MAX_ACTION_TYPE_LENGTH &&
                step.payload.length() <= MAX_PAYLOAD_LENGTH &&
                step.payload_commitment.length() == COMMITMENT_LENGTH &&
                step.dependencies.length() <= MAX_DEPENDENCIES &&
                step.not_before_offset_ms <= step.deadline_offset_ms &&
                step.deadline_offset_ms <= duration_ms && step.max_attempts > 0 &&
                step.max_attempts <= MAX_ATTEMPTS,
            EStepInvalid,
        );
        validate_predicate(&step.predicate);
        let mut dependency_index = 0;
        while (dependency_index < step.dependencies.length()) {
            let dependency = *step.dependencies.borrow(dependency_index) as u64;
            assert!(dependency < i, EStepInvalid);
            let mut prior = 0;
            while (prior < dependency_index) {
                assert!(*step.dependencies.borrow(prior) != dependency as u8, EStepInvalid);
                prior = prior + 1;
            };
            dependency_index = dependency_index + 1;
        };
        i = i + 1;
    };
}

fun validate_predicate(predicate: &SignalPredicate) {
    assert!(predicate.kind <= PREDICATE_GTE, EStepInvalid);
    if (predicate.kind == PREDICATE_NONE) {
        assert!(predicate.signal_type.is_empty() && predicate.value_commitment.is_empty() && predicate.threshold == 0, EStepInvalid);
    } else if (predicate.kind == PREDICATE_EXISTS) {
        assert!(!predicate.signal_type.is_empty() && predicate.signal_type.length() <= MAX_SIGNAL_TYPE_LENGTH && predicate.value_commitment.is_empty() && predicate.threshold == 0, EStepInvalid);
    } else if (predicate.kind == PREDICATE_EQUALS) {
        assert!(!predicate.signal_type.is_empty() && predicate.signal_type.length() <= MAX_SIGNAL_TYPE_LENGTH && predicate.value_commitment.length() == COMMITMENT_LENGTH && predicate.threshold == 0, EStepInvalid);
    } else {
        assert!(!predicate.signal_type.is_empty() && predicate.signal_type.length() <= MAX_SIGNAL_TYPE_LENGTH && predicate.value_commitment.is_empty(), EStepInvalid);
    };
}

fun assert_dependencies(automation: &Automation, step: &AutomationStep) {
    let mut i = 0;
    while (i < step.dependencies.length()) {
        let dependency = *step.dependencies.borrow(i) as u64;
        assert!(automation.runtime.borrow(dependency).status == STEP_SUCCEEDED, EStateInvalid);
        i = i + 1;
    };
}

fun assert_signal(
    step: &AutomationStep,
    observed_signal_type: vector<u8>,
    observed_value_commitment: vector<u8>,
    observed_value: u64,
) {
    let predicate = &step.predicate;
    let satisfied = if (predicate.kind == PREDICATE_NONE) {
        observed_signal_type.is_empty() && observed_value_commitment.is_empty() && observed_value == 0
    } else if (predicate.kind == PREDICATE_EXISTS) {
        observed_signal_type == predicate.signal_type
    } else if (predicate.kind == PREDICATE_EQUALS) {
        observed_signal_type == predicate.signal_type &&
            observed_value_commitment == predicate.value_commitment
    } else {
        observed_signal_type == predicate.signal_type && observed_value >= predicate.threshold
    };
    assert!(satisfied, ESignalUnsatisfied);
}

fun all_succeeded(runtime: &vector<StepRuntime>): bool {
    let mut i = 0;
    while (i < runtime.length()) {
        if (runtime.borrow(i).status != STEP_SUCCEEDED) return false;
        i = i + 1;
    };
    true
}

fun assert_owner<T: key>(automation: &Automation, owner_cap: &OwnerCap<T>) {
    assert!(access::is_authorized(owner_cap, automation.assembly_id), ENotAssemblyOwner);
}

fun assert_server(server_registry: &ServerAddressRegistry, ctx: &TxContext) {
    assert!(access::is_authorized_server_address(server_registry, ctx.sender()), EServerUnauthorized);
}

fun transition(automation: &mut Automation, at_ms: u64, actor: address) {
    automation.revision = automation.revision + 1;
    event::emit(AutomationTransitioned {
        automation_object_id: object::id(automation),
        actor,
        status: automation.status,
        revision: automation.revision,
        at_ms,
    });
}

public fun id(automation: &Automation): ID { object::id(automation) }
public fun assembly_id(automation: &Automation): ID { automation.assembly_id }
public fun status(automation: &Automation): u8 { automation.status }
public fun revision(automation: &Automation): u64 { automation.revision }
public fun step_count(automation: &Automation): u64 { automation.steps.length() }
public fun step_status(automation: &Automation, index: u64): u8 { automation.runtime.borrow(index).status }
public fun step_attempts(automation: &Automation, index: u64): u8 { automation.runtime.borrow(index).attempts }
public fun draft_status(): u8 { AUTOMATION_DRAFT }
public fun active_status(): u8 { AUTOMATION_ACTIVE }
public fun paused_status(): u8 { AUTOMATION_PAUSED }
public fun succeeded_status(): u8 { AUTOMATION_SUCCEEDED }
public fun failed_status(): u8 { AUTOMATION_FAILED }
public fun cancelled_status(): u8 { AUTOMATION_CANCELLED }
public fun step_pending_status(): u8 { STEP_PENDING }
public fun step_queued_status(): u8 { STEP_QUEUED }
public fun step_retry_wait_status(): u8 { STEP_RETRY_WAIT }
public fun step_succeeded_status(): u8 { STEP_SUCCEEDED }
public fun step_failed_status(): u8 { STEP_FAILED }
