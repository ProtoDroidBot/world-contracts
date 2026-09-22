/// Blockchain-visible observations of an existing in-game Industry assembly.
///
/// The authorized game server reads facility state and submits snapshots. These
/// records attest to the server's observation; they do not mint items, provide
/// inventory custody, or execute production. Owner and solar-system IDs are
/// server attestations. Assembly identity and status come from the parent object.
/// After the parent is unanchored this record remains a historical observation;
/// its timestamps do not imply that the parent still exists or is still online.
module world_smart_industry::smart_industry;

use std::string::{Self, String};
use sui::{clock::{Self, Clock}, derived_object, dynamic_field, event};
use world::{access::AdminACL, assembly::Assembly, in_game_id::TenantItemId, status};

#[error(code = 0)]
const EAssemblyMismatch: vector<u8> = b"Industry record belongs to another assembly";
#[error(code = 1)]
const EStaleRevision: vector<u8> = b"Industry revision changed; read and retry";
#[error(code = 2)]
const EStaleObservation: vector<u8> = b"Observation must be newer than the stored observation";
#[error(code = 3)]
const EFutureObservation: vector<u8> = b"Observation is too far ahead of chain time";
#[error(code = 4)]
const EInvalidIdentity: vector<u8> = b"Owner and solar system IDs must be nonzero";
#[error(code = 5)]
const EInvalidStack: vector<u8> = b"Item type and quantity must be nonzero";
#[error(code = 6)]
const EInvalidRecipe: vector<u8> = b"Recipe quantity must be positive and within maximum quantity";
#[error(code = 7)]
const EUnsortedTypes: vector<u8> = b"Item types must be strictly increasing without duplicates";
#[error(code = 8)]
const ETooManyItems: vector<u8> = b"Each inventory or recipe vector is limited to 256 entries";
#[error(code = 9)]
const EInvalidBlueprint: vector<u8> = b"Blueprint and recipe runtime are inconsistent";
#[error(code = 10)]
const EInvalidProduction: vector<u8> = b"Production state, counters, or timing are inconsistent";
#[error(code = 11)]
const EInvalidLane: vector<u8> = b"Industry lanes must start at one and be strictly increasing";

const MAX_ITEMS: u64 = 256;
const MAX_FUTURE_SKEW_MS: u64 = 30_000;
const PRODUCTION_KEY: u8 = 0;
const LANE_PRODUCTION_KEY: u8 = 1;
const LANE_STATE_KEY: u8 = 2;
const MAX_LANES: u64 = 16;

/// Uses a distinct registry key type so the existing Assembly retains its ID.
/// BCS layout is one Sui ID; clients may derive the sidecar address in advance.
public struct IndustryKey has copy, drop, store {
    assembly_id: ID,
}

public struct ItemStack has copy, drop, store {
    type_id: u64,
    quantity: u64,
}

public struct RecipeSlot has copy, drop, store {
    type_id: u64,
    quantity: u64,
    max_quantity: u64,
}

/// Runtime is measured in seconds. Blueprint ID 0 means no configured blueprint.
/// Inventory vectors contain aggregated, nonzero totals ordered by item type.
public struct Snapshot has copy, drop, store {
    owner_id: u64,
    solar_system_id: u64,
    blueprint_id: u64,
    run_time: u64,
    inputs: vector<ItemStack>,
    outputs: vector<ItemStack>,
    blueprint_inputs: vector<RecipeSlot>,
    blueprint_outputs: vector<RecipeSlot>,
}

public struct SmartIndustry has key {
    id: UID,
    assembly_id: ID,
    assembly_key: TenantItemId,
    type_id: u64,
    /// Parent status at synchronization: 1 offline, 2 online.
    assembly_status: u8,
    revision: u64,
    observed_at_ms: u64,
    synced_at_ms: u64,
    snapshot: Snapshot,
}

/// Package-owned root for deterministic Smart Industry sidecars.
public struct SmartIndustryRegistry has key {
    id: UID,
}

/// Stored as a dynamic field to preserve deployed Snapshot/SmartIndustry layouts.
/// State: 0 idle, 1 running, 2 finishing the current run, 3 stopped.
/// requested_runs=0 means continuous. Times are Unix milliseconds.
public struct Production has copy, drop, store {
    job_id: u64,
    state: u8,
    requested_runs: u64,
    completed_runs: u64,
    run_started_at_ms: u64,
    run_end_at_ms: u64,
    stop_reason: String,
}

/// Readers must match this revision with SmartIndustry before combining reads.
public struct ProductionRecord has copy, drop, store {
    revision: u64,
    production: Production,
}

public struct LaneProduction has copy, drop, store {
    lane_id: u64,
    production: Production,
}

public struct LaneProductionRecord has copy, drop, store {
    revision: u64,
    lanes: vector<LaneProduction>,
}

/// Complete per-lane recipe, escrow and production observation. This is a
/// dynamic field so deployed SmartIndustry and Snapshot layouts remain valid.
public struct LaneState has copy, drop, store {
    lane_id: u64,
    snapshot: Snapshot,
    production: Production,
}

/// Readers must match this revision with SmartIndustry before combining reads.
public struct LaneStateRecord has copy, drop, store {
    revision: u64,
    lanes: vector<LaneState>,
}

public struct SmartIndustryCreatedEvent has copy, drop {
    industry_id: ID,
    assembly_id: ID,
    assembly_key: TenantItemId,
    type_id: u64,
    revision: u64,
    observed_at_ms: u64,
    synced_at_ms: u64,
}

public struct SmartIndustrySyncedEvent has copy, drop {
    industry_id: ID,
    assembly_id: ID,
    revision: u64,
    observed_at_ms: u64,
    synced_at_ms: u64,
}

// === Transaction argument constructors ===

public fun new_industry_key(assembly_id: ID): IndustryKey {
    IndustryKey { assembly_id }
}

public fun new_production(
    job_id: u64,
    state: u8,
    requested_runs: u64,
    completed_runs: u64,
    run_started_at_ms: u64,
    run_end_at_ms: u64,
    stop_reason: String,
): Production {
    assert!(state <= 3 && stop_reason.length() <= 64, EInvalidProduction);
    let reason_bytes = stop_reason.as_bytes();
    let mut index = 0;
    while (index < reason_bytes.length()) {
        let byte = reason_bytes[index];
        assert!(
            (byte >= 65 && byte <= 90) ||
            (index > 0 && ((byte >= 48 && byte <= 57) || byte == 95)),
            EInvalidProduction,
        );
        index = index + 1;
    };
    if (state == 0) {
        assert!(
            job_id == 0 && requested_runs == 0 && completed_runs == 0
            && run_started_at_ms == 0 && run_end_at_ms == 0 && stop_reason.is_empty(),
            EInvalidProduction,
        );
    } else {
        assert!(job_id > 0 && run_end_at_ms > run_started_at_ms, EInvalidProduction);
        assert!(requested_runs == 0 || completed_runs <= requested_runs, EInvalidProduction);
        if (state == 3) {
            assert!(!stop_reason.is_empty(), EInvalidProduction);
        } else {
            assert!(
                stop_reason.is_empty() && (requested_runs == 0 || completed_runs < requested_runs),
                EInvalidProduction,
            );
        };
        if (stop_reason == string::utf8(b"COMPLETED")) {
            assert!(requested_runs > 0 && completed_runs == requested_runs, EInvalidProduction);
        };
    };
    Production {
        job_id,
        state,
        requested_runs,
        completed_runs,
        run_started_at_ms,
        run_end_at_ms,
        stop_reason,
    }
}

public fun idle_production(): Production {
    new_production(0, 0, 0, 0, 0, 0, string::utf8(b""))
}

public fun new_lane_production(lane_id: u64, production: Production): LaneProduction {
    assert!(lane_id > 0 && lane_id <= MAX_LANES, EInvalidLane);
    LaneProduction { lane_id, production }
}

public fun new_lane_state(
    lane_id: u64,
    snapshot: Snapshot,
    production: Production,
): LaneState {
    assert!(lane_id > 0 && lane_id <= MAX_LANES, EInvalidLane);
    validate_production_snapshot(&production, &snapshot);
    LaneState { lane_id, snapshot, production }
}

public fun new_item_stack(type_id: u64, quantity: u64): ItemStack {
    assert!(type_id > 0 && quantity > 0, EInvalidStack);
    ItemStack { type_id, quantity }
}

public fun new_recipe_slot(type_id: u64, quantity: u64, max_quantity: u64): RecipeSlot {
    assert!(type_id > 0 && quantity > 0 && max_quantity >= quantity, EInvalidRecipe);
    RecipeSlot { type_id, quantity, max_quantity }
}

public fun new_snapshot(
    owner_id: u64,
    solar_system_id: u64,
    blueprint_id: u64,
    run_time: u64,
    inputs: vector<ItemStack>,
    outputs: vector<ItemStack>,
    blueprint_inputs: vector<RecipeSlot>,
    blueprint_outputs: vector<RecipeSlot>,
): Snapshot {
    assert!(owner_id > 0 && solar_system_id > 0, EInvalidIdentity);
    validate_inventory(&inputs);
    validate_inventory(&outputs);
    validate_recipe(&blueprint_inputs);
    validate_recipe(&blueprint_outputs);
    if (blueprint_id == 0) {
        assert!(
            run_time == 0 && blueprint_inputs.is_empty() && blueprint_outputs.is_empty(),
            EInvalidBlueprint,
        );
    } else {
        assert!(run_time > 0, EInvalidBlueprint);
    };
    Snapshot {
        owner_id,
        solar_system_id,
        blueprint_id,
        run_time,
        inputs,
        outputs,
        blueprint_inputs,
        blueprint_outputs,
    }
}

// === Authorized synchronization ===

/// Creates and shares exactly one record for this assembly in this registry.
/// A duplicate creation aborts during deterministic claiming; read the record and sync.
public fun create(
    registry: &mut SmartIndustryRegistry,
    assembly: &Assembly,
    acl: &AdminACL,
    observed_at_ms: u64,
    snapshot: Snapshot,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    create_with_production(
        registry,
        assembly,
        acl,
        observed_at_ms,
        snapshot,
        idle_production(),
        clock,
        ctx,
    );
}

public fun create_with_production(
    registry: &mut SmartIndustryRegistry,
    assembly: &Assembly,
    acl: &AdminACL,
    observed_at_ms: u64,
    snapshot: Snapshot,
    production: Production,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    create_with_lanes(
        registry,
        assembly,
        acl,
        observed_at_ms,
        snapshot,
        vector[new_lane_production(1, production)],
        clock,
        ctx,
    );
}

public fun create_with_lanes(
    registry: &mut SmartIndustryRegistry,
    assembly: &Assembly,
    acl: &AdminACL,
    observed_at_ms: u64,
    snapshot: Snapshot,
    lanes: vector<LaneProduction>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    acl.verify_sponsor(ctx);
    validate_lane_productions(&lanes, &snapshot);
    let synced_at_ms = clock::timestamp_ms(clock);
    validate_observation(observed_at_ms, synced_at_ms);
    let assembly_id = object::id(assembly);
    let assembly_key = assembly.key();
    let type_id = assembly.type_id();
    let id = derived_object::claim(&mut registry.id, new_industry_key(assembly_id));
    let industry_id = object::uid_to_inner(&id);
    let mut industry = SmartIndustry {
        id,
        assembly_id,
        assembly_key,
        type_id,
        assembly_status: parent_status(assembly),
        revision: 1,
        observed_at_ms,
        synced_at_ms,
        snapshot,
    };
    let lane_one = lanes[0].production;
    dynamic_field::add(
        &mut industry.id,
        PRODUCTION_KEY,
        ProductionRecord { revision: 1, production: lane_one },
    );
    dynamic_field::add(
        &mut industry.id,
        LANE_PRODUCTION_KEY,
        LaneProductionRecord { revision: 1, lanes },
    );
    event::emit(SmartIndustryCreatedEvent {
        industry_id,
        assembly_id,
        assembly_key,
        type_id,
        revision: 1,
        observed_at_ms,
        synced_at_ms,
    });
    transfer::share_object(industry);
}

/// Creates a sidecar whose complete blueprint, recipe, escrow and production
/// state is isolated per lane. The root snapshot and legacy dynamic fields
/// remain lane-one projections for compatibility readers.
public fun create_with_lane_states(
    registry: &mut SmartIndustryRegistry,
    assembly: &Assembly,
    acl: &AdminACL,
    observed_at_ms: u64,
    lanes: vector<LaneState>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    acl.verify_sponsor(ctx);
    validate_lane_states(&lanes);
    let snapshot = lanes[0].snapshot;
    let productions = lane_productions_from_states(&lanes);
    let synced_at_ms = clock::timestamp_ms(clock);
    validate_observation(observed_at_ms, synced_at_ms);
    let assembly_id = object::id(assembly);
    let assembly_key = assembly.key();
    let type_id = assembly.type_id();
    let id = derived_object::claim(&mut registry.id, new_industry_key(assembly_id));
    let industry_id = object::uid_to_inner(&id);
    let mut industry = SmartIndustry {
        id,
        assembly_id,
        assembly_key,
        type_id,
        assembly_status: parent_status(assembly),
        revision: 1,
        observed_at_ms,
        synced_at_ms,
        snapshot,
    };
    dynamic_field::add(
        &mut industry.id,
        PRODUCTION_KEY,
        ProductionRecord { revision: 1, production: productions[0].production },
    );
    dynamic_field::add(
        &mut industry.id,
        LANE_PRODUCTION_KEY,
        LaneProductionRecord { revision: 1, lanes: productions },
    );
    dynamic_field::add(
        &mut industry.id,
        LANE_STATE_KEY,
        LaneStateRecord { revision: 1, lanes },
    );
    event::emit(SmartIndustryCreatedEvent {
        industry_id,
        assembly_id,
        assembly_key,
        type_id,
        revision: 1,
        observed_at_ms,
        synced_at_ms,
    });
    transfer::share_object(industry);
}

fun init(ctx: &mut TxContext) {
    transfer::share_object(SmartIndustryRegistry { id: object::new(ctx) });
}

#[test_only]
public fun init_for_testing(ctx: &mut TxContext) {
    init(ctx);
}

public fun registry_id(registry: &SmartIndustryRegistry): ID {
    object::id(registry)
}

/// Atomically replaces the complete observation. Revision CAS prevents racing
/// workers from silently overwriting each other; source time rejects stale reads.
public fun sync(
    industry: &mut SmartIndustry,
    assembly: &Assembly,
    acl: &AdminACL,
    expected_revision: u64,
    observed_at_ms: u64,
    snapshot: Snapshot,
    clock: &Clock,
    ctx: &TxContext,
) {
    sync_with_production(
        industry,
        assembly,
        acl,
        expected_revision,
        observed_at_ms,
        snapshot,
        idle_production(),
        clock,
        ctx,
    );
}

public fun sync_with_production(
    industry: &mut SmartIndustry,
    assembly: &Assembly,
    acl: &AdminACL,
    expected_revision: u64,
    observed_at_ms: u64,
    snapshot: Snapshot,
    production: Production,
    clock: &Clock,
    ctx: &TxContext,
) {
    sync_with_lanes(
        industry,
        assembly,
        acl,
        expected_revision,
        observed_at_ms,
        snapshot,
        vector[new_lane_production(1, production)],
        clock,
        ctx,
    );
}

public fun sync_with_lanes(
    industry: &mut SmartIndustry,
    assembly: &Assembly,
    acl: &AdminACL,
    expected_revision: u64,
    observed_at_ms: u64,
    snapshot: Snapshot,
    lanes: vector<LaneProduction>,
    clock: &Clock,
    ctx: &TxContext,
) {
    acl.verify_sponsor(ctx);
    validate_lane_productions(&lanes, &snapshot);
    assert!(
        industry.assembly_id == object::id(assembly)
            && industry.assembly_key == assembly.key()
            && industry.type_id == assembly.type_id(),
        EAssemblyMismatch,
    );
    assert!(industry.revision == expected_revision, EStaleRevision);
    assert!(observed_at_ms > industry.observed_at_ms, EStaleObservation);
    let synced_at_ms = clock::timestamp_ms(clock);
    validate_observation(observed_at_ms, synced_at_ms);
    industry.assembly_status = parent_status(assembly);
    industry.revision = industry.revision + 1;
    industry.observed_at_ms = observed_at_ms;
    industry.synced_at_ms = synced_at_ms;
    industry.snapshot = snapshot;
    let lane_one = lanes[0].production;
    if (dynamic_field::exists(&industry.id, PRODUCTION_KEY)) {
        dynamic_field::remove<u8, ProductionRecord>(&mut industry.id, PRODUCTION_KEY);
    };
    dynamic_field::add(
        &mut industry.id,
        PRODUCTION_KEY,
        ProductionRecord { revision: industry.revision, production: lane_one },
    );
    if (dynamic_field::exists(&industry.id, LANE_PRODUCTION_KEY)) {
        dynamic_field::remove<u8, LaneProductionRecord>(
            &mut industry.id,
            LANE_PRODUCTION_KEY,
        );
    };
    dynamic_field::add(
        &mut industry.id,
        LANE_PRODUCTION_KEY,
        LaneProductionRecord { revision: industry.revision, lanes },
    );
    // A legacy writer cannot provide authoritative per-lane snapshots. Remove
    // any prior record so current readers fail closed and request a full sync.
    if (dynamic_field::exists(&industry.id, LANE_STATE_KEY)) {
        dynamic_field::remove<u8, LaneStateRecord>(&mut industry.id, LANE_STATE_KEY);
    };
    event::emit(SmartIndustrySyncedEvent {
        industry_id: object::id(industry),
        assembly_id: industry.assembly_id,
        revision: industry.revision,
        observed_at_ms,
        synced_at_ms,
    });
}

/// Atomically replaces every lane and all compatibility projections.
public fun sync_with_lane_states(
    industry: &mut SmartIndustry,
    assembly: &Assembly,
    acl: &AdminACL,
    expected_revision: u64,
    observed_at_ms: u64,
    lanes: vector<LaneState>,
    clock: &Clock,
    ctx: &TxContext,
) {
    acl.verify_sponsor(ctx);
    validate_lane_states(&lanes);
    assert!(
        industry.assembly_id == object::id(assembly)
            && industry.assembly_key == assembly.key()
            && industry.type_id == assembly.type_id(),
        EAssemblyMismatch,
    );
    assert!(industry.revision == expected_revision, EStaleRevision);
    assert!(observed_at_ms > industry.observed_at_ms, EStaleObservation);
    let synced_at_ms = clock::timestamp_ms(clock);
    validate_observation(observed_at_ms, synced_at_ms);
    let snapshot = lanes[0].snapshot;
    let productions = lane_productions_from_states(&lanes);
    industry.assembly_status = parent_status(assembly);
    industry.revision = industry.revision + 1;
    industry.observed_at_ms = observed_at_ms;
    industry.synced_at_ms = synced_at_ms;
    industry.snapshot = snapshot;
    if (dynamic_field::exists(&industry.id, PRODUCTION_KEY)) {
        dynamic_field::remove<u8, ProductionRecord>(&mut industry.id, PRODUCTION_KEY);
    };
    dynamic_field::add(
        &mut industry.id,
        PRODUCTION_KEY,
        ProductionRecord {
            revision: industry.revision,
            production: productions[0].production,
        },
    );
    if (dynamic_field::exists(&industry.id, LANE_PRODUCTION_KEY)) {
        dynamic_field::remove<u8, LaneProductionRecord>(
            &mut industry.id,
            LANE_PRODUCTION_KEY,
        );
    };
    dynamic_field::add(
        &mut industry.id,
        LANE_PRODUCTION_KEY,
        LaneProductionRecord { revision: industry.revision, lanes: productions },
    );
    if (dynamic_field::exists(&industry.id, LANE_STATE_KEY)) {
        dynamic_field::remove<u8, LaneStateRecord>(&mut industry.id, LANE_STATE_KEY);
    };
    dynamic_field::add(
        &mut industry.id,
        LANE_STATE_KEY,
        LaneStateRecord { revision: industry.revision, lanes },
    );
    event::emit(SmartIndustrySyncedEvent {
        industry_id: object::id(industry),
        assembly_id: industry.assembly_id,
        revision: industry.revision,
        observed_at_ms,
        synced_at_ms,
    });
}

// === Public views ===

public fun id(industry: &SmartIndustry): ID { object::id(industry) }

public fun assembly_id(industry: &SmartIndustry): ID { industry.assembly_id }

public fun assembly_key(industry: &SmartIndustry): TenantItemId { industry.assembly_key }

public fun type_id(industry: &SmartIndustry): u64 { industry.type_id }

public fun assembly_status(industry: &SmartIndustry): u8 { industry.assembly_status }

public fun revision(industry: &SmartIndustry): u64 { industry.revision }

public fun observed_at_ms(industry: &SmartIndustry): u64 { industry.observed_at_ms }

public fun synced_at_ms(industry: &SmartIndustry): u64 { industry.synced_at_ms }

public fun snapshot(industry: &SmartIndustry): &Snapshot { &industry.snapshot }

public fun owner_id(snapshot: &Snapshot): u64 { snapshot.owner_id }

public fun solar_system_id(snapshot: &Snapshot): u64 { snapshot.solar_system_id }

public fun blueprint_id(snapshot: &Snapshot): u64 { snapshot.blueprint_id }

public fun run_time(snapshot: &Snapshot): u64 { snapshot.run_time }

public fun inputs(snapshot: &Snapshot): &vector<ItemStack> { &snapshot.inputs }

public fun outputs(snapshot: &Snapshot): &vector<ItemStack> { &snapshot.outputs }

public fun blueprint_inputs(snapshot: &Snapshot): &vector<RecipeSlot> { &snapshot.blueprint_inputs }

public fun blueprint_outputs(snapshot: &Snapshot): &vector<RecipeSlot> {
    &snapshot.blueprint_outputs
}

public fun item_type_id(item: &ItemStack): u64 { item.type_id }

public fun item_quantity(item: &ItemStack): u64 { item.quantity }

public fun recipe_type_id(slot: &RecipeSlot): u64 { slot.type_id }

public fun recipe_quantity(slot: &RecipeSlot): u64 { slot.quantity }

public fun recipe_max_quantity(slot: &RecipeSlot): u64 { slot.max_quantity }

public fun max_items(): u64 { MAX_ITEMS }

public fun max_future_skew_ms(): u64 { MAX_FUTURE_SKEW_MS }

public fun key_assembly_id(key: &IndustryKey): ID { key.assembly_id }

public fun production(industry: &SmartIndustry): Production {
    if (has_production(industry)) {
        dynamic_field::borrow<u8, ProductionRecord>(&industry.id, PRODUCTION_KEY).production
    } else idle_production()
}

public fun has_production(industry: &SmartIndustry): bool {
    dynamic_field::exists(&industry.id, PRODUCTION_KEY)
}

public fun production_job_id(value: &Production): u64 { value.job_id }

public fun production_state(value: &Production): u8 { value.state }

public fun production_requested_runs(value: &Production): u64 { value.requested_runs }

public fun production_completed_runs(value: &Production): u64 { value.completed_runs }

public fun production_run_started_at_ms(value: &Production): u64 { value.run_started_at_ms }

public fun production_run_end_at_ms(value: &Production): u64 { value.run_end_at_ms }

public fun production_stop_reason(value: &Production): String { value.stop_reason }

public fun production_record_revision(value: &ProductionRecord): u64 { value.revision }

public fun production_record_value(value: &ProductionRecord): Production { value.production }

public fun has_lane_productions(industry: &SmartIndustry): bool {
    dynamic_field::exists(&industry.id, LANE_PRODUCTION_KEY)
}

public fun lane_productions(industry: &SmartIndustry): &vector<LaneProduction> {
    &dynamic_field::borrow<u8, LaneProductionRecord>(&industry.id, LANE_PRODUCTION_KEY).lanes
}

public fun lane_production_lane_id(value: &LaneProduction): u64 { value.lane_id }

public fun lane_production_value(value: &LaneProduction): Production { value.production }

public fun lane_production_record_revision(value: &LaneProductionRecord): u64 { value.revision }

public fun lane_production_record_lanes(
    value: &LaneProductionRecord,
): &vector<LaneProduction> {
    &value.lanes
}

public fun has_lane_states(industry: &SmartIndustry): bool {
    dynamic_field::exists(&industry.id, LANE_STATE_KEY)
}

public fun lane_states(industry: &SmartIndustry): &vector<LaneState> {
    &dynamic_field::borrow<u8, LaneStateRecord>(&industry.id, LANE_STATE_KEY).lanes
}

public fun lane_state_lane_id(value: &LaneState): u64 { value.lane_id }

public fun lane_state_snapshot(value: &LaneState): &Snapshot { &value.snapshot }

public fun lane_state_production(value: &LaneState): Production { value.production }

public fun lane_state_record_revision(value: &LaneStateRecord): u64 { value.revision }

public fun lane_state_record_lanes(value: &LaneStateRecord): &vector<LaneState> {
    &value.lanes
}

public fun max_lanes(): u64 { MAX_LANES }

#[test_only]
public fun remove_production_for_testing(industry: &mut SmartIndustry) {
    dynamic_field::remove<u8, ProductionRecord>(&mut industry.id, PRODUCTION_KEY);
}

// === Validation ===

fun validate_production_snapshot(production: &Production, snapshot: &Snapshot) {
    assert!(production.state == 0 || snapshot.blueprint_id > 0, EInvalidProduction);
}

fun validate_lane_productions(lanes: &vector<LaneProduction>, snapshot: &Snapshot) {
    assert!(
        !lanes.is_empty() && lanes.length() <= MAX_LANES && lanes[0].lane_id == 1,
        EInvalidLane,
    );
    let mut previous = 0;
    let mut index = 0;
    while (index < lanes.length()) {
        let lane = &lanes[index];
        assert!(lane.lane_id > previous && lane.lane_id <= MAX_LANES, EInvalidLane);
        validate_production_snapshot(&lane.production, snapshot);
        previous = lane.lane_id;
        index = index + 1;
    };
}

fun validate_lane_states(lanes: &vector<LaneState>) {
    assert!(
        !lanes.is_empty() && lanes.length() <= MAX_LANES && lanes[0].lane_id == 1,
        EInvalidLane,
    );
    let owner_id = lanes[0].snapshot.owner_id;
    let solar_system_id = lanes[0].snapshot.solar_system_id;
    let mut previous = 0;
    let mut index = 0;
    while (index < lanes.length()) {
        let lane = &lanes[index];
        assert!(lane.lane_id > previous && lane.lane_id <= MAX_LANES, EInvalidLane);
        assert!(
            lane.snapshot.owner_id == owner_id
                && lane.snapshot.solar_system_id == solar_system_id,
            EInvalidIdentity,
        );
        validate_production_snapshot(&lane.production, &lane.snapshot);
        previous = lane.lane_id;
        index = index + 1;
    };
}

fun lane_productions_from_states(lanes: &vector<LaneState>): vector<LaneProduction> {
    let mut productions = vector[];
    let mut index = 0;
    while (index < lanes.length()) {
        let lane = &lanes[index];
        productions.push_back(LaneProduction {
            lane_id: lane.lane_id,
            production: lane.production,
        });
        index = index + 1;
    };
    productions
}

fun parent_status(assembly: &Assembly): u8 {
    // An Assembly exists only while anchored; unanchor consumes the object.
    if (status::is_online(assembly.status())) 2 else 1
}

fun validate_observation(observed_at_ms: u64, synced_at_ms: u64) {
    // Subtract only when positive, avoiding an addition overflow near u64::MAX.
    assert!(
        observed_at_ms <= synced_at_ms || observed_at_ms - synced_at_ms <= MAX_FUTURE_SKEW_MS,
        EFutureObservation,
    );
}

fun validate_inventory(items: &vector<ItemStack>) {
    assert!(items.length() <= MAX_ITEMS, ETooManyItems);
    let mut previous = 0;
    let mut index = 0;
    while (index < items.length()) {
        let item = &items[index];
        assert!(item.type_id > 0 && item.quantity > 0, EInvalidStack);
        assert!(item.type_id > previous, EUnsortedTypes);
        previous = item.type_id;
        index = index + 1;
    };
}

fun validate_recipe(slots: &vector<RecipeSlot>) {
    assert!(slots.length() <= MAX_ITEMS, ETooManyItems);
    let mut previous = 0;
    let mut index = 0;
    while (index < slots.length()) {
        let slot = &slots[index];
        assert!(
            slot.type_id > 0 && slot.quantity > 0 && slot.max_quantity >= slot.quantity,
            EInvalidRecipe,
        );
        assert!(slot.type_id > previous, EUnsortedTypes);
        previous = slot.type_id;
        index = index + 1;
    };
}
