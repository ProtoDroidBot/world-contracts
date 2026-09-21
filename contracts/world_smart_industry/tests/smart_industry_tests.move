#[test_only]
module world_smart_industry::smart_industry_tests;

use std::unit_test::assert_eq;
use sui::{clock, derived_object, test_scenario as ts};
use world::{
    access::{Self, AdminACL, OwnerCap},
    assembly::{Self, Assembly},
    character::{Self, Character},
    energy::EnergyConfig,
    network_node::{Self, NetworkNode},
    object_registry::ObjectRegistry,
    test_helpers::{Self, governor, admin, user_a, tenant}
};
use world_smart_industry::smart_industry::{Self, SmartIndustry, SmartIndustryRegistry, Snapshot};

const LOCATION_HASH: vector<u8> =
    x"7a8f3b2e9c4d1a6f5e8b2d9c3f7a1e5b7a8f3b2e9c4d1a6f5e8b2d9c3f7a1e5b";
const CHAIN_TIME: u64 = 100_000;

/// Build real generic assemblies so parent binding and ACL tests use the same
/// paths as live facilities, including the pre-existing TenantItemId registry.
fun setup(ts: &mut ts::Scenario): (ID, ID) {
    smart_industry::init_for_testing(ts.ctx());
    test_helpers::setup_world(ts);
    ts::next_tx(ts, admin());
    let mut registry = ts::take_shared<ObjectRegistry>(ts);
    let acl = ts::take_shared<AdminACL>(ts);
    let character = character::create_character(
        &mut registry,
        &acl,
        2001,
        tenant(),
        100,
        user_a(),
        b"Industry owner".to_string(),
        ts.ctx(),
    );
    let mut node = network_node::anchor(
        &mut registry,
        &character,
        &acl,
        5000,
        111000,
        LOCATION_HASH,
        1000,
        3600000,
        100,
        ts.ctx(),
    );
    let assembly = assembly::anchor(
        &mut registry,
        &mut node,
        &character,
        &acl,
        1001,
        8888,
        LOCATION_HASH,
        ts.ctx(),
    );
    let other = assembly::anchor(
        &mut registry,
        &mut node,
        &character,
        &acl,
        1002,
        8888,
        LOCATION_HASH,
        ts.ctx(),
    );
    let assembly_id = object::id(&assembly);
    let other_id = object::id(&other);
    assembly.share_assembly(&acl, ts.ctx());
    other.share_assembly(&acl, ts.ctx());
    node.share_network_node(&acl, ts.ctx());
    character.share_character(&acl, ts.ctx());
    ts::return_shared(acl);
    ts::return_shared(registry);
    (assembly_id, other_id)
}

fun sample(quantity: u64): Snapshot {
    smart_industry::new_snapshot(
        2001,
        30000142,
        9001,
        60,
        vector[smart_industry::new_item_stack(10, quantity)],
        vector[smart_industry::new_item_stack(20, 2)],
        vector[smart_industry::new_recipe_slot(10, 5, 500)],
        vector[smart_industry::new_recipe_slot(20, 1, 100)],
    )
}

fun create_record(ts: &mut ts::Scenario, assembly_id: ID, sender: address, observed: u64): ID {
    ts::next_tx(ts, sender);
    let mut registry = ts::take_shared<SmartIndustryRegistry>(ts);
    let assembly = ts::take_shared_by_id<Assembly>(ts, assembly_id);
    let acl = ts::take_shared<AdminACL>(ts);
    let mut clock = clock::create_for_testing(ts.ctx());
    clock.set_for_testing(CHAIN_TIME);
    let expected_id = object::id_from_address(
        derived_object::derive_address(
            object::id(&registry),
            smart_industry::new_industry_key(assembly_id),
        ),
    );
    smart_industry::create(&mut registry, &assembly, &acl, observed, sample(10), &clock, ts.ctx());
    clock.destroy_for_testing();
    ts::return_shared(acl);
    ts::return_shared(assembly);
    ts::return_shared(registry);
    expected_id
}

fun sync_record(
    ts: &mut ts::Scenario,
    industry_id: ID,
    assembly_id: ID,
    sender: address,
    expected_revision: u64,
    observed: u64,
) {
    ts::next_tx(ts, sender);
    let mut industry = ts::take_shared_by_id<SmartIndustry>(ts, industry_id);
    let assembly = ts::take_shared_by_id<Assembly>(ts, assembly_id);
    let acl = ts::take_shared<AdminACL>(ts);
    let mut clock = clock::create_for_testing(ts.ctx());
    clock.set_for_testing(CHAIN_TIME);
    smart_industry::sync(
        &mut industry,
        &assembly,
        &acl,
        expected_revision,
        observed,
        sample(25),
        &clock,
        ts.ctx(),
    );
    clock.destroy_for_testing();
    ts::return_shared(acl);
    ts::return_shared(assembly);
    ts::return_shared(industry);
}

#[test]
fun creates_deterministic_sidecar_and_replaces_snapshot() {
    let mut ts = ts::begin(governor());
    let (parent, _) = setup(&mut ts);
    let industry_id = create_record(&mut ts, parent, admin(), 90_000);
    ts::next_tx(&mut ts, admin());
    let industry = ts::take_shared_by_id<SmartIndustry>(&ts, industry_id);
    let registry = ts::take_shared<ObjectRegistry>(&ts);
    assert!(registry.object_exists(test_helpers::in_game_id(1001)), 0);
    assert_eq!(industry.id(), industry_id);
    assert_eq!(industry.assembly_id(), parent);
    assert_eq!(industry.assembly_key(), test_helpers::in_game_id(1001));
    assert_eq!(industry.type_id(), 8888);
    assert_eq!(industry.assembly_status(), 1);
    assert_eq!(industry.revision(), 1);
    assert_eq!(industry.observed_at_ms(), 90_000);
    assert_eq!(industry.synced_at_ms(), CHAIN_TIME);
    assert_eq!(smart_industry::owner_id(industry.snapshot()), 2001);
    assert_eq!(smart_industry::solar_system_id(industry.snapshot()), 30000142);
    assert_eq!(smart_industry::blueprint_id(industry.snapshot()), 9001);
    assert_eq!(smart_industry::run_time(industry.snapshot()), 60);
    assert_eq!(smart_industry::item_quantity(&smart_industry::inputs(industry.snapshot())[0]), 10);
    assert_eq!(
        smart_industry::recipe_max_quantity(
            &smart_industry::blueprint_inputs(industry.snapshot())[0],
        ),
        500,
    );
    ts::return_shared(registry);
    ts::return_shared(industry);

    sync_record(&mut ts, industry_id, parent, admin(), 1, 95_000);
    ts::next_tx(&mut ts, admin());
    let industry = ts::take_shared_by_id<SmartIndustry>(&ts, industry_id);
    assert_eq!(industry.revision(), 2);
    assert_eq!(industry.observed_at_ms(), 95_000);
    assert_eq!(smart_industry::item_quantity(&smart_industry::inputs(industry.snapshot())[0]), 25);
    ts::return_shared(industry);
    ts.end();
}

#[test]
fun status_is_derived_from_the_online_parent() {
    let mut ts = ts::begin(governor());
    // The latest receiving ticket belongs to the second assembly.
    let (_, parent) = setup(&mut ts);
    test_helpers::configure_assembly_energy(&mut ts);
    ts::next_tx(&mut ts, user_a());
    let mut character = ts::take_shared<Character>(&ts);
    let character_id = object::id(&character);
    let mut node = ts::take_shared<NetworkNode>(&ts);
    let mut assembly = ts::take_shared_by_id<Assembly>(&ts, parent);
    let energy_config = ts::take_shared<EnergyConfig>(&ts);
    let clock = clock::create_for_testing(ts.ctx());
    let (node_cap, node_receipt) = character.borrow_owner_cap<NetworkNode>(
        ts::most_recent_receiving_ticket<OwnerCap<NetworkNode>>(&character_id),
        ts.ctx(),
    );
    node.deposit_fuel_test(&node_cap, 1, 10, 10, &clock);
    node.online(&node_cap, &clock);
    character.return_owner_cap(node_cap, node_receipt);
    let (assembly_cap, assembly_receipt) = character.borrow_owner_cap<Assembly>(
        ts::most_recent_receiving_ticket<OwnerCap<Assembly>>(&character_id),
        ts.ctx(),
    );
    assembly.online(&mut node, &energy_config, &assembly_cap);
    character.return_owner_cap(assembly_cap, assembly_receipt);
    clock.destroy_for_testing();
    ts::return_shared(energy_config);
    ts::return_shared(assembly);
    ts::return_shared(node);
    ts::return_shared(character);

    let industry_id = create_record(&mut ts, parent, admin(), 90_000);
    ts::next_tx(&mut ts, admin());
    let industry = ts::take_shared_by_id<SmartIndustry>(&ts, industry_id);
    assert_eq!(industry.assembly_status(), 2);
    ts::return_shared(industry);
    ts.end();
}

#[test]
fun accepts_empty_facility_and_future_skew_boundary() {
    let empty = smart_industry::new_snapshot(
        2001,
        30000142,
        0,
        0,
        vector[],
        vector[],
        vector[],
        vector[],
    );
    assert_eq!(smart_industry::blueprint_id(&empty), 0);
    assert!(smart_industry::inputs(&empty).is_empty(), 0);
    let mut ts = ts::begin(governor());
    let (parent, _) = setup(&mut ts);
    create_record(&mut ts, parent, admin(), CHAIN_TIME + smart_industry::max_future_skew_ms());
    ts.end();
}

#[test]
#[expected_failure(abort_code = access::EUnauthorizedSponsor)]
fun unauthorized_create_rejected() {
    let mut ts = ts::begin(governor());
    let (parent, _) = setup(&mut ts);
    create_record(&mut ts, parent, @0xDEAD, 90_000);
    ts.end();
}

#[test]
#[expected_failure(abort_code = access::EUnauthorizedSponsor)]
fun unauthorized_sync_rejected() {
    let mut ts = ts::begin(governor());
    let (parent, _) = setup(&mut ts);
    let industry = create_record(&mut ts, parent, admin(), 90_000);
    sync_record(&mut ts, industry, parent, @0xDEAD, 1, 95_000);
    ts.end();
}

#[test]
#[expected_failure(abort_code = derived_object::EObjectAlreadyExists)]
fun duplicate_creation_rejected() {
    let mut ts = ts::begin(governor());
    let (parent, _) = setup(&mut ts);
    create_record(&mut ts, parent, admin(), 90_000);
    create_record(&mut ts, parent, admin(), 95_000);
    ts.end();
}

#[test]
#[expected_failure(abort_code = smart_industry::EAssemblyMismatch)]
fun another_parent_rejected() {
    let mut ts = ts::begin(governor());
    let (parent, other) = setup(&mut ts);
    let industry = create_record(&mut ts, parent, admin(), 90_000);
    sync_record(&mut ts, industry, other, admin(), 1, 95_000);
    ts.end();
}

#[test]
#[expected_failure(abort_code = smart_industry::EStaleRevision)]
fun stale_revision_rejected() {
    let mut ts = ts::begin(governor());
    let (parent, _) = setup(&mut ts);
    let industry = create_record(&mut ts, parent, admin(), 90_000);
    sync_record(&mut ts, industry, parent, admin(), 0, 95_000);
    ts.end();
}

#[test]
#[expected_failure(abort_code = smart_industry::EStaleObservation)]
fun repeated_observation_rejected() {
    let mut ts = ts::begin(governor());
    let (parent, _) = setup(&mut ts);
    let industry = create_record(&mut ts, parent, admin(), 90_000);
    sync_record(&mut ts, industry, parent, admin(), 1, 90_000);
    ts.end();
}

#[test]
#[expected_failure(abort_code = smart_industry::EStaleObservation)]
fun older_observation_rejected() {
    let mut ts = ts::begin(governor());
    let (parent, _) = setup(&mut ts);
    let industry = create_record(&mut ts, parent, admin(), 90_000);
    sync_record(&mut ts, industry, parent, admin(), 1, 89_999);
    ts.end();
}

#[test]
#[expected_failure(abort_code = smart_industry::EFutureObservation)]
fun future_creation_rejected() {
    let mut ts = ts::begin(governor());
    let (parent, _) = setup(&mut ts);
    create_record(&mut ts, parent, admin(), CHAIN_TIME + 30_001);
    ts.end();
}

#[test]
#[expected_failure(abort_code = smart_industry::EFutureObservation)]
fun future_sync_rejected() {
    let mut ts = ts::begin(governor());
    let (parent, _) = setup(&mut ts);
    let industry = create_record(&mut ts, parent, admin(), 90_000);
    sync_record(&mut ts, industry, parent, admin(), 1, CHAIN_TIME + 30_001);
    ts.end();
}

#[test]
#[expected_failure(abort_code = smart_industry::EInvalidStack)]
fun zero_inventory_quantity_rejected() {
    smart_industry::new_item_stack(10, 0);
}

#[test]
#[expected_failure(abort_code = smart_industry::EInvalidStack)]
fun zero_inventory_type_rejected() {
    smart_industry::new_item_stack(0, 1);
}

#[test]
#[expected_failure(abort_code = smart_industry::EUnsortedTypes)]
fun duplicate_inventory_rejected() {
    smart_industry::new_snapshot(
        2001,
        30000142,
        0,
        0,
        vector[smart_industry::new_item_stack(10, 1), smart_industry::new_item_stack(10, 2)],
        vector[],
        vector[],
        vector[],
    );
}

#[test]
#[expected_failure(abort_code = smart_industry::EUnsortedTypes)]
fun descending_inventory_rejected() {
    smart_industry::new_snapshot(
        2001,
        30000142,
        0,
        0,
        vector[],
        vector[smart_industry::new_item_stack(20, 1), smart_industry::new_item_stack(10, 1)],
        vector[],
        vector[],
    );
}

#[test]
#[expected_failure(abort_code = smart_industry::ETooManyItems)]
fun oversized_inventory_rejected() {
    let mut items = vector[];
    let mut type_id = 1;
    while (type_id <= 257) {
        items.push_back(smart_industry::new_item_stack(type_id, 1));
        type_id = type_id + 1;
    };
    smart_industry::new_snapshot(2001, 30000142, 0, 0, items, vector[], vector[], vector[]);
}

#[test]
#[expected_failure(abort_code = smart_industry::EInvalidRecipe)]
fun recipe_exceeding_capacity_rejected() {
    smart_industry::new_recipe_slot(10, 10, 9);
}

#[test]
#[expected_failure(abort_code = smart_industry::EInvalidRecipe)]
fun zero_recipe_quantity_rejected() {
    smart_industry::new_recipe_slot(10, 0, 9);
}

#[test]
#[expected_failure(abort_code = smart_industry::EUnsortedTypes)]
fun duplicate_recipe_rejected() {
    smart_industry::new_snapshot(
        2001,
        30000142,
        9001,
        60,
        vector[],
        vector[],
        vector[
            smart_industry::new_recipe_slot(10, 1, 10),
            smart_industry::new_recipe_slot(10, 2, 20),
        ],
        vector[],
    );
}

#[test]
#[expected_failure(abort_code = smart_industry::EInvalidBlueprint)]
fun recipe_without_blueprint_rejected() {
    smart_industry::new_snapshot(
        2001,
        30000142,
        0,
        0,
        vector[],
        vector[],
        vector[smart_industry::new_recipe_slot(10, 1, 10)],
        vector[],
    );
}

#[test]
#[expected_failure(abort_code = smart_industry::EInvalidBlueprint)]
fun blueprint_without_runtime_rejected() {
    smart_industry::new_snapshot(2001, 30000142, 9001, 0, vector[], vector[], vector[], vector[]);
}

#[test]
#[expected_failure(abort_code = smart_industry::EInvalidIdentity)]
fun missing_owner_rejected() {
    smart_industry::new_snapshot(0, 30000142, 0, 0, vector[], vector[], vector[], vector[]);
}

#[test]
#[expected_failure(abort_code = smart_industry::EInvalidIdentity)]
fun missing_system_rejected() {
    smart_industry::new_snapshot(2001, 0, 0, 0, vector[], vector[], vector[], vector[]);
}

#[test]
fun production_upgrade_mirrors_paid_runs_and_stop_in_same_revision() {
    let mut ts = ts::begin(governor());
    let (parent, _) = setup(&mut ts);
    let industry_id = create_record(&mut ts, parent, admin(), 90_000);
    ts::next_tx(&mut ts, admin());
    let mut industry = ts::take_shared_by_id<SmartIndustry>(&ts, industry_id);
    smart_industry::remove_production_for_testing(&mut industry);
    assert!(!industry.has_production(), 0);
    assert_eq!(smart_industry::production_state(&industry.production()), 0);
    let assembly = ts::take_shared_by_id<Assembly>(&ts, parent);
    let acl = ts::take_shared<AdminACL>(&ts);
    let mut clock = clock::create_for_testing(ts.ctx());
    clock.set_for_testing(CHAIN_TIME);
    smart_industry::sync_with_production(
        &mut industry,
        &assembly,
        &acl,
        1,
        91_000,
        sample(5),
        smart_industry::new_production(8, 1, 3, 0, 91_000, 151_000, b"".to_string()),
        &clock,
        ts.ctx(),
    );
    assert!(industry.has_production(), 0);
    assert_eq!(industry.revision(), 2);
    assert_eq!(smart_industry::production_job_id(&industry.production()), 8);
    assert_eq!(smart_industry::production_state(&industry.production()), 1);
    assert_eq!(smart_industry::production_requested_runs(&industry.production()), 3);
    assert_eq!(smart_industry::item_quantity(&smart_industry::inputs(industry.snapshot())[0]), 5);
    smart_industry::sync_with_production(
        &mut industry,
        &assembly,
        &acl,
        2,
        92_000,
        sample(10),
        smart_industry::new_production(8, 2, 3, 1, 151_000, 211_000, b"".to_string()),
        &clock,
        ts.ctx(),
    );
    assert_eq!(smart_industry::production_state(&industry.production()), 2);
    assert_eq!(smart_industry::production_completed_runs(&industry.production()), 1);
    smart_industry::sync_with_production(
        &mut industry,
        &assembly,
        &acl,
        3,
        93_000,
        sample(10),
        smart_industry::new_production(8, 3, 3, 2, 151_000, 211_000, b"DISCONTINUED".to_string()),
        &clock,
        ts.ctx(),
    );
    assert_eq!(industry.revision(), 4);
    assert_eq!(smart_industry::production_completed_runs(&industry.production()), 2);
    assert_eq!(
        smart_industry::production_stop_reason(&industry.production()),
        b"DISCONTINUED".to_string(),
    );
    clock.destroy_for_testing();
    ts::return_shared(acl);
    ts::return_shared(assembly);
    ts::return_shared(industry);
    ts.end();
}

#[test]
fun production_accepts_continuous_and_completed_batches() {
    let continuous = smart_industry::new_production(1, 1, 0, 100, 1, 2, b"".to_string());
    assert_eq!(smart_industry::production_requested_runs(&continuous), 0);
    let completed = smart_industry::new_production(2, 3, 3, 3, 1, 2, b"COMPLETED".to_string());
    assert_eq!(smart_industry::production_state(&completed), 3);
}

#[test]
#[expected_failure(abort_code = smart_industry::EInvalidProduction)]
fun production_rejects_running_finished_batch() {
    smart_industry::new_production(1, 1, 3, 3, 1, 2, b"".to_string());
}

#[test]
#[expected_failure(abort_code = smart_industry::EInvalidProduction)]
fun production_rejects_early_completion() {
    smart_industry::new_production(1, 3, 3, 2, 1, 2, b"COMPLETED".to_string());
}

#[test]
#[expected_failure(abort_code = smart_industry::EInvalidProduction)]
fun production_rejects_invalid_deadline() {
    smart_industry::new_production(1, 1, 3, 0, 2, 2, b"".to_string());
}

#[test]
#[expected_failure(abort_code = smart_industry::EInvalidProduction)]
fun production_rejects_invalid_reason_token() {
    smart_industry::new_production(1, 3, 3, 0, 1, 2, b"manual".to_string());
}

#[test]
#[expected_failure(abort_code = access::EUnauthorizedSponsor)]
fun production_sync_rejects_unauthorized_writer() {
    let mut ts = ts::begin(governor());
    let (parent, _) = setup(&mut ts);
    let industry_id = create_record(&mut ts, parent, admin(), 90_000);
    ts::next_tx(&mut ts, @0xDEAD);
    let mut industry = ts::take_shared_by_id<SmartIndustry>(&ts, industry_id);
    let assembly = ts::take_shared_by_id<Assembly>(&ts, parent);
    let acl = ts::take_shared<AdminACL>(&ts);
    let clock = clock::create_for_testing(ts.ctx());
    smart_industry::sync_with_production(
        &mut industry,
        &assembly,
        &acl,
        1,
        91_000,
        sample(5),
        smart_industry::new_production(1, 1, 3, 0, 1, 2, b"".to_string()),
        &clock,
        ts.ctx(),
    );
    clock.destroy_for_testing();
    ts::return_shared(acl);
    ts::return_shared(assembly);
    ts::return_shared(industry);
    ts.end();
}
