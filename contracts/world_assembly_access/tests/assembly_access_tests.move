#[test_only]
module world_assembly_access::assembly_access_tests;

use std::{string::utf8, unit_test::assert_eq};
use sui::{clock, derived_object, test_scenario as ts};
use world::{
    access::{AdminACL, OwnerCap},
    character::{Self, Character},
    object_registry::ObjectRegistry,
    test_helpers::{Self, admin, governor, tenant, user_a},
};
use world_assembly_access::assembly_access::{
    Self,
    AssemblyAccessGrant,
    AssemblyAccessPolicy,
    AssemblyAccessRegistry,
};

const CHARACTER_ITEM_ID: u32 = 1234;
const GRANT_ID: vector<u8> = x"11111111111141118111111111111111";

fun create_character(scenario: &mut ts::Scenario): ID {
    assembly_access::init_for_testing(scenario.ctx());
    ts::next_tx(scenario, admin());
    let mut registry = ts::take_shared<ObjectRegistry>(scenario);
    let acl = ts::take_shared<AdminACL>(scenario);
    let character = character::create_character(
        &mut registry,
        &acl,
        CHARACTER_ITEM_ID,
        tenant(),
        100,
        user_a(),
        utf8(b"Access Tester"),
        scenario.ctx(),
    );
    let id = character.id();
    character.share_character(&acl, scenario.ctx());
    ts::return_shared(registry);
    ts::return_shared(acl);
    id
}

#[test]
fun owner_grant_is_deterministic_and_recipient_can_relinquish() {
    let mut scenario = ts::begin(governor());
    test_helpers::setup_world(&mut scenario);
    let character_id = create_character(&mut scenario);

    ts::next_tx(&mut scenario, user_a());
    let mut registry = ts::take_shared<ObjectRegistry>(&scenario);
    let mut access_registry = ts::take_shared<AssemblyAccessRegistry>(&scenario);
    let mut character = ts::take_shared_by_id<Character>(&scenario, character_id);
    let (owner_cap, receipt) = character.borrow_owner_cap<Character>(
        ts::most_recent_receiving_ticket<OwnerCap<Character>>(&character_id),
        scenario.ctx(),
    );
    assembly_access::create_policy<Character>(
        &mut registry,
        &mut access_registry,
        character_id,
        &owner_cap,
        scenario.ctx(),
    );
    let policy_id = object::id_from_address(derived_object::derive_address(
        object::id(&access_registry),
        assembly_access::policy_key(character_id),
    ));
    character.return_owner_cap(owner_cap, receipt);
    ts::return_shared(character);
    ts::return_shared(registry);
    ts::return_shared(access_registry);

    ts::next_tx(&mut scenario, user_a());
    let clock = clock::create_for_testing(scenario.ctx());
    let mut registry = ts::take_shared<ObjectRegistry>(&scenario);
    let mut policy = ts::take_shared_by_id<AssemblyAccessPolicy>(&scenario, policy_id);
    let mut character = ts::take_shared_by_id<Character>(&scenario, character_id);
    let (owner_cap, receipt) = character.borrow_owner_cap<Character>(
        ts::most_recent_receiving_ticket<OwnerCap<Character>>(&character_id),
        scenario.ctx(),
    );
    assembly_access::grant_by_owner<Character>(
        &mut registry,
        &mut policy,
        &owner_cap,
        GRANT_ID,
        assembly_access::player_principal(),
        CHARACTER_ITEM_ID.to_string(),
        assembly_access::gui_view_capability() | assembly_access::manage_access_capability(),
        0,
        b"".to_string(),
        10_000,
        true,
        2,
        &clock,
        scenario.ctx(),
    );
    let grant_id = object::id_from_address(derived_object::derive_address(
        policy_id,
        assembly_access::grant_key(policy_id, GRANT_ID),
    ));
    assert_eq!(assembly_access::policy_revision(&policy), 2);
    character.return_owner_cap(owner_cap, receipt);
    ts::return_shared(character);
    ts::return_shared(policy);
    ts::return_shared(registry);
    clock.destroy_for_testing();

    ts::next_tx(&mut scenario, user_a());
    let mut policy = ts::take_shared_by_id<AssemblyAccessPolicy>(&scenario, policy_id);
    let mut grant = ts::take_shared_by_id<AssemblyAccessGrant>(&scenario, grant_id);
    let character = ts::take_shared_by_id<Character>(&scenario, character_id);
    assert_eq!(assembly_access::grant_identifier(&grant), GRANT_ID);
    assert_eq!(assembly_access::grant_policy_id(&grant), policy_id);
    assert_eq!(assembly_access::grant_assembly_id(&grant), character_id);
    assert_eq!(assembly_access::recipient_kind(&grant), assembly_access::player_principal());
    assert_eq!(assembly_access::recipient_id(&grant), CHARACTER_ITEM_ID.to_string());
    assembly_access::revoke_by_character(
        &mut policy,
        &mut grant,
        &character,
        2,
        1,
        scenario.ctx(),
    );
    assert!(assembly_access::is_revoked(&grant), 0);
    assert_eq!(assembly_access::policy_revision(&policy), 3);
    assert_eq!(assembly_access::grant_revision(&grant), 2);
    ts::return_shared(character);
    ts::return_shared(grant);
    ts::return_shared(policy);
    scenario.end();
}
