#[test_only]
module world_automation::automation_tests;

use std::{string::utf8, unit_test::assert_eq};
use sui::{clock, test_scenario as ts};
use world::{
    access::{OwnerCap, ServerAddressRegistry},
    character::{Self, Character},
    object_registry::ObjectRegistry,
    test_helpers::{Self, admin, governor, server_admin, tenant, user_a},
};
use world_action_queue::action_queue::{Self, Action, ActionQueueRegistry, AssemblyActionQueue};
use world_automation::automation::{Self, AssemblyAutomationRoot, Automation, AutomationRegistry};

const AUTOMATION_ID: vector<u8> = x"6666666666664666a666666666666666";
const ACTION_ID: vector<u8> = x"7777777777774777a777777777777777";

fun setup(scenario: &mut ts::Scenario): ID {
    action_queue::init_for_testing(scenario.ctx());
    automation::init_for_testing(scenario.ctx());
    test_helpers::setup_world(scenario);
    test_helpers::register_server_address(scenario);
    ts::next_tx(scenario, admin());
    let mut registry = ts::take_shared<ObjectRegistry>(scenario);
    let acl = ts::take_shared<world::access::AdminACL>(scenario);
    let character = character::create_character(
        &mut registry,
        &acl,
        6100,
        tenant(),
        100,
        user_a(),
        utf8(b"Automation owner"),
        scenario.ctx(),
    );
    let character_id = character.id();
    character.share_character(&acl, scenario.ctx());
    ts::return_shared(registry);
    ts::return_shared(acl);
    character_id
}

#[test]
fun keeper_advances_bounded_workflow_and_records_completion() {
    let mut scenario = ts::begin(governor());
    let assembly_id = setup(&mut scenario);

    ts::next_tx(&mut scenario, user_a());
    let mut action_registry = ts::take_shared<ActionQueueRegistry>(&scenario);
    let mut automation_registry = ts::take_shared<AutomationRegistry>(&scenario);
    let mut character = ts::take_shared_by_id<Character>(&scenario, assembly_id);
    let (owner_cap, receipt) = character.borrow_owner_cap<Character>(
        ts::most_recent_receiving_ticket<OwnerCap<Character>>(&assembly_id),
        scenario.ctx(),
    );
    action_queue::create_queue<Character>(
        &mut action_registry,
        assembly_id,
        &owner_cap,
        scenario.ctx(),
    );
    automation::create_root<Character>(
        &mut automation_registry,
        assembly_id,
        &owner_cap,
        scenario.ctx(),
    );
    let queue_id = action_queue::queue_object_id(&action_registry, assembly_id);
    let root_id = automation::root_object_id(&automation_registry, assembly_id);
    character.return_owner_cap(owner_cap, receipt);
    ts::return_shared(character);
    ts::return_shared(action_registry);
    ts::return_shared(automation_registry);

    ts::next_tx(&mut scenario, user_a());
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock.set_for_testing(1_000);
    let mut root = ts::take_shared_by_id<AssemblyAutomationRoot>(&scenario, root_id);
    let mut character = ts::take_shared_by_id<Character>(&scenario, assembly_id);
    let (owner_cap, receipt) = character.borrow_owner_cap<Character>(
        ts::most_recent_receiving_ticket<OwnerCap<Character>>(&assembly_id),
        scenario.ctx(),
    );
    let step = automation::new_step(
        assembly_id,
        b"infrastructure.refuel",
        b"payload",
        vector[],
        0,
        10_000,
        2,
        500,
        automation::no_signal(),
        action_queue::normal_priority(),
        8,
    );
    automation::create_automation<Character>(
        &mut root,
        &owner_cap,
        AUTOMATION_ID,
        10_000,
        vector[step],
        &clock,
        scenario.ctx(),
    );
    let workflow_id = automation::automation_object_id(&root, AUTOMATION_ID);
    character.return_owner_cap(owner_cap, receipt);
    ts::return_shared(character);
    ts::return_shared(root);
    clock.destroy_for_testing();

    ts::next_tx(&mut scenario, user_a());
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock.set_for_testing(1_100);
    let mut workflow = ts::take_shared_by_id<Automation>(&scenario, workflow_id);
    let mut character = ts::take_shared_by_id<Character>(&scenario, assembly_id);
    let (owner_cap, receipt) = character.borrow_owner_cap<Character>(
        ts::most_recent_receiving_ticket<OwnerCap<Character>>(&assembly_id),
        scenario.ctx(),
    );
    automation::activate<Character>(&mut workflow, &owner_cap, &clock, scenario.ctx());
    character.return_owner_cap(owner_cap, receipt);
    ts::return_shared(character);
    ts::return_shared(workflow);
    clock.destroy_for_testing();

    ts::next_tx(&mut scenario, server_admin());
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock.set_for_testing(1_200);
    let mut workflow = ts::take_shared_by_id<Automation>(&scenario, workflow_id);
    let mut queue = ts::take_shared_by_id<AssemblyActionQueue>(&scenario, queue_id);
    let server_registry = ts::take_shared<ServerAddressRegistry>(&scenario);
    automation::advance(
        &mut workflow,
        &mut queue,
        &server_registry,
        0,
        ACTION_ID,
        vector[],
        vector[],
        0,
        5_000,
        &clock,
        scenario.ctx(),
    );
    let action_id = action_queue::action_object_id(&queue, ACTION_ID);
    assert_eq!(automation::step_status(&workflow, 0), automation::step_queued_status());
    ts::return_shared(workflow);
    ts::return_shared(queue);
    ts::return_shared(server_registry);
    clock.destroy_for_testing();

    ts::next_tx(&mut scenario, server_admin());
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock.set_for_testing(1_300);
    let mut workflow = ts::take_shared_by_id<Automation>(&scenario, workflow_id);
    let mut action = ts::take_shared_by_id<Action>(&scenario, action_id);
    let server_registry = ts::take_shared<ServerAddressRegistry>(&scenario);
    action_queue::claim_server_action(
        &mut action,
        &server_registry,
        1_000,
        &clock,
        scenario.ctx(),
    );
    action_queue::complete_server_action(
        &mut action,
        &server_registry,
        true,
        b"done",
        &clock,
        scenario.ctx(),
    );
    automation::record_step_result(
        &mut workflow,
        0,
        &action,
        &server_registry,
        &clock,
        scenario.ctx(),
    );
    assert_eq!(automation::step_status(&workflow, 0), automation::step_succeeded_status());
    assert_eq!(automation::status(&workflow), automation::succeeded_status());
    ts::return_shared(workflow);
    ts::return_shared(action);
    ts::return_shared(server_registry);
    clock.destroy_for_testing();
    scenario.end();
}
