#[test_only]
module world_action_queue::action_queue_tests;

use std::{string::utf8, unit_test::assert_eq};
use sui::{clock, derived_object, test_scenario as ts};
use world::{
    access::OwnerCap,
    character::{Self, Character},
    object_registry::ObjectRegistry,
    test_helpers::{Self, admin, governor, tenant, user_a},
};
use world_action_queue::action_queue::{
    Self,
    Action,
    ActionQueueRegistry,
    AssemblyActionQueue,
};

const CHARACTER_ITEM_ID: u32 = 1234;
const ACTION_ID: vector<u8> = x"22222222222242228222222222222222";
const COMMITMENT: vector<u8> =
    x"1111111111111111111111111111111111111111111111111111111111111111";

fun setup(scenario: &mut ts::Scenario): ID {
    action_queue::init_for_testing(scenario.ctx());
    test_helpers::setup_world(scenario);
    ts::next_tx(scenario, admin());
    let mut registry = ts::take_shared<ObjectRegistry>(scenario);
    let acl = ts::take_shared<world::access::AdminACL>(scenario);
    let character = character::create_character(
        &mut registry,
        &acl,
        CHARACTER_ITEM_ID,
        tenant(),
        100,
        user_a(),
        utf8(b"Queue Tester"),
        scenario.ctx(),
    );
    let id = character.id();
    character.share_character(&acl, scenario.ctx());
    ts::return_shared(registry);
    ts::return_shared(acl);
    id
}

#[test]
fun owner_action_is_deterministic_and_can_be_completed() {
    let mut scenario = ts::begin(governor());
    let character_id = setup(&mut scenario);

    ts::next_tx(&mut scenario, user_a());
    let mut registry = ts::take_shared<ActionQueueRegistry>(&scenario);
    let mut character = ts::take_shared_by_id<Character>(&scenario, character_id);
    let (owner_cap, receipt) = character.borrow_owner_cap<Character>(
        ts::most_recent_receiving_ticket<OwnerCap<Character>>(&character_id),
        scenario.ctx(),
    );
    action_queue::create_queue<Character>(
        &mut registry,
        character_id,
        &owner_cap,
        scenario.ctx(),
    );
    let queue_id = action_queue::queue_object_id(&registry, character_id);
    character.return_owner_cap(owner_cap, receipt);
    ts::return_shared(character);
    ts::return_shared(registry);

    ts::next_tx(&mut scenario, user_a());
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock.set_for_testing(1_000);
    let mut queue = ts::take_shared_by_id<AssemblyActionQueue>(&scenario, queue_id);
    let mut character = ts::take_shared_by_id<Character>(&scenario, character_id);
    let (owner_cap, receipt) = character.borrow_owner_cap<Character>(
        ts::most_recent_receiving_ticket<OwnerCap<Character>>(&character_id),
        scenario.ctx(),
    );
    action_queue::queue_action<Character>(
        &mut queue,
        character_id,
        &owner_cap,
        ACTION_ID,
        b"intelligence.remote-scan.execute",
        b"{}",
        COMMITMENT,
        action_queue::normal_priority(),
        258,
        10_000,
        &clock,
        scenario.ctx(),
    );
    let action_id = object::id_from_address(
        derived_object::derive_address(object::id(&queue), action_queue::action_key(ACTION_ID)),
    );
    assert_eq!(action_queue::action_object_id(&queue, ACTION_ID), action_id);
    character.return_owner_cap(owner_cap, receipt);
    ts::return_shared(character);
    ts::return_shared(queue);
    clock.destroy_for_testing();

    ts::next_tx(&mut scenario, user_a());
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock.set_for_testing(2_000);
    let mut character = ts::take_shared_by_id<Character>(&scenario, character_id);
    let mut action = ts::take_shared_by_id<Action>(&scenario, action_id);
    let (owner_cap, receipt) = character.borrow_owner_cap<Character>(
        ts::most_recent_receiving_ticket<OwnerCap<Character>>(&character_id),
        scenario.ctx(),
    );
    assert_eq!(action_queue::action_id(&action), ACTION_ID);
    assert_eq!(action_queue::status(&action), action_queue::queued_status());
    assert_eq!(action_queue::priority_flags(&action), 258);
    action_queue::claim_action<Character>(&mut action, &owner_cap, 1_000, &clock, scenario.ctx());
    assert_eq!(action_queue::status(&action), action_queue::claimed_status());
    action_queue::complete_action<Character>(
        &mut action,
        &owner_cap,
        true,
        b"done",
        &clock,
        scenario.ctx(),
    );
    assert_eq!(action_queue::status(&action), action_queue::fulfilled_status());
    assert_eq!(*action_queue::outcome(&action), b"done");
    assert_eq!(action_queue::receipt_commitment(&action).length(), 32);
    character.return_owner_cap(owner_cap, receipt);
    ts::return_shared(action);
    ts::return_shared(character);
    clock.destroy_for_testing();
    scenario.end();
}
