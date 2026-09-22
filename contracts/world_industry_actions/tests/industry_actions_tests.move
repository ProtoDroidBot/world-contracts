#[test_only]
module world_industry_actions::industry_actions_tests;

use std::unit_test::assert_eq;
use sui::{clock, test_scenario as ts};
use world::{
    access::{AdminACL, OwnerCap},
    assembly::{Self, Assembly},
    character::{Self, Character},
    network_node::{Self, NetworkNode},
    object_registry::ObjectRegistry,
    test_helpers::{Self, admin, governor, tenant, user_a},
};
use world_action_queue::action_queue::{
    Self,
    Action,
    ActionQueueRegistry,
    AssemblyActionQueue,
};
use world_industry_actions::industry_actions::{Self, IndustryActionRegistry};
use world_smart_industry::smart_industry::{Self, SmartIndustry, SmartIndustryRegistry};

const LOCATION_HASH: vector<u8> =
    x"7a8f3b2e9c4d1a6f5e8b2d9c3f7a1e5b7a8f3b2e9c4d1a6f5e8b2d9c3f7a1e5b";
const BLUEPRINT_HASH: vector<u8> =
    x"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
const ACTION_ID: vector<u8> = x"33333333333343338333333333333333";

fun setup(scenario: &mut ts::Scenario): ID {
    action_queue::init_for_testing(scenario.ctx());
    industry_actions::init_for_testing(scenario.ctx());
    smart_industry::init_for_testing(scenario.ctx());
    test_helpers::setup_world(scenario);
    ts::next_tx(scenario, admin());
    let mut object_registry = ts::take_shared<ObjectRegistry>(scenario);
    let acl = ts::take_shared<AdminACL>(scenario);
    let character = character::create_character(
        &mut object_registry,
        &acl,
        2001,
        tenant(),
        100,
        user_a(),
        b"Industry owner".to_string(),
        scenario.ctx(),
    );
    let mut node = network_node::anchor(
        &mut object_registry,
        &character,
        &acl,
        5000,
        111000,
        LOCATION_HASH,
        1000,
        3_600_000,
        100,
        scenario.ctx(),
    );
    let assembly = assembly::anchor(
        &mut object_registry,
        &mut node,
        &character,
        &acl,
        1001,
        8888,
        LOCATION_HASH,
        scenario.ctx(),
    );
    let assembly_id = object::id(&assembly);
    assembly.share_assembly(&acl, scenario.ctx());
    node.share_network_node(&acl, scenario.ctx());
    character.share_character(&acl, scenario.ctx());
    ts::return_shared(acl);
    ts::return_shared(object_registry);
    assembly_id
}

fun create_industry(scenario: &mut ts::Scenario, assembly_id: ID): ID {
    ts::next_tx(scenario, admin());
    let mut registry = ts::take_shared<SmartIndustryRegistry>(scenario);
    let assembly = ts::take_shared_by_id<Assembly>(scenario, assembly_id);
    let acl = ts::take_shared<AdminACL>(scenario);
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock.set_for_testing(100_000);
    smart_industry::create(
        &mut registry,
        &assembly,
        &acl,
        90_000,
        smart_industry::new_snapshot(
            2001,
            30000142,
            9001,
            60,
            vector[],
            vector[],
            vector[smart_industry::new_recipe_slot(10, 5, 500)],
            vector[smart_industry::new_recipe_slot(20, 1, 100)],
        ),
        &clock,
        scenario.ctx(),
    );
    let industry_id = object::id_from_address(
        sui::derived_object::derive_address(
            object::id(&registry),
            smart_industry::new_industry_key(assembly_id),
        ),
    );
    clock.destroy_for_testing();
    ts::return_shared(acl);
    ts::return_shared(assembly);
    ts::return_shared(registry);
    industry_id
}

fun create_action_queue(scenario: &mut ts::Scenario, assembly_id: ID): ID {
    ts::next_tx(scenario, user_a());
    let mut registry = ts::take_shared<ActionQueueRegistry>(scenario);
    let mut character = ts::take_shared<Character>(scenario);
    let character_id = object::id(&character);
    let (owner_cap, receipt) = character.borrow_owner_cap<Assembly>(
        ts::most_recent_receiving_ticket<OwnerCap<Assembly>>(&character_id),
        scenario.ctx(),
    );
    action_queue::create_queue<Assembly>(
        &mut registry,
        assembly_id,
        &owner_cap,
        scenario.ctx(),
    );
    let queue_id = action_queue::queue_object_id(&registry, assembly_id);
    character.return_owner_cap(owner_cap, receipt);
    ts::return_shared(character);
    ts::return_shared(registry);
    queue_id
}

#[test]
fun queues_typed_start_against_current_industry_revision() {
    let mut scenario = ts::begin(governor());
    let assembly_id = setup(&mut scenario);
    let industry_id = create_industry(&mut scenario, assembly_id);
    let queue_id = create_action_queue(&mut scenario, assembly_id);

    ts::next_tx(&mut scenario, user_a());
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock.set_for_testing(100_000);
    let mut action_queue_root = ts::take_shared_by_id<AssemblyActionQueue>(&scenario, queue_id);
    let industry_action_registry = ts::take_shared<IndustryActionRegistry>(&scenario);
    let industry = ts::take_shared_by_id<SmartIndustry>(&scenario, industry_id);
    let mut character = ts::take_shared<Character>(&scenario);
    let character_id = object::id(&character);
    let (owner_cap, receipt) = character.borrow_owner_cap<Assembly>(
        ts::most_recent_receiving_ticket<OwnerCap<Assembly>>(&character_id),
        scenario.ctx(),
    );
    let command = industry_actions::start_command(
        assembly_id,
        1,
        1,
        9001,
        BLUEPRINT_HASH,
        5,
    );
    industry_actions::queue_command<Assembly>(
        &mut action_queue_root,
        &industry_action_registry,
        &industry,
        &owner_cap,
        ACTION_ID,
        command,
        action_queue::normal_priority(),
        18,
        200_000,
        &clock,
        scenario.ctx(),
    );
    let queued_id = action_queue::action_object_id(&action_queue_root, ACTION_ID);
    character.return_owner_cap(owner_cap, receipt);
    ts::return_shared(character);
    ts::return_shared(industry);
    ts::return_shared(industry_action_registry);
    ts::return_shared(action_queue_root);
    clock.destroy_for_testing();

    ts::next_tx(&mut scenario, user_a());
    let action = ts::take_shared_by_id<Action>(&scenario, queued_id);
    assert_eq!(action_queue::source(&action), assembly_id);
    assert_eq!(action_queue::target(&action), assembly_id);
    assert_eq!(*action_queue::action_type(&action), b"industry.start");
    assert!(!action_queue::payload(&action).is_empty(), 0);
    assert_eq!(action_queue::status(&action), action_queue::queued_status());
    ts::return_shared(action);
    scenario.end();
}
