#[test_only]
module world_logistics_actions::logistics_actions_tests;

use std::{string::utf8, unit_test::assert_eq};
use sui::{clock, test_scenario as ts};
use world::{
    access::{OwnerCap, ServerAddressRegistry},
    character::{Self, Character},
    object_registry::ObjectRegistry,
    test_helpers::{Self, admin, governor, server_admin, tenant, user_a},
};
use world_action_queue::action_queue::{Self, Action, ActionQueueRegistry, AssemblyActionQueue};
use world_logistics_actions::logistics_actions::{
    Self,
    AssemblyTransferRoot,
    LogisticsRegistry,
    TransferIntent,
};

const TRANSFER_ID: vector<u8> = x"44444444444444448444444444444444";
const RECEIPT: vector<u8> =
    x"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";

fun setup(scenario: &mut ts::Scenario): ID {
    action_queue::init_for_testing(scenario.ctx());
    logistics_actions::init_for_testing(scenario.ctx());
    test_helpers::setup_world(scenario);
    test_helpers::register_server_address(scenario);
    ts::next_tx(scenario, admin());
    let mut registry = ts::take_shared<ObjectRegistry>(scenario);
    let acl = ts::take_shared<world::access::AdminACL>(scenario);
    let character = character::create_character(
        &mut registry,
        &acl,
        4100,
        tenant(),
        100,
        user_a(),
        utf8(b"Logistics owner"),
        scenario.ctx(),
    );
    let character_id = character.id();
    character.share_character(&acl, scenario.ctx());
    ts::return_shared(registry);
    ts::return_shared(acl);
    character_id
}

#[test]
fun portable_transfer_uses_two_phase_settlement() {
    let mut scenario = ts::begin(governor());
    let source_id = setup(&mut scenario);
    let destination_id = object::id_from_address(@0x777);

    ts::next_tx(&mut scenario, user_a());
    let mut action_registry = ts::take_shared<ActionQueueRegistry>(&scenario);
    let mut logistics_registry = ts::take_shared<LogisticsRegistry>(&scenario);
    let mut character = ts::take_shared_by_id<Character>(&scenario, source_id);
    let (owner_cap, receipt) = character.borrow_owner_cap<Character>(
        ts::most_recent_receiving_ticket<OwnerCap<Character>>(&source_id),
        scenario.ctx(),
    );
    action_queue::create_queue<Character>(
        &mut action_registry,
        source_id,
        &owner_cap,
        scenario.ctx(),
    );
    logistics_actions::create_root<Character>(
        &mut logistics_registry,
        source_id,
        &owner_cap,
        scenario.ctx(),
    );
    let queue_id = action_queue::queue_object_id(&action_registry, source_id);
    let root_id = logistics_actions::root_object_id(&logistics_registry, source_id);
    character.return_owner_cap(owner_cap, receipt);
    ts::return_shared(character);
    ts::return_shared(action_registry);
    ts::return_shared(logistics_registry);

    ts::next_tx(&mut scenario, user_a());
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock.set_for_testing(1_000);
    let mut queue = ts::take_shared_by_id<AssemblyActionQueue>(&scenario, queue_id);
    let mut root = ts::take_shared_by_id<AssemblyTransferRoot>(&scenario, root_id);
    let mut character = ts::take_shared_by_id<Character>(&scenario, source_id);
    let (owner_cap, receipt) = character.borrow_owner_cap<Character>(
        ts::most_recent_receiving_ticket<OwnerCap<Character>>(&source_id),
        scenario.ctx(),
    );
    let command = logistics_actions::new_transfer(
        TRANSFER_ID,
        source_id,
        destination_id,
        logistics_actions::ship_endpoint(),
        logistics_actions::field_storage_endpoint(),
        34,
        50,
        7,
        11,
    );
    logistics_actions::prepare_transfer<Character>(
        &mut root,
        &mut queue,
        &owner_cap,
        command,
        action_queue::normal_priority(),
        2,
        20_000,
        &clock,
        scenario.ctx(),
    );
    let action_id = action_queue::action_object_id(&queue, TRANSFER_ID);
    let intent_id = logistics_actions::intent_object_id(&root, TRANSFER_ID);
    character.return_owner_cap(owner_cap, receipt);
    ts::return_shared(character);
    ts::return_shared(queue);
    ts::return_shared(root);
    clock.destroy_for_testing();

    ts::next_tx(&mut scenario, server_admin());
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock.set_for_testing(2_000);
    let server_registry = ts::take_shared<ServerAddressRegistry>(&scenario);
    let mut action = ts::take_shared_by_id<Action>(&scenario, action_id);
    let mut intent = ts::take_shared_by_id<TransferIntent>(&scenario, intent_id);
    logistics_actions::begin_settlement(
        &mut intent,
        &mut action,
        &server_registry,
        1_000,
        &clock,
        scenario.ctx(),
    );
    assert_eq!(logistics_actions::state(&intent), logistics_actions::settling_state());
    logistics_actions::settle_transfer(
        &mut intent,
        &mut action,
        &server_registry,
        50,
        8,
        12,
        RECEIPT,
        &clock,
        scenario.ctx(),
    );
    assert_eq!(logistics_actions::state(&intent), logistics_actions::settled_state());
    assert_eq!(logistics_actions::settled_quantity(&intent), 50);
    assert_eq!(action_queue::status(&action), action_queue::fulfilled_status());
    ts::return_shared(server_registry);
    ts::return_shared(action);
    ts::return_shared(intent);
    clock.destroy_for_testing();
    scenario.end();
}
