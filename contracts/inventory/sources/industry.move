/// One assembly module for refining and manufacturing through governed recipes.
/// Starts use owner-configured actions. Funded-job lifecycle operations use
/// module-authored requests so an owner cannot disable customer recovery.
module inventory::industry;

use core::{
    access_cap::{Self, AccessCap},
    admin_service::AdminACL,
    entity::Entity,
    mod::{Self, Module},
    request::{Request, Frame},
    requirement::{Self, Requirement}
};
use inventory::{
    industry_job::{Self, IndustryJob},
    item_type::{Self, ItemTypeRegistry},
    item_v2::{Self, ItemV2, ItemAmount},
    recipe::{Self, RecipeRegistry, RecipeRevision}
};
use std::{internal::Permit, string::String};
use sui::{bcs, clock::Clock, coin::{Self, Coin}, event, sui::SUI, table::{Self, Table}};

// === Errors ===

#[error(code = 0)]
const EWrongVersion: vector<u8> = b"Unsupported industry module version";
#[error(code = 1)]
const EWrongCatalog: vector<u8> = b"Industry catalog or admin authority does not match";
#[error(code = 2)]
const EWrongTenant: vector<u8> = b"Industry catalog belongs to another tenant";
#[error(code = 3)]
const ENotAuthorized: vector<u8> = b"AccessCap does not authorize this industry operation";
#[error(code = 4)]
const EPaused: vector<u8> = b"Industry is paused for new work";
#[error(code = 5)]
const EKindNotAllowed: vector<u8> = b"Recipe kind is not allowed on this facility";
#[error(code = 6)]
const ERecipeNotAllowed: vector<u8> = b"Recipe is excluded by the facility policy";
#[error(code = 7)]
const ENoLane: vector<u8> = b"All industry lanes are occupied";
#[error(code = 8)]
const EJobLimit: vector<u8> = b"Outstanding industry job limit reached";
#[error(code = 9)]
const EOverCapacity: vector<u8> = b"Industry input or reserved output exceeds capacity";
#[error(code = 10)]
const EOverflow: vector<u8> = b"Industry quantity exceeds u64";
#[error(code = 11)]
const EInvalidConfig: vector<u8> =
    b"Industry configuration is invalid or below existing obligations";
#[error(code = 12)]
const EJobMissing: vector<u8> = b"Industry job does not exist in this module";
#[error(code = 13)]
const EFeeTooHigh: vector<u8> = b"Industry fee exceeds caller maximum";
#[error(code = 14)]
const EOutstandingJobs: vector<u8> = b"Cannot uninstall industry with jobs or funds";
#[error(code = 15)]
const EBatchLimit: vector<u8> = b"Batch count exceeds the action limit";

// === Constants ===

const VERSION: u64 = 1;
const MAX_JOBS: u64 = 128;
const MAX_LANES: u64 = 32;
const MAX_POLICY_RECIPES: u64 = 128;
const MAX_U64: u128 = 18446744073709551615;

// === Structs ===

/// Admin-attested capabilities and capacity allocations shared across all kinds.
public struct FacilityConfig has copy, drop, store {
    type_id: u64,
    tier: u64,
    kinds: vector<u8>,
    lanes: u64,
    max_jobs: u64,
    input_capacity: u64,
    output_capacity: u64,
}

/// Owner-selected restrictions and commercial terms for new starts only.
public struct Policy has copy, drop, store {
    paused: bool,
    owner_only: bool,
    kinds: vector<u8>,
    allowed_recipes: vector<ID>,
    fee_per_batch: u64,
    fee_recipient: address,
}

/// Installed production state. No owner-controlled inventory action exposes jobs.
public struct Industry has store {
    item_registry_id: ID,
    recipe_registry_id: ID,
    admin_acl_id: ID,
    tenant: String,
    config: FacilityConfig,
    policy: Policy,
    running: u64,
    input_used: u64,
    output_used: u64,
    output_reserved: u64,
    jobs: Table<ID, IndustryJob>,
}

/// Module-owned requirement witness for this operation.
public struct Start(u64) has drop;
/// Module-owned requirement witness for this operation.
public struct Settle() has drop;
/// Module-owned requirement witness for this operation.
public struct Claim() has drop;
/// Module-owned requirement witness for this operation.
public struct Cancel() has drop;
/// Module-owned requirement witness for this operation.
public struct Refund() has drop;
/// Module-owned requirement witness for this operation.
public struct Configure() has drop;

// === Events ===

/// Event describing this committed industry change.
public struct IndustryInstalled has copy, drop {
    entity_id: ID,
    module_id: u64,
    item_registry_id: ID,
    recipe_registry_id: ID,
    config: FacilityConfig,
}

/// Event describing this committed industry change.
public struct IndustryPolicyChanged has copy, drop {
    entity_id: ID,
    module_id: u64,
    policy: Policy,
}

/// Event describing this committed industry change.
public struct IndustryLimitsChanged has copy, drop {
    entity_id: ID,
    module_id: u64,
    config: FacilityConfig,
}

/// Full canonical deltas accompany every lifecycle event for idempotent indexing.
public struct JobSummary has copy, drop, store {
    schema_version: u64,
    job_id: ID,
    entity_id: ID,
    module_id: u64,
    tenant: String,
    beneficiary: ID,
    recipe_id: ID,
    recipe_digest: vector<u8>,
    kind: u8,
    batches: u64,
    inputs: vector<ItemAmount>,
    outputs: vector<ItemAmount>,
    started_at_ms: u64,
    ready_at_ms: u64,
    fee: u64,
}

/// Event describing this committed industry change.
public struct IndustryJobStarted has copy, drop { job: JobSummary }
/// Event describing this committed industry change.
public struct IndustryJobCompleted has copy, drop { job: JobSummary }
/// Event describing this committed industry change.
public struct IndustryJobCancelled has copy, drop { job: JobSummary }
/// Event describing this committed industry change.
public struct IndustryOutputsClaimed has copy, drop { job: JobSummary }
/// Event describing this committed industry change.
public struct IndustryInputsRefunded has copy, drop { job: JobSummary }

// === Public Functions ===

/// Construct bounded facility configuration; only a verified admin installs it.
public fun facility_config(
    type_id: u64,
    tier: u64,
    kinds: vector<u8>,
    lanes: u64,
    max_jobs: u64,
    input_capacity: u64,
    output_capacity: u64,
): FacilityConfig {
    validate_kinds(&kinds);
    assert!(
        lanes > 0 && lanes <= MAX_LANES && max_jobs >= lanes && max_jobs <= MAX_JOBS,
        EInvalidConfig,
    );
    assert!(input_capacity > 0 && output_capacity > 0, EInvalidConfig);
    FacilityConfig { type_id, tier, kinds, lanes, max_jobs, input_capacity, output_capacity }
}

/// Construct a policy; set_policy proves owner access and checks facility bounds.
public fun policy(
    paused: bool,
    owner_only: bool,
    kinds: vector<u8>,
    allowed_recipes: vector<ID>,
    fee_per_batch: u64,
    fee_recipient: address,
): Policy {
    validate_kinds(&kinds);
    assert!(allowed_recipes.length() <= MAX_POLICY_RECIPES, EInvalidConfig);
    Policy { paused, owner_only, kinds, allowed_recipes, fee_per_batch, fee_recipient }
}

/// Install the unified module with explicit game authority and catalog binding.
public fun install(
    entity: &mut Entity,
    types: &ItemTypeRegistry,
    recipes: &RecipeRegistry,
    acl: &AdminACL,
    config: FacilityConfig,
    module_id: u64,
    name: Option<String>,
    ctx: &mut TxContext,
): Request {
    item_type::assert_admin(types, acl, ctx);
    assert!(
        recipe::registry_item_registry_id(recipes) == object::id(types) && recipe::admin_acl_id(recipes) == object::id(acl),
        EWrongCatalog,
    );
    assert!(item_type::tenant(types) == entity.key().tenant(), EWrongTenant);
    let default_policy = policy(false, true, config.kinds, vector[], 0, ctx.sender());
    event::emit(IndustryInstalled {
        entity_id: entity.id(),
        module_id,
        item_registry_id: object::id(types),
        recipe_registry_id: object::id(recipes),
        config,
    });
    entity.install(
        module_id,
        name,
        Industry {
            item_registry_id: object::id(types),
            recipe_registry_id: object::id(recipes),
            admin_acl_id: object::id(acl),
            tenant: item_type::tenant(types),
            config,
            policy: default_policy,
            running: 0,
            input_used: 0,
            output_used: 0,
            output_reserved: 0,
            jobs: table::new(ctx),
        },
        VERSION,
        module_permit(),
        ctx,
    )
}

/// Expose a batch-bounded start action; all economic and access checks are internal.
public fun start_requirement(module_id: u64, max_batches: u64): Requirement {
    assert!(max_batches > 0, EBatchLimit);
    requirement::from_config(option::some(module_id), Start(max_batches))
}

/// Fund an exact recipe with actual ItemV2 assets, reserving every output at start.
public fun start_job(
    entity: &mut Entity,
    req: &mut Request,
    types: &ItemTypeRegistry,
    recipes: &RecipeRegistry,
    recipe: &RecipeRevision,
    cap: &AccessCap,
    payment: &mut Coin<SUI>,
    inputs: vector<ItemV2>,
    batches: u64,
    max_fee: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): ID {
    access_cap::assert_valid(cap);
    let beneficiary = access_cap::entity(cap);
    let entity_id = entity.id();
    let module_id = req.next().module_id().destroy_or!(abort EInvalidConfig);
    let (requirement, frame, state) = take(entity, req, internal::permit<Start>());
    let max_batches = bcs::new(requirement.data()).peel_u64();
    assert!(batches > 0 && batches <= max_batches, EBatchLimit);
    assert_catalogs(state, types, recipes);
    recipe::assert_enabled(recipes, recipe, batches);
    assert!(!state.policy.paused, EPaused);
    assert!(!state.policy.owner_only || beneficiary == entity_id, ENotAuthorized);
    let kind = recipe::kind(recipe);
    assert!(
        state.config.kinds.contains(&kind) && state.policy.kinds.contains(&kind),
        EKindNotAllowed,
    );
    assert!(
        state.policy.allowed_recipes.is_empty() || state.policy.allowed_recipes.contains(&object::id(recipe)),
        ERecipeNotAllowed,
    );
    recipe::assert_facility(recipe, state.config.type_id, state.config.tier);
    assert!(state.running < state.config.lanes, ENoLane);
    assert!(state.jobs.length() < state.config.max_jobs, EJobLimit);
    let (required, produced) = recipe::amounts(recipe, batches);
    let input_volume = item_v2::total_volume(types, &required);
    let output_volume = item_v2::total_volume(types, &produced);
    assert!(sum(state.input_used, input_volume) <= state.config.input_capacity, EOverCapacity);
    assert!(
        sum(sum(state.output_used, state.output_reserved), output_volume) <= state.config.output_capacity,
        EOverCapacity,
    );
    let total_fee = (state.policy.fee_per_batch as u128) * (batches as u128);
    assert!(total_fee <= MAX_U64, EOverflow);
    assert!(total_fee <= (max_fee as u128), EFeeTooHigh);
    let fee = coin::into_balance(coin::split(payment, total_fee as u64, ctx));
    let job = industry_job::new(
        types,
        recipe,
        entity_id,
        module_id,
        beneficiary,
        batches,
        inputs,
        fee,
        state.policy.fee_recipient,
        clock,
        ctx,
    );
    let job_id = object::id(&job);
    event::emit(IndustryJobStarted { job: summary(&job) });
    state.jobs.add(job_id, job);
    state.running = state.running + 1;
    state.input_used = sum(state.input_used, input_volume);
    state.output_reserved = sum(state.output_reserved, output_volume);
    req.enqueue(frame);
    job_id
}

/// Settle a mature job without owner-controlled actions; products stay in its vault.
public fun settle_job(
    entity: &mut Entity,
    types: &ItemTypeRegistry,
    module_id: u64,
    job_id: ID,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let mut req = entity.begin_module_request(
        module_id,
        requirement::from_config(option::some(module_id), Settle()),
        module_permit(),
    );
    let (_, frame, state) = take(entity, &mut req, internal::permit<Settle>());
    assert!(object::id(types) == state.item_registry_id, EWrongCatalog);
    assert!(state.jobs.contains(job_id), EJobMissing);
    let job = &mut state.jobs[job_id];
    let input_volume = industry_job::input_volume(job);
    let output_volume = industry_job::output_volume(job);
    industry_job::settle(job, types, clock, ctx);
    event::emit(IndustryJobCompleted { job: summary(job) });
    state.running = state.running - 1;
    state.input_used = state.input_used - input_volume;
    state.output_reserved = state.output_reserved - output_volume;
    state.output_used = sum(state.output_used, output_volume);
    req.enqueue(frame);
    entity.complete_request(req);
}

/// Claim the complete product array; a failed downstream deposit rolls back the claim.
public fun claim_outputs(
    entity: &mut Entity,
    cap: &AccessCap,
    module_id: u64,
    job_id: ID,
    _ctx: &mut TxContext,
): vector<ItemV2> {
    access_cap::assert_valid(cap);
    let mut req = entity.begin_module_request(
        module_id,
        requirement::from_config(option::some(module_id), Claim()),
        module_permit(),
    );
    let (_, frame, state) = take(entity, &mut req, internal::permit<Claim>());
    assert_job_owner(state, job_id, cap);
    let job = state.jobs.remove(job_id);
    let output_volume = industry_job::output_volume(&job);
    event::emit(IndustryOutputsClaimed { job: summary(&job) });
    let items = industry_job::take_outputs(job);
    state.output_used = state.output_used - output_volume;
    req.enqueue(frame);
    entity.complete_request(req);
    items
}

/// Cancel before maturity, releasing a lane/output reservation but retaining refunds.
public fun cancel_job(
    entity: &mut Entity,
    cap: &AccessCap,
    module_id: u64,
    job_id: ID,
    clock: &Clock,
    _ctx: &mut TxContext,
) {
    access_cap::assert_valid(cap);
    let mut req = entity.begin_module_request(
        module_id,
        requirement::from_config(option::some(module_id), Cancel()),
        module_permit(),
    );
    let (_, frame, state) = take(entity, &mut req, internal::permit<Cancel>());
    assert_job_owner(state, job_id, cap);
    let job = &mut state.jobs[job_id];
    industry_job::cancel(job, clock);
    let output_volume = industry_job::output_volume(job);
    event::emit(IndustryJobCancelled { job: summary(job) });
    state.running = state.running - 1;
    state.output_reserved = state.output_reserved - output_volume;
    req.enqueue(frame);
    entity.complete_request(req);
}

/// Refund every input and the full prepaid fee to the authenticated principal.
public fun claim_refund(
    entity: &mut Entity,
    cap: &AccessCap,
    module_id: u64,
    job_id: ID,
    ctx: &mut TxContext,
): (vector<ItemV2>, Coin<SUI>) {
    access_cap::assert_valid(cap);
    let mut req = entity.begin_module_request(
        module_id,
        requirement::from_config(option::some(module_id), Refund()),
        module_permit(),
    );
    let (_, frame, state) = take(entity, &mut req, internal::permit<Refund>());
    assert_job_owner(state, job_id, cap);
    let job = state.jobs.remove(job_id);
    let input_volume = industry_job::input_volume(&job);
    event::emit(IndustryInputsRefunded { job: summary(&job) });
    let (items, payment) = industry_job::take_refund(job, ctx);
    state.input_used = state.input_used - input_volume;
    req.enqueue(frame);
    entity.complete_request(req);
    (items, payment)
}

/// Change only future-job terms; existing jobs retain amounts, timing and fees.
public fun set_policy(
    entity: &mut Entity,
    cap: &AccessCap,
    module_id: u64,
    policy: Policy,
    _ctx: &mut TxContext,
) {
    access_cap::assert_valid(cap);
    assert!(access_cap::entity(cap) == entity.id(), ENotAuthorized);
    let entity_id = entity.id();
    let mut req = entity.begin_module_request(
        module_id,
        requirement::from_config(option::some(module_id), Configure()),
        module_permit(),
    );
    let (_, frame, state) = take(entity, &mut req, internal::permit<Configure>());
    policy.kinds.do_ref!(|kind| assert!(state.config.kinds.contains(kind), EKindNotAllowed));
    state.policy = policy;
    event::emit(IndustryPolicyChanged { entity_id, module_id, policy });
    req.enqueue(frame);
    entity.complete_request(req);
}

/// Remove only a fully drained industry module, then complete its admin request.
public fun uninstall(entity: &mut Entity, module_id: u64, ctx: &mut TxContext): Request {
    let current = industry(entity, module_id);
    assert!(
        current.jobs.is_empty() && current.running == 0 && current.input_used == 0 && current.output_used == 0 && current.output_reserved == 0,
        EOutstandingJobs,
    );
    let (m, req) = entity.uninstall<Industry>(module_id, module_permit(), ctx);
    let Industry { jobs, .. } = m.unwrap(module_permit());
    jobs.destroy_empty();
    req
}

// === View Functions ===

/// Read industry.
public fun industry(entity: &Entity, module_id: u64): &Industry {
    let m = entity.module_ref<Industry>(module_id, module_permit());
    assert!(mod::version(m) == VERSION, EWrongVersion);
    m.inner()
}

/// Read job.
public fun job(entity: &Entity, module_id: u64, job_id: ID): &IndustryJob {
    let state = industry(entity, module_id);
    assert!(state.jobs.contains(job_id), EJobMissing);
    &state.jobs[job_id]
}

/// Copy a complete job projection for SDK inspection without returning a reference.
public fun job_summary(entity: &Entity, module_id: u64, job_id: ID): JobSummary {
    summary(job(entity, module_id, job_id))
}

/// Read the lifecycle state: 0 running, 1 completed, 2 cancelled.
public fun job_state(entity: &Entity, module_id: u64, job_id: ID): u8 {
    industry_job::state(job(entity, module_id, job_id))
}

/// Read item registry id.
public fun item_registry_id(state: &Industry): ID { state.item_registry_id }

/// Read recipe registry id.
public fun recipe_registry_id(state: &Industry): ID { state.recipe_registry_id }

/// Read admin acl id.
public fun admin_acl_id(state: &Industry): ID { state.admin_acl_id }

/// Read tenant.
public fun tenant(state: &Industry): String { state.tenant }

/// Read config.
public fun config(state: &Industry): &FacilityConfig { &state.config }

/// Read current policy.
public fun current_policy(state: &Industry): &Policy { &state.policy }

/// Read running.
public fun running(state: &Industry): u64 { state.running }

/// Read input used.
public fun input_used(state: &Industry): u64 { state.input_used }

/// Read output used.
public fun output_used(state: &Industry): u64 { state.output_used }

/// Read output reserved.
public fun output_reserved(state: &Industry): u64 { state.output_reserved }

/// Read jobs.
public fun jobs(state: &Industry): &Table<ID, IndustryJob> { &state.jobs }

/// Read type id.
public fun type_id(config: &FacilityConfig): u64 { config.type_id }

/// Read tier.
public fun tier(config: &FacilityConfig): u64 { config.tier }

/// Read kinds.
public fun kinds(config: &FacilityConfig): &vector<u8> { &config.kinds }

/// Read lanes.
public fun lanes(config: &FacilityConfig): u64 { config.lanes }

/// Read max jobs.
public fun max_jobs(config: &FacilityConfig): u64 { config.max_jobs }

/// Read input capacity.
public fun input_capacity(config: &FacilityConfig): u64 { config.input_capacity }

/// Read output capacity.
public fun output_capacity(config: &FacilityConfig): u64 { config.output_capacity }

/// Read paused.
public fun paused(policy: &Policy): bool { policy.paused }

/// Read owner only.
public fun owner_only(policy: &Policy): bool { policy.owner_only }

/// Read policy kinds.
public fun policy_kinds(policy: &Policy): &vector<u8> { &policy.kinds }

/// Read allowed recipes.
public fun allowed_recipes(policy: &Policy): &vector<ID> { &policy.allowed_recipes }

/// Read fee per batch.
public fun fee_per_batch(policy: &Policy): u64 { policy.fee_per_batch }

/// Read fee recipient.
public fun fee_recipient(policy: &Policy): address { policy.fee_recipient }

/// Canonical event/read projection of an immutable job commitment.
public fun summary(job: &IndustryJob): JobSummary {
    JobSummary {
        schema_version: VERSION,
        job_id: object::id(job),
        entity_id: industry_job::entity_id(job),
        module_id: industry_job::module_id(job),
        tenant: industry_job::tenant(job),
        beneficiary: industry_job::beneficiary(job),
        recipe_id: industry_job::recipe_id(job),
        recipe_digest: *industry_job::recipe_digest(job),
        kind: industry_job::kind(job),
        batches: industry_job::batches(job),
        inputs: *industry_job::committed_inputs(job),
        outputs: *industry_job::committed_outputs(job),
        started_at_ms: industry_job::started_at_ms(job),
        ready_at_ms: industry_job::ready_at_ms(job),
        fee: industry_job::fee_amount(job),
    }
}

/// Read entity id from the installed projection.
public fun installed_entity_id(value: &IndustryInstalled): ID { value.entity_id }

/// Read module id from the installed projection.
public fun installed_module_id(value: &IndustryInstalled): u64 { value.module_id }

/// Read item registry id from the installed projection.
public fun installed_item_registry_id(value: &IndustryInstalled): ID { value.item_registry_id }

/// Read recipe registry id from the installed projection.
public fun installed_recipe_registry_id(value: &IndustryInstalled): ID { value.recipe_registry_id }

/// Read config from the installed projection.
public fun installed_config(value: &IndustryInstalled): &FacilityConfig { &value.config }

/// Read entity id from the policy changed projection.
public fun policy_changed_entity_id(value: &IndustryPolicyChanged): ID { value.entity_id }

/// Read module id from the policy changed projection.
public fun policy_changed_module_id(value: &IndustryPolicyChanged): u64 { value.module_id }

/// Read policy from the policy changed projection.
public fun policy_changed_policy(value: &IndustryPolicyChanged): &Policy { &value.policy }

/// Read entity id from the limits changed projection.
public fun limits_changed_entity_id(value: &IndustryLimitsChanged): ID { value.entity_id }

/// Read module id from the limits changed projection.
public fun limits_changed_module_id(value: &IndustryLimitsChanged): u64 { value.module_id }

/// Read config from the limits changed projection.
public fun limits_changed_config(value: &IndustryLimitsChanged): &FacilityConfig { &value.config }

/// Read schema version from the summary projection.
public fun summary_schema_version(value: &JobSummary): u64 { value.schema_version }

/// Read job id from the summary projection.
public fun summary_job_id(value: &JobSummary): ID { value.job_id }

/// Read entity id from the summary projection.
public fun summary_entity_id(value: &JobSummary): ID { value.entity_id }

/// Read module id from the summary projection.
public fun summary_module_id(value: &JobSummary): u64 { value.module_id }

/// Read tenant from the summary projection.
public fun summary_tenant(value: &JobSummary): String { value.tenant }

/// Read beneficiary from the summary projection.
public fun summary_beneficiary(value: &JobSummary): ID { value.beneficiary }

/// Read recipe id from the summary projection.
public fun summary_recipe_id(value: &JobSummary): ID { value.recipe_id }

/// Read recipe digest from the summary projection.
public fun summary_recipe_digest(value: &JobSummary): &vector<u8> { &value.recipe_digest }

/// Read kind from the summary projection.
public fun summary_kind(value: &JobSummary): u8 { value.kind }

/// Read batches from the summary projection.
public fun summary_batches(value: &JobSummary): u64 { value.batches }

/// Read inputs from the summary projection.
public fun summary_inputs(value: &JobSummary): &vector<ItemAmount> { &value.inputs }

/// Read outputs from the summary projection.
public fun summary_outputs(value: &JobSummary): &vector<ItemAmount> { &value.outputs }

/// Read started at ms from the summary projection.
public fun summary_started_at_ms(value: &JobSummary): u64 { value.started_at_ms }

/// Read ready at ms from the summary projection.
public fun summary_ready_at_ms(value: &JobSummary): u64 { value.ready_at_ms }

/// Read fee from the summary projection.
public fun summary_fee(value: &JobSummary): u64 { value.fee }

/// Read job from the started projection.
public fun started_job(value: &IndustryJobStarted): &JobSummary { &value.job }

/// Read job from the completed projection.
public fun completed_job(value: &IndustryJobCompleted): &JobSummary { &value.job }

/// Read job from the cancelled projection.
public fun cancelled_job(value: &IndustryJobCancelled): &JobSummary { &value.job }

/// Read job from the claimed projection.
public fun claimed_job(value: &IndustryOutputsClaimed): &JobSummary { &value.job }

/// Read job from the refunded projection.
public fun refunded_job(value: &IndustryInputsRefunded): &JobSummary { &value.job }

// === Admin Functions ===

/// Adjust trusted allocations without reducing them below outstanding obligations.
public fun set_limits(
    entity: &mut Entity,
    types: &ItemTypeRegistry,
    acl: &AdminACL,
    module_id: u64,
    lanes: u64,
    max_jobs: u64,
    input_capacity: u64,
    output_capacity: u64,
    _ctx: &mut TxContext,
) {
    item_type::assert_admin(types, acl, _ctx);
    let entity_id = entity.id();
    let mut req = entity.begin_module_request(
        module_id,
        requirement::from_config(option::some(module_id), Configure()),
        module_permit(),
    );
    let (_, frame, state) = take(entity, &mut req, internal::permit<Configure>());
    assert!(
        state.item_registry_id == object::id(types) && state.admin_acl_id == object::id(acl),
        EWrongCatalog,
    );
    assert!(
        lanes >= state.running && max_jobs >= state.jobs.length() && input_capacity >= state.input_used && output_capacity >= sum(state.output_used, state.output_reserved),
        EInvalidConfig,
    );
    state.config =
        facility_config(
            state.config.type_id,
            state.config.tier,
            state.config.kinds,
            lanes,
            max_jobs,
            input_capacity,
            output_capacity,
        );
    event::emit(IndustryLimitsChanged { entity_id, module_id, config: state.config });
    req.enqueue(frame);
    entity.complete_request(req);
}

// === Private Functions ===

fun take<T: drop>(
    entity: &mut Entity,
    req: &mut Request,
    permit: Permit<T>,
): (Requirement, Frame, &mut Industry) {
    let m: &mut Module<Industry> = entity.module_mut(req, module_permit());
    assert!(mod::version(m) == VERSION, EWrongVersion);
    let state = m.inner_mut();
    let (requirement, frame) = req.take_next(permit);
    (requirement, frame, state)
}

fun assert_catalogs(state: &Industry, types: &ItemTypeRegistry, recipes: &RecipeRegistry) {
    assert!(
        state.item_registry_id == object::id(types) && state.recipe_registry_id == object::id(recipes),
        EWrongCatalog,
    );
}

fun assert_job_owner(state: &Industry, job_id: ID, cap: &AccessCap) {
    assert!(state.jobs.contains(job_id), EJobMissing);
    assert!(
        industry_job::beneficiary(&state.jobs[job_id]) == access_cap::entity(cap),
        ENotAuthorized,
    );
}

fun validate_kinds(kinds: &vector<u8>) {
    assert!(!kinds.is_empty() && kinds.length() <= 2, EInvalidConfig);
    let mut i = 0;
    while (i < kinds.length()) {
        recipe::assert_kind(kinds[i]);
        if (i > 0) assert!(kinds[i - 1] < kinds[i], EInvalidConfig);
        i = i + 1;
    };
}

fun sum(a: u64, b: u64): u64 {
    let result = (a as u128) + (b as u128);
    assert!(result <= MAX_U64, EOverflow);
    result as u64
}

fun module_permit(): Permit<Industry> { internal::permit<Industry>() }
