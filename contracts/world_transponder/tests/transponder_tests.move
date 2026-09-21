#[test_only]
module world_transponder::transponder_tests;

use std::unit_test::assert_eq;
use sui::{derived_object, test_scenario as ts};
use world::{
    access::AdminACL,
    character::{Self, Character},
    object_registry::ObjectRegistry,
    test_helpers::{Self, admin, governor, tenant, user_a, user_b}
};
use world_npc::npc::{Self, NpcProfile, NpcRegistry};
use world_transponder::transponder::{Self, TransponderCommitment, TransponderRegistry};

const HUMAN_A: u32 = 140_000_001;
const HUMAN_B: u32 = 140_000_002;
const NPC_ID: u32 = 1_500_000_000;
const TRIBE: u32 = 101;

fun first(): vector<u8> {
    x"1111111111111111111111111111111111111111111111111111111111111111"
}

fun second(): vector<u8> {
    x"2222222222222222222222222222222222222222222222222222222222222222"
}

fun setup(scenario: &mut ts::Scenario) {
    npc::init_for_testing(scenario.ctx());
    transponder::init_for_testing(scenario.ctx());
    test_helpers::setup_world(scenario);
}

fun create_character(scenario: &mut ts::Scenario, id: u32, tribe_id: u32, wallet: address): ID {
    ts::next_tx(scenario, admin());
    let mut registry = ts::take_shared<ObjectRegistry>(scenario);
    let acl = ts::take_shared<AdminACL>(scenario);
    let character = character::create_character(
        &mut registry,
        &acl,
        id,
        tenant(),
        tribe_id,
        wallet,
        b"Pilot".to_string(),
        scenario.ctx(),
    );
    let character_id = character.id();
    character.share_character(&acl, scenario.ctx());
    ts::return_shared(registry);
    ts::return_shared(acl);
    character_id
}

fun create_npc(scenario: &mut ts::Scenario): (ID, ID) {
    ts::next_tx(scenario, admin());
    let mut registry = ts::take_shared<ObjectRegistry>(scenario);
    let mut npc_registry = ts::take_shared<NpcRegistry>(scenario);
    let acl = ts::take_shared<AdminACL>(scenario);
    let character = npc::create_npc_character(
        &mut registry,
        &mut npc_registry,
        &acl,
        NPC_ID,
        tenant(),
        TRIBE,
        user_a(),
        b"Faction NPC".to_string(),
        500012,
        b"".to_string(),
        1,
        980_000_000_001,
        0,
        scenario.ctx(),
    );
    let character_id = character.id();
    let profile_id = character.npc_profile_id().destroy_some();
    character.share_character(&acl, scenario.ctx());
    ts::return_shared(registry);
    ts::return_shared(npc_registry);
    ts::return_shared(acl);
    (character_id, profile_id)
}

fun author_tribe(scenario: &mut ts::Scenario, character_id: ID): ID {
    ts::next_tx(scenario, user_a());
    let mut registry = ts::take_shared<ObjectRegistry>(scenario);
    let mut transponder_registry = ts::take_shared<TransponderRegistry>(scenario);
    let character = ts::take_shared_by_id<Character>(scenario, character_id);
    let record_id = object::id_from_address(
        derived_object::derive_address(
            object::id(&transponder_registry),
            transponder::tribe_scope_key(tenant(), TRIBE),
        ),
    );
    transponder::author_for_tribe(
        &mut registry,
        &mut transponder_registry,
        &character,
        first(),
        scenario.ctx(),
    );
    ts::return_shared(character);
    ts::return_shared(registry);
    ts::return_shared(transponder_registry);
    record_id
}

#[test]
fun tribe_record_is_deterministic_and_contains_only_commitment_metadata() {
    let mut scenario = ts::begin(governor());
    setup(&mut scenario);
    let character_id = create_character(&mut scenario, HUMAN_A, TRIBE, user_a());
    let record_id = author_tribe(&mut scenario, character_id);
    ts::next_tx(&mut scenario, user_a());
    let record = ts::take_shared_by_id<TransponderCommitment>(&scenario, record_id);
    assert_eq!(record.id(), record_id);
    assert_eq!(record.tenant(), tenant());
    assert_eq!(record.scope_kind(), transponder::tribe_scope());
    assert_eq!(record.scope_id(), TRIBE.to_string());
    assert_eq!(record.authority(), user_a());
    assert_eq!(record.hash_scheme(), transponder::blake2b_256_v1());
    assert_eq!(record.commitment(), first());
    assert_eq!(record.revision(), 1);
    assert!(!record.is_revoked(), 0);
    ts::return_shared(record);
    scenario.end();
}

#[test]
fun tribe_authority_can_rotate_revoke_and_reactivate() {
    let mut scenario = ts::begin(governor());
    setup(&mut scenario);
    let character_id = create_character(&mut scenario, HUMAN_A, TRIBE, user_a());
    let record_id = author_tribe(&mut scenario, character_id);
    ts::next_tx(&mut scenario, user_a());
    let character = ts::take_shared_by_id<Character>(&scenario, character_id);
    let mut record = ts::take_shared_by_id<TransponderCommitment>(&scenario, record_id);
    record.rotate_for_tribe(&character, 1, second(), scenario.ctx());
    assert_eq!(record.revision(), 2);
    assert_eq!(record.commitment(), second());
    record.revoke_for_tribe(&character, 2, scenario.ctx());
    assert_eq!(record.revision(), 3);
    assert!(record.commitment().is_empty(), 0);
    assert!(record.is_revoked(), 0);
    record.revoke_for_tribe(&character, 3, scenario.ctx());
    assert_eq!(record.revision(), 3);
    record.rotate_for_tribe(&character, 3, first(), scenario.ctx());
    assert_eq!(record.revision(), 4);
    assert!(!record.is_revoked(), 0);
    ts::return_shared(record);
    ts::return_shared(character);
    scenario.end();
}

#[test]
fun tribe_authority_can_be_transferred_only_to_a_member() {
    let mut scenario = ts::begin(governor());
    setup(&mut scenario);
    let first_character = create_character(&mut scenario, HUMAN_A, TRIBE, user_a());
    let second_character = create_character(&mut scenario, HUMAN_B, TRIBE, user_b());
    let record_id = author_tribe(&mut scenario, first_character);
    ts::next_tx(&mut scenario, user_a());
    let current = ts::take_shared_by_id<Character>(&scenario, first_character);
    let successor = ts::take_shared_by_id<Character>(&scenario, second_character);
    let mut record = ts::take_shared_by_id<TransponderCommitment>(&scenario, record_id);
    record.transfer_tribe_authority(&current, &successor, 1, scenario.ctx());
    assert_eq!(record.authority(), user_b());
    assert_eq!(record.revision(), 2);
    assert!(record.is_revoked(), 0);
    assert!(record.commitment().is_empty(), 0);
    ts::return_shared(record);
    ts::return_shared(current);
    ts::return_shared(successor);
    ts::next_tx(&mut scenario, user_b());
    let successor = ts::take_shared_by_id<Character>(&scenario, second_character);
    let mut record = ts::take_shared_by_id<TransponderCommitment>(&scenario, record_id);
    record.rotate_for_tribe(&successor, 2, second(), scenario.ctx());
    assert_eq!(record.revision(), 3);
    ts::return_shared(record);
    ts::return_shared(successor);
    scenario.end();
}

#[test]
#[expected_failure(abort_code = transponder::EUnauthorized)]
fun another_tribe_member_cannot_overwrite_the_authority() {
    let mut scenario = ts::begin(governor());
    setup(&mut scenario);
    let first_character = create_character(&mut scenario, HUMAN_A, TRIBE, user_a());
    let second_character = create_character(&mut scenario, HUMAN_B, TRIBE, user_b());
    let record_id = author_tribe(&mut scenario, first_character);
    ts::next_tx(&mut scenario, user_b());
    let character = ts::take_shared_by_id<Character>(&scenario, second_character);
    let mut record = ts::take_shared_by_id<TransponderCommitment>(&scenario, record_id);
    record.rotate_for_tribe(&character, 1, second(), scenario.ctx());
    abort 0
}

#[test]
#[expected_failure(abort_code = transponder::EScopeMismatch)]
fun tribe_authority_cannot_transfer_to_another_tribe() {
    let mut scenario = ts::begin(governor());
    setup(&mut scenario);
    let first_character = create_character(&mut scenario, HUMAN_A, TRIBE, user_a());
    let outsider = create_character(&mut scenario, HUMAN_B, TRIBE + 1, user_b());
    let record_id = author_tribe(&mut scenario, first_character);
    ts::next_tx(&mut scenario, user_a());
    let current = ts::take_shared_by_id<Character>(&scenario, first_character);
    let outsider = ts::take_shared_by_id<Character>(&scenario, outsider);
    let mut record = ts::take_shared_by_id<TransponderCommitment>(&scenario, record_id);
    record.transfer_tribe_authority(&current, &outsider, 1, scenario.ctx());
    abort 0
}

#[test]
fun faction_wallet_authors_and_rotates_a_deterministic_record() {
    let mut scenario = ts::begin(governor());
    setup(&mut scenario);
    let (character_id, profile_id) = create_npc(&mut scenario);
    ts::next_tx(&mut scenario, user_a());
    let mut registry = ts::take_shared<ObjectRegistry>(&scenario);
    let mut transponder_registry = ts::take_shared<TransponderRegistry>(&scenario);
    let character = ts::take_shared_by_id<Character>(&scenario, character_id);
    let profile = ts::take_shared_by_id<NpcProfile>(&scenario, profile_id);
    let record_id = object::id_from_address(
        derived_object::derive_address(
            object::id(&transponder_registry),
            transponder::faction_scope_key(tenant(), b"500012-none".to_string()),
        ),
    );
    transponder::author_for_faction(
        &mut registry,
        &mut transponder_registry,
        &character,
        &profile,
        first(),
        scenario.ctx(),
    );
    ts::return_shared(character);
    ts::return_shared(profile);
    ts::return_shared(registry);
    ts::return_shared(transponder_registry);
    ts::next_tx(&mut scenario, user_a());
    let profile = ts::take_shared_by_id<NpcProfile>(&scenario, profile_id);
    let mut record = ts::take_shared_by_id<TransponderCommitment>(&scenario, record_id);
    assert_eq!(record.scope_kind(), transponder::faction_scope());
    assert_eq!(record.scope_id(), b"500012-none".to_string());
    record.rotate_for_faction(&profile, 1, second(), scenario.ctx());
    assert_eq!(record.commitment(), second());
    assert_eq!(record.revision(), 2);
    ts::return_shared(record);
    ts::return_shared(profile);
    scenario.end();
}

#[test]
#[expected_failure(abort_code = transponder::EUnauthorized)]
fun another_wallet_cannot_author_a_faction_record() {
    let mut scenario = ts::begin(governor());
    setup(&mut scenario);
    let (character_id, profile_id) = create_npc(&mut scenario);
    ts::next_tx(&mut scenario, user_b());
    let mut registry = ts::take_shared<ObjectRegistry>(&scenario);
    let mut transponder_registry = ts::take_shared<TransponderRegistry>(&scenario);
    let character = ts::take_shared_by_id<Character>(&scenario, character_id);
    let profile = ts::take_shared_by_id<NpcProfile>(&scenario, profile_id);
    transponder::author_for_faction(
        &mut registry,
        &mut transponder_registry,
        &character,
        &profile,
        first(),
        scenario.ctx(),
    );
    abort 0
}

#[test]
#[expected_failure(abort_code = transponder::ERetiredNpc)]
fun retired_npc_profile_cannot_author_a_faction_record() {
    let mut scenario = ts::begin(governor());
    setup(&mut scenario);
    let (character_id, profile_id) = create_npc(&mut scenario);
    ts::next_tx(&mut scenario, admin());
    let mut profile = ts::take_shared_by_id<NpcProfile>(&scenario, profile_id);
    let acl = ts::take_shared<AdminACL>(&scenario);
    profile.retire(&acl, 1, scenario.ctx());
    ts::return_shared(profile);
    ts::return_shared(acl);
    ts::next_tx(&mut scenario, user_a());
    let mut registry = ts::take_shared<ObjectRegistry>(&scenario);
    let mut transponder_registry = ts::take_shared<TransponderRegistry>(&scenario);
    let character = ts::take_shared_by_id<Character>(&scenario, character_id);
    let profile = ts::take_shared_by_id<NpcProfile>(&scenario, profile_id);
    transponder::author_for_faction(
        &mut registry,
        &mut transponder_registry,
        &character,
        &profile,
        first(),
        scenario.ctx(),
    );
    abort 0
}

#[test]
#[expected_failure(abort_code = transponder::EInvalidCommitment)]
fun rejects_non_32_byte_commitments() {
    let mut scenario = ts::begin(governor());
    setup(&mut scenario);
    let character_id = create_character(&mut scenario, HUMAN_A, TRIBE, user_a());
    ts::next_tx(&mut scenario, user_a());
    let mut registry = ts::take_shared<ObjectRegistry>(&scenario);
    let mut transponder_registry = ts::take_shared<TransponderRegistry>(&scenario);
    let character = ts::take_shared_by_id<Character>(&scenario, character_id);
    transponder::author_for_tribe(
        &mut registry,
        &mut transponder_registry,
        &character,
        x"00",
        scenario.ctx(),
    );
    abort 0
}

#[test]
#[expected_failure(abort_code = transponder::EStaleRevision)]
fun stale_rotation_cannot_replace_a_newer_commitment() {
    let mut scenario = ts::begin(governor());
    setup(&mut scenario);
    let character_id = create_character(&mut scenario, HUMAN_A, TRIBE, user_a());
    let record_id = author_tribe(&mut scenario, character_id);
    ts::next_tx(&mut scenario, user_a());
    let character = ts::take_shared_by_id<Character>(&scenario, character_id);
    let mut record = ts::take_shared_by_id<TransponderCommitment>(&scenario, record_id);
    record.rotate_for_tribe(&character, 1, second(), scenario.ctx());
    record.rotate_for_tribe(&character, 1, first(), scenario.ctx());
    abort 0
}
