#[test_only]
module world_catapult::catapult_tests;

use std::unit_test::assert_eq;
use sui::{clock, derived_object, test_scenario as ts};
use world::{
    access::{AdminACL, OwnerCap},
    character::{Self, Character},
    energy::EnergyConfig,
    gate::{Self, Gate, GateConfig},
    network_node::{Self, NetworkNode},
    object_registry::ObjectRegistry,
    test_helpers::{Self, admin, governor, tenant, user_a},
};
use world_catapult::catapult::{Self, Catapult, CatapultRegistry};

const CATAPULT_TYPE_ID: u64 = 95_627;
const NORMAL_GATE_TYPE_ID: u64 = 84_955;
const LOCATION_HASH: vector<u8> =
    x"7a8f3b2e9c4d1a6f5e8b2d9c3f7a1e5b7a8f3b2e9c4d1a6f5e8b2d9c3f7a1e5b";
const SOURCE_SYSTEM: u64 = 30_000_004;
const DESTINATION_SYSTEM: u64 = 30_000_006;
const MAX_DISTANCE: u64 = 1000;
const CATAPULT_ENERGY: u64 = 50;

fun setup(ts: &mut ts::Scenario, type_id: u64): (ID, ID, ID) {
    catapult::init_for_testing(ts.ctx());
    test_helpers::setup_world(ts);
    gate::init_for_testing(ts.ctx());

    ts::next_tx(ts, admin());
    let mut registry = ts::take_shared<ObjectRegistry>(ts);
    let acl = ts::take_shared<AdminACL>(ts);
    let mut gate_config = ts::take_shared<GateConfig>(ts);
    let mut energy_config = ts::take_shared<EnergyConfig>(ts);
    gate::set_max_distance(&mut gate_config, &acl, type_id, MAX_DISTANCE, ts.ctx());
    energy_config.set_energy_config(&acl, type_id, CATAPULT_ENERGY, ts.ctx());
    let character = character::create_character(
        &mut registry,
        &acl,
        2001,
        tenant(),
        100,
        user_a(),
        b"Catapult owner".to_string(),
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
        3_600_000,
        100,
        ts.ctx(),
    );
    let gate = gate::anchor(
        &mut registry,
        &mut node,
        &character,
        &acl,
        7001,
        type_id,
        LOCATION_HASH,
        ts.ctx(),
    );
    let character_id = object::id(&character);
    let node_id = object::id(&node);
    let gate_id = object::id(&gate);
    gate.share_gate(&acl, ts.ctx());
    node.share_network_node(&acl, ts.ctx());
    character.share_character(&acl, ts.ctx());
    ts::return_shared(gate_config);
    ts::return_shared(energy_config);
    ts::return_shared(acl);
    ts::return_shared(registry);
    (character_id, node_id, gate_id)
}

fun bring_catapult_online(ts: &mut ts::Scenario, character_id: ID, node_id: ID, gate_id: ID) {
    ts::next_tx(ts, user_a());
    let clock = clock::create_for_testing(ts.ctx());
    let mut node = ts::take_shared_by_id<NetworkNode>(ts, node_id);
    let mut gate = ts::take_shared_by_id<Gate>(ts, gate_id);
    let mut character = ts::take_shared_by_id<Character>(ts, character_id);
    let energy_config = ts::take_shared<EnergyConfig>(ts);
    let (node_cap, node_receipt) = character.borrow_owner_cap<NetworkNode>(
        ts::receiving_ticket_by_id<OwnerCap<NetworkNode>>(node.owner_cap_id()),
        ts.ctx(),
    );
    node.deposit_fuel_test(&node_cap, 1, 10, 10, &clock);
    node.online(&node_cap, &clock);
    character.return_owner_cap(node_cap, node_receipt);
    let (gate_cap, gate_receipt) = character.borrow_owner_cap<Gate>(
        ts::receiving_ticket_by_id<OwnerCap<Gate>>(gate.owner_cap_id()),
        ts.ctx(),
    );
    gate.online(&mut node, &energy_config, &gate_cap);
    character.return_owner_cap(gate_cap, gate_receipt);
    clock.destroy_for_testing();
    ts::return_shared(energy_config);
    ts::return_shared(character);
    ts::return_shared(gate);
    ts::return_shared(node);
}

fun create_route(ts: &mut ts::Scenario, gate_id: ID, destination: u64, distance: u64): ID {
    ts::next_tx(ts, admin());
    let mut registry = ts::take_shared<CatapultRegistry>(ts);
    let gate = ts::take_shared_by_id<Gate>(ts, gate_id);
    let gate_config = ts::take_shared<GateConfig>(ts);
    let acl = ts::take_shared<AdminACL>(ts);
    let mut clock = clock::create_for_testing(ts.ctx());
    clock.set_for_testing(100_000);
    let expected_id = object::id_from_address(derived_object::derive_address(
        object::id(&registry),
        catapult::new_catapult_key(gate_id),
    ));
    catapult::create(
        &mut registry,
        &gate,
        &gate_config,
        &acl,
        SOURCE_SYSTEM,
        destination,
        distance,
        &clock,
        ts.ctx(),
    );
    clock.destroy_for_testing();
    ts::return_shared(acl);
    ts::return_shared(gate_config);
    ts::return_shared(gate);
    ts::return_shared(registry);
    expected_id
}

#[test]
fun creates_one_way_route_and_clears_it_without_a_destination_gate() {
    let mut ts = ts::begin(governor());
    let (_, _, gate_id) = setup(&mut ts, CATAPULT_TYPE_ID);
    let catapult_id = create_route(&mut ts, gate_id, DESTINATION_SYSTEM, 750);

    ts::next_tx(&mut ts, admin());
    let catapult = ts::take_shared_by_id<Catapult>(&ts, catapult_id);
    assert_eq!(catapult.id(), catapult_id);
    assert_eq!(catapult.gate_id(), gate_id);
    assert_eq!(catapult.source_solar_system_id(), SOURCE_SYSTEM);
    assert_eq!(catapult.destination_solar_system_id(), option::some(DESTINATION_SYSTEM));
    assert_eq!(catapult.distance(), 750);
    assert_eq!(catapult.revision(), 1);
    assert_eq!(catapult.updated_at_ms(), 100_000);
    ts::return_shared(catapult);

    ts::next_tx(&mut ts, admin());
    let mut catapult = ts::take_shared_by_id<Catapult>(&ts, catapult_id);
    let gate = ts::take_shared_by_id<Gate>(&ts, gate_id);
    let gate_config = ts::take_shared<GateConfig>(&ts);
    let acl = ts::take_shared<AdminACL>(&ts);
    let mut clock = clock::create_for_testing(ts.ctx());
    clock.set_for_testing(110_000);
    catapult.sync_destination(
        &gate,
        &gate_config,
        &acl,
        1,
        SOURCE_SYSTEM,
        0,
        0,
        &clock,
        ts.ctx(),
    );
    assert_eq!(catapult.destination_solar_system_id(), option::none());
    assert_eq!(catapult.distance(), 0);
    assert_eq!(catapult.revision(), 2);
    assert_eq!(catapult.updated_at_ms(), 110_000);
    clock.destroy_for_testing();
    ts::return_shared(acl);
    ts::return_shared(gate_config);
    ts::return_shared(gate);
    ts::return_shared(catapult);
    ts::end(ts);
}

#[test]
fun jumps_to_the_configured_system_without_a_destination_gate() {
    let mut ts = ts::begin(governor());
    let (character_id, node_id, gate_id) = setup(&mut ts, CATAPULT_TYPE_ID);
    let catapult_id = create_route(&mut ts, gate_id, DESTINATION_SYSTEM, 750);
    bring_catapult_online(&mut ts, character_id, node_id, gate_id);

    ts::next_tx(&mut ts, admin());
    let catapult = ts::take_shared_by_id<Catapult>(&ts, catapult_id);
    let gate = ts::take_shared_by_id<Gate>(&ts, gate_id);
    let gate_config = ts::take_shared<GateConfig>(&ts);
    let character = ts::take_shared_by_id<Character>(&ts, character_id);
    let acl = ts::take_shared<AdminACL>(&ts);
    catapult.jump(&gate, &gate_config, &character, &acl, ts.ctx());
    ts::return_shared(acl);
    ts::return_shared(character);
    ts::return_shared(gate_config);
    ts::return_shared(gate);
    ts::return_shared(catapult);
    ts::end(ts);
}

#[test]
#[expected_failure(abort_code = catapult::EOutOfRange)]
fun rejects_destination_outside_the_type_range() {
    let mut ts = ts::begin(governor());
    let (_, _, gate_id) = setup(&mut ts, CATAPULT_TYPE_ID);
    create_route(&mut ts, gate_id, DESTINATION_SYSTEM, MAX_DISTANCE + 1);
    ts::end(ts);
}

#[test]
#[expected_failure(abort_code = catapult::ENotCatapultType)]
fun rejects_a_normal_smart_gate() {
    let mut ts = ts::begin(governor());
    let (_, _, gate_id) = setup(&mut ts, NORMAL_GATE_TYPE_ID);
    create_route(&mut ts, gate_id, DESTINATION_SYSTEM, 10);
    ts::end(ts);
}

#[test]
#[expected_failure(abort_code = catapult::EStaleRevision)]
fun stale_route_revision_cannot_overwrite_newer_state() {
    let mut ts = ts::begin(governor());
    let (_, _, gate_id) = setup(&mut ts, CATAPULT_TYPE_ID);
    let catapult_id = create_route(&mut ts, gate_id, DESTINATION_SYSTEM, 750);
    ts::next_tx(&mut ts, admin());
    let mut catapult = ts::take_shared_by_id<Catapult>(&ts, catapult_id);
    let gate = ts::take_shared_by_id<Gate>(&ts, gate_id);
    let gate_config = ts::take_shared<GateConfig>(&ts);
    let acl = ts::take_shared<AdminACL>(&ts);
    let clock = clock::create_for_testing(ts.ctx());
    catapult.sync_destination(
        &gate,
        &gate_config,
        &acl,
        0,
        SOURCE_SYSTEM,
        DESTINATION_SYSTEM,
        750,
        &clock,
        ts.ctx(),
    );
    clock.destroy_for_testing();
    ts::return_shared(acl);
    ts::return_shared(gate_config);
    ts::return_shared(gate);
    ts::return_shared(catapult);
    ts::end(ts);
}

#[test]
#[expected_failure(abort_code = catapult::EGateOffline)]
fun jump_requires_the_source_catapult_online() {
    let mut ts = ts::begin(governor());
    let (character_id, _, gate_id) = setup(&mut ts, CATAPULT_TYPE_ID);
    let catapult_id = create_route(&mut ts, gate_id, DESTINATION_SYSTEM, 750);
    ts::next_tx(&mut ts, admin());
    let catapult = ts::take_shared_by_id<Catapult>(&ts, catapult_id);
    let gate = ts::take_shared_by_id<Gate>(&ts, gate_id);
    let gate_config = ts::take_shared<GateConfig>(&ts);
    let character = ts::take_shared_by_id<Character>(&ts, character_id);
    let acl = ts::take_shared<AdminACL>(&ts);
    catapult.jump(&gate, &gate_config, &character, &acl, ts.ctx());
    ts::return_shared(acl);
    ts::return_shared(character);
    ts::return_shared(gate_config);
    ts::return_shared(gate);
    ts::return_shared(catapult);
    ts::end(ts);
}
