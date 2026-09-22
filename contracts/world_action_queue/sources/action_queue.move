/// Canonical blockchain queue shared by Smart Assemblies and the game server.
///
/// Every assembly owns a deterministic queue root. Actions are derived below
/// that root by a 16-byte action ID, so unrelated assemblies never contend on
/// one shared registry object while enqueueing work.
/// Payload commitments are SHA-256 digests verified by clients and the server;
/// Move stores the digest and bounded payload without interpreting its encoding.
module world_action_queue::action_queue;

use std::hash;
use sui::{clock::Clock, derived_object, event};
use world::access::{Self, OwnerCap, ServerAddressRegistry};

#[error(code = 0)]
const ENotAssemblyOwner: vector<u8> = b"OwnerCap does not authorize this assembly action";
#[error(code = 1)]
const EActionIdInvalid: vector<u8> = b"Action ID must be exactly 16 bytes";
#[error(code = 2)]
const EActionPayloadInvalid: vector<u8> = b"Action type, payload, or commitment is invalid";
#[error(code = 3)]
const EActionPriorityInvalid: vector<u8> = b"Action priority or priority flags are invalid";
#[error(code = 4)]
const EActionExpiryInvalid: vector<u8> = b"Action expiry is invalid";
#[error(code = 5)]
const EActionStateInvalid: vector<u8> = b"Action is not in the required state";
#[error(code = 6)]
const EActionClaimInvalid: vector<u8> = b"Action claim duration or claimant is invalid";
#[error(code = 7)]
const EServerUnauthorized: vector<u8> = b"Action requires an authorized world server";
#[error(code = 8)]
const EQueueMismatch: vector<u8> = b"Action queue does not match this assembly or registry";

const ACTION_ID_LENGTH: u64 = 16;
const ACTION_COMMITMENT_LENGTH: u64 = 32;
const ACTION_TYPE_MAX_LENGTH: u64 = 96;
const ACTION_PAYLOAD_MAX_LENGTH: u64 = 16_384;
const ACTION_OUTCOME_MAX_LENGTH: u64 = 16_384;
const ACTION_MAX_TTL_MS: u64 = 7 * 24 * 60 * 60 * 1000;
const ACTION_MAX_CLAIM_TTL_MS: u64 = 5 * 60 * 1000;

const PRIORITY_BACKGROUND: u64 = 0;
const PRIORITY_NORMAL: u64 = 100;
const PRIORITY_HIGH: u64 = 200;
const PRIORITY_CRITICAL: u64 = 300;
const PRIORITY_FLAG_MASK: u64 = 511;

const ACTION_QUEUED: u8 = 0;
const ACTION_CLAIMED: u8 = 1;
const ACTION_FULFILLED: u8 = 2;
const ACTION_FAILED: u8 = 3;
const ACTION_CANCELLED: u8 = 4;

public struct ActionKey has copy, drop, store { action_id: vector<u8> }

public struct AssemblyQueueKey has copy, drop, store { assembly_id: ID }

public struct ActionQueueRegistry has key { id: UID }

/// Per-assembly write root. The package registry is touched only once when the
/// queue is created; all subsequent action claims mutate this object instead.
public struct AssemblyActionQueue has key {
    id: UID,
    registry_id: ID,
    assembly_id: ID,
}

public struct Action has key {
    id: UID,
    registry_id: ID,
    queue_id: ID,
    action_id: vector<u8>,
    source_assembly_id: ID,
    target_assembly_id: ID,
    creator: address,
    action_type: vector<u8>,
    payload: vector<u8>,
    payload_commitment: vector<u8>,
    priority: u64,
    priority_flags: u64,
    created_at_ms: u64,
    expires_at_ms: u64,
    status: u8,
    revision: u64,
    claimed_by: address,
    claim_expires_at_ms: u64,
    outcome: vector<u8>,
    receipt_commitment: vector<u8>,
    server_action: bool,
}

public struct ActionQueued has copy, drop {
    action_object_id: ID,
    registry_id: ID,
    queue_id: ID,
    action_id: vector<u8>,
    source_assembly_id: ID,
    target_assembly_id: ID,
    creator: address,
    action_type: vector<u8>,
    payload_commitment: vector<u8>,
    priority: u64,
    priority_flags: u64,
    created_at_ms: u64,
    expires_at_ms: u64,
    server_action: bool,
}

public struct AssemblyActionQueueCreated has copy, drop {
    queue_id: ID,
    registry_id: ID,
    assembly_id: ID,
    creator: address,
    server_created: bool,
}

public struct ActionTransitioned has copy, drop {
    action_object_id: ID,
    action_id: vector<u8>,
    actor: address,
    status: u8,
    revision: u64,
    at_ms: u64,
}

/// Immutable completion evidence emitted after the claimed action reaches a
/// fulfilled or failed terminal state.
public struct ActionReceipt has copy, drop {
    action_object_id: ID,
    action_id: vector<u8>,
    actor: address,
    succeeded: bool,
    outcome_commitment: vector<u8>,
    revision: u64,
    completed_at_ms: u64,
}

fun init(ctx: &mut TxContext) {
    transfer::share_object(ActionQueueRegistry { id: object::new(ctx) });
}

#[test_only]
public fun init_for_testing(ctx: &mut TxContext) {
    init(ctx);
}

public fun registry_id(registry: &ActionQueueRegistry): ID {
    object::id(registry)
}

public fun queue_key(assembly_id: ID): AssemblyQueueKey {
    AssemblyQueueKey { assembly_id }
}

public fun queue_object_id(registry: &ActionQueueRegistry, assembly_id: ID): ID {
    object::id_from_address(
        derived_object::derive_address(object::id(registry), queue_key(assembly_id)),
    )
}

public fun create_queue<T: key>(
    registry: &mut ActionQueueRegistry,
    assembly_id: ID,
    owner_cap: &OwnerCap<T>,
    ctx: &mut TxContext,
) {
    assert!(access::is_authorized(owner_cap, assembly_id), ENotAssemblyOwner);
    create_queue_internal(registry, assembly_id, false, ctx);
}

public fun create_server_queue(
    registry: &mut ActionQueueRegistry,
    server_registry: &ServerAddressRegistry,
    assembly_id: ID,
    ctx: &mut TxContext,
) {
    assert_server(server_registry, ctx);
    create_queue_internal(registry, assembly_id, true, ctx);
}

fun create_queue_internal(
    registry: &mut ActionQueueRegistry,
    assembly_id: ID,
    server_created: bool,
    ctx: &mut TxContext,
) {
    let registry_id = object::id(registry);
    let uid = derived_object::claim(&mut registry.id, queue_key(assembly_id));
    let queue_id = object::uid_to_inner(&uid);
    event::emit(AssemblyActionQueueCreated {
        queue_id,
        registry_id,
        assembly_id,
        creator: ctx.sender(),
        server_created,
    });
    transfer::share_object(AssemblyActionQueue { id: uid, registry_id, assembly_id });
}

public fun action_key(action_id: vector<u8>): ActionKey {
    ActionKey { action_id }
}

public fun action_object_id(queue: &AssemblyActionQueue, action_id: vector<u8>): ID {
    object::id_from_address(
        derived_object::derive_address(object::id(queue), action_key(action_id)),
    )
}

/// Queue an action authorized by the source assembly owner.
public fun queue_action<T: key>(
    queue: &mut AssemblyActionQueue,
    target_assembly_id: ID,
    source_owner_cap: &OwnerCap<T>,
    action_id: vector<u8>,
    action_type: vector<u8>,
    payload: vector<u8>,
    payload_commitment: vector<u8>,
    priority: u64,
    priority_flags: u64,
    expires_at_ms: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(access::is_authorized(source_owner_cap, queue.assembly_id), ENotAssemblyOwner);
    create_action(
        queue,
        target_assembly_id,
        action_id,
        action_type,
        payload,
        payload_commitment,
        priority,
        priority_flags,
        expires_at_ms,
        false,
        clock,
        ctx,
    );
}

/// Queue a world-observed action from an authorized server address.
public fun queue_server_action(
    queue: &mut AssemblyActionQueue,
    server_registry: &ServerAddressRegistry,
    target_assembly_id: ID,
    action_id: vector<u8>,
    action_type: vector<u8>,
    payload: vector<u8>,
    payload_commitment: vector<u8>,
    priority: u64,
    priority_flags: u64,
    expires_at_ms: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(
        access::is_authorized_server_address(server_registry, ctx.sender()),
        EServerUnauthorized,
    );
    create_action(
        queue,
        target_assembly_id,
        action_id,
        action_type,
        payload,
        payload_commitment,
        priority,
        priority_flags,
        expires_at_ms,
        true,
        clock,
        ctx,
    );
}

fun create_action(
    queue: &mut AssemblyActionQueue,
    target_assembly_id: ID,
    action_id: vector<u8>,
    action_type: vector<u8>,
    payload: vector<u8>,
    payload_commitment: vector<u8>,
    priority: u64,
    priority_flags: u64,
    expires_at_ms: u64,
    server_action: bool,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(action_id.length() == ACTION_ID_LENGTH, EActionIdInvalid);
    assert!(
        !action_type.is_empty() && action_type.length() <= ACTION_TYPE_MAX_LENGTH &&
            payload.length() <= ACTION_PAYLOAD_MAX_LENGTH &&
            payload_commitment.length() == ACTION_COMMITMENT_LENGTH,
        EActionPayloadInvalid,
    );
    assert!(
        valid_priority(priority) && priority_flags <= PRIORITY_FLAG_MASK,
        EActionPriorityInvalid,
    );
    let created_at_ms = clock.timestamp_ms();
    assert!(
        expires_at_ms > created_at_ms && expires_at_ms - created_at_ms <= ACTION_MAX_TTL_MS,
        EActionExpiryInvalid,
    );
    let uid = derived_object::claim(&mut queue.id, action_key(copy action_id));
    let action_object_id = object::uid_to_inner(&uid);
    let registry_id = queue.registry_id;
    let queue_id = object::id(queue);
    let source_assembly_id = queue.assembly_id;
    let creator = ctx.sender();
    event::emit(ActionQueued {
        action_object_id,
        registry_id,
        queue_id,
        action_id: copy action_id,
        source_assembly_id,
        target_assembly_id,
        creator,
        action_type: copy action_type,
        payload_commitment: copy payload_commitment,
        priority,
        priority_flags,
        created_at_ms,
        expires_at_ms,
        server_action,
    });
    transfer::share_object(Action {
        id: uid,
        registry_id,
        queue_id,
        action_id,
        source_assembly_id,
        target_assembly_id,
        creator,
        action_type,
        payload,
        payload_commitment,
        priority,
        priority_flags,
        created_at_ms,
        expires_at_ms,
        status: ACTION_QUEUED,
        revision: 1,
        claimed_by: @0x0,
        claim_expires_at_ms: 0,
        outcome: vector[],
        receipt_commitment: vector[],
        server_action,
    });
}

public fun claim_action<T: key>(
    action: &mut Action,
    target_owner_cap: &OwnerCap<T>,
    claim_ttl_ms: u64,
    clock: &Clock,
    ctx: &TxContext,
) {
    assert!(access::is_authorized(target_owner_cap, action.target_assembly_id), ENotAssemblyOwner);
    claim(action, claim_ttl_ms, clock, ctx.sender());
}

public fun claim_server_action(
    action: &mut Action,
    server_registry: &ServerAddressRegistry,
    claim_ttl_ms: u64,
    clock: &Clock,
    ctx: &TxContext,
) {
    assert_server(server_registry, ctx);
    claim(action, claim_ttl_ms, clock, ctx.sender());
}

fun claim(action: &mut Action, claim_ttl_ms: u64, clock: &Clock, actor: address) {
    let at_ms = clock.timestamp_ms();
    assert!(at_ms < action.expires_at_ms, EActionExpiryInvalid);
    if (
        action.status == ACTION_CLAIMED && action.claimed_by == actor &&
            action.claim_expires_at_ms > at_ms
    ) {
        return
    };
    if (action.status == ACTION_CLAIMED && action.claim_expires_at_ms <= at_ms) {
        action.status = ACTION_QUEUED;
        action.claimed_by = @0x0;
        action.claim_expires_at_ms = 0;
    };
    assert!(action.status == ACTION_QUEUED, EActionStateInvalid);
    assert!(
        claim_ttl_ms > 0 && claim_ttl_ms <= ACTION_MAX_CLAIM_TTL_MS &&
            claim_ttl_ms <= action.expires_at_ms - at_ms,
        EActionClaimInvalid,
    );
    action.status = ACTION_CLAIMED;
    action.claimed_by = actor;
    action.claim_expires_at_ms = at_ms + claim_ttl_ms;
    action.revision = action.revision + 1;
    emit_transition(action, actor, at_ms);
}

public fun release_action<T: key>(
    action: &mut Action,
    target_owner_cap: &OwnerCap<T>,
    clock: &Clock,
    ctx: &TxContext,
) {
    assert!(access::is_authorized(target_owner_cap, action.target_assembly_id), ENotAssemblyOwner);
    release(action, clock, ctx.sender());
}

public fun release_server_action(
    action: &mut Action,
    server_registry: &ServerAddressRegistry,
    clock: &Clock,
    ctx: &TxContext,
) {
    assert_server(server_registry, ctx);
    release(action, clock, ctx.sender());
}

fun release(action: &mut Action, clock: &Clock, actor: address) {
    assert!(action.status == ACTION_CLAIMED && action.claimed_by == actor, EActionClaimInvalid);
    action.status = ACTION_QUEUED;
    action.claimed_by = @0x0;
    action.claim_expires_at_ms = 0;
    action.revision = action.revision + 1;
    emit_transition(action, actor, clock.timestamp_ms());
}

public fun complete_action<T: key>(
    action: &mut Action,
    target_owner_cap: &OwnerCap<T>,
    succeeded: bool,
    outcome: vector<u8>,
    clock: &Clock,
    ctx: &TxContext,
) {
    assert!(access::is_authorized(target_owner_cap, action.target_assembly_id), ENotAssemblyOwner);
    complete(action, succeeded, outcome, clock, ctx.sender());
}

public fun complete_server_action(
    action: &mut Action,
    server_registry: &ServerAddressRegistry,
    succeeded: bool,
    outcome: vector<u8>,
    clock: &Clock,
    ctx: &TxContext,
) {
    assert_server(server_registry, ctx);
    complete(action, succeeded, outcome, clock, ctx.sender());
}

fun complete(
    action: &mut Action,
    succeeded: bool,
    outcome: vector<u8>,
    clock: &Clock,
    actor: address,
) {
    let completed_at_ms = clock.timestamp_ms();
    assert!(
        action.status == ACTION_CLAIMED && action.claimed_by == actor &&
            completed_at_ms < action.claim_expires_at_ms &&
            completed_at_ms < action.expires_at_ms,
        EActionClaimInvalid,
    );
    assert!(outcome.length() <= ACTION_OUTCOME_MAX_LENGTH, EActionPayloadInvalid);
    let receipt_commitment = hash::sha2_256(copy outcome);
    action.status = if (succeeded) ACTION_FULFILLED else ACTION_FAILED;
    action.outcome = outcome;
    action.receipt_commitment = copy receipt_commitment;
    action.claimed_by = @0x0;
    action.claim_expires_at_ms = 0;
    action.revision = action.revision + 1;
    event::emit(ActionReceipt {
        action_object_id: object::id(action),
        action_id: copy action.action_id,
        actor,
        succeeded,
        outcome_commitment: receipt_commitment,
        revision: action.revision,
        completed_at_ms,
    });
    emit_transition(action, actor, completed_at_ms);
}

public fun cancel_action<T: key>(
    action: &mut Action,
    source_owner_cap: &OwnerCap<T>,
    clock: &Clock,
    ctx: &TxContext,
) {
    assert!(access::is_authorized(source_owner_cap, action.source_assembly_id), ENotAssemblyOwner);
    let at_ms = clock.timestamp_ms();
    assert!(
        action.status == ACTION_QUEUED ||
            (action.status == ACTION_CLAIMED && action.claim_expires_at_ms <= at_ms),
        EActionStateInvalid,
    );
    action.status = ACTION_CANCELLED;
    action.claimed_by = @0x0;
    action.claim_expires_at_ms = 0;
    action.revision = action.revision + 1;
    emit_transition(action, ctx.sender(), at_ms);
}

fun assert_server(server_registry: &ServerAddressRegistry, ctx: &TxContext) {
    assert!(
        access::is_authorized_server_address(server_registry, ctx.sender()),
        EServerUnauthorized,
    );
}

fun emit_transition(action: &Action, actor: address, at_ms: u64) {
    event::emit(ActionTransitioned {
        action_object_id: object::id(action),
        action_id: copy action.action_id,
        actor,
        status: action.status,
        revision: action.revision,
        at_ms,
    });
}

fun valid_priority(priority: u64): bool {
    priority == PRIORITY_BACKGROUND || priority == PRIORITY_NORMAL ||
        priority == PRIORITY_HIGH || priority == PRIORITY_CRITICAL
}

public fun id(action: &Action): ID { object::id(action) }

public fun action_registry_id(action: &Action): ID { action.registry_id }

public fun action_queue_id(action: &Action): ID { action.queue_id }

public fun queue_registry_id(queue: &AssemblyActionQueue): ID { queue.registry_id }

public fun queue_assembly_id(queue: &AssemblyActionQueue): ID { queue.assembly_id }

public fun assert_action_queue(action: &Action, queue: &AssemblyActionQueue) {
    assert!(
        action.queue_id == object::id(queue) && action.registry_id == queue.registry_id &&
            action.source_assembly_id == queue.assembly_id,
        EQueueMismatch,
    );
}

public fun action_id(action: &Action): vector<u8> { action.action_id }

public fun source(action: &Action): ID { action.source_assembly_id }

public fun target(action: &Action): ID { action.target_assembly_id }

public fun creator(action: &Action): address { action.creator }

public fun action_type(action: &Action): &vector<u8> { &action.action_type }

public fun payload(action: &Action): &vector<u8> { &action.payload }

public fun payload_commitment(action: &Action): &vector<u8> { &action.payload_commitment }

public fun priority(action: &Action): u64 { action.priority }

public fun priority_flags(action: &Action): u64 { action.priority_flags }

public fun created_at_ms(action: &Action): u64 { action.created_at_ms }

public fun expires_at_ms(action: &Action): u64 { action.expires_at_ms }

public fun status(action: &Action): u8 { action.status }

public fun revision(action: &Action): u64 { action.revision }

public fun claimed_by(action: &Action): address { action.claimed_by }

public fun claim_expires_at_ms(action: &Action): u64 { action.claim_expires_at_ms }

public fun outcome(action: &Action): &vector<u8> { &action.outcome }

public fun receipt_commitment(action: &Action): &vector<u8> { &action.receipt_commitment }

public fun is_server_authored(action: &Action): bool { action.server_action }

public fun background_priority(): u64 { PRIORITY_BACKGROUND }

public fun normal_priority(): u64 { PRIORITY_NORMAL }

public fun high_priority(): u64 { PRIORITY_HIGH }

public fun critical_priority(): u64 { PRIORITY_CRITICAL }

public fun priority_flag_mask(): u64 { PRIORITY_FLAG_MASK }

public fun queued_status(): u8 { ACTION_QUEUED }

public fun claimed_status(): u8 { ACTION_CLAIMED }

public fun fulfilled_status(): u8 { ACTION_FULFILLED }

public fun failed_status(): u8 { ACTION_FAILED }

public fun cancelled_status(): u8 { ACTION_CANCELLED }
