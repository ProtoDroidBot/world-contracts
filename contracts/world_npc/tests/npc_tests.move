#[test_only]
module world_npc::npc_tests;

use std::unit_test::assert_eq;
use sui::{derived_object, test_scenario as ts};
use world::{
    access::{Self, AdminACL},
    character::{Self, Character, PlayerProfile},
    object_registry::{Self, ObjectRegistry},
    test_helpers::{Self, governor, admin, user_a, user_b, tenant},
    world::GovernorCap
};
use world_npc::npc::{Self, NpcProfile, NpcRegistry};

const NPC_ID: u32 = 1_500_000_000;
const SHIP_A: u64 = 980_000_000_001;
const SHIP_B: u64 = 980_000_000_002;

fun setup(scenario: &mut ts::Scenario) {
    npc::init_for_testing(scenario.ctx());
    test_helpers::setup_world(scenario);
}

fun create(scenario: &mut ts::Scenario, npc_id: u32, wallet: address): (ID, ID) {
    ts::next_tx(scenario, admin());
    let mut registry = ts::take_shared<ObjectRegistry>(scenario);
    let mut npc_registry = ts::take_shared<NpcRegistry>(scenario);
    let acl = ts::take_shared<AdminACL>(scenario);
    let character = npc::create_npc_character(
        &mut registry,
        &mut npc_registry,
        &acl,
        npc_id,
        tenant(),
        100,
        wallet,
        b"NPC".to_string(),
        500012,
        b"".to_string(),
        1,
        SHIP_A,
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

fun sync(
    scenario: &mut ts::Scenario,
    profile_id: ID,
    expected_revision: u64,
    incarnation: u64,
    active_entity_id: u64,
    deaths: u64,
) {
    ts::next_tx(scenario, admin());
    let mut profile = ts::take_shared_by_id<NpcProfile>(scenario, profile_id);
    let acl = ts::take_shared<AdminACL>(scenario);
    profile.sync_lifecycle(
        &acl,
        expected_revision,
        incarnation,
        active_entity_id,
        deaths,
        scenario.ctx(),
    );
    ts::return_shared(profile);
    ts::return_shared(acl);
}

#[test]
fun creates_compatible_character_and_deterministic_profile() {
    let mut scenario = ts::begin(governor());
    setup(&mut scenario);
    let (character_id, profile_id) = create(&mut scenario, NPC_ID, user_a());
    ts::next_tx(&mut scenario, user_a());
    let character = ts::take_shared_by_id<Character>(&scenario, character_id);
    let profile = ts::take_shared_by_id<NpcProfile>(&scenario, profile_id);
    let registry = ts::take_shared<ObjectRegistry>(&scenario);
    let npc_registry = ts::take_shared<NpcRegistry>(&scenario);
    let acl = ts::take_shared<AdminACL>(&scenario);
    let player_profile = ts::take_from_sender<PlayerProfile>(&scenario);
    assert!(character.is_npc_character(), 0);
    assert_eq!(character.npc_profile_id().destroy_some(), profile_id);
    assert_eq!(
        profile.id(),
        object::id_from_address(
            derived_object::derive_address(
                object::id(&npc_registry),
                npc::new_profile_key(character_id),
            ),
        ),
    );
    assert_eq!(profile.character_id(), character_id);
    assert_eq!(profile.registry_id(), object::id(&registry));
    assert_eq!(profile.admin_acl_id(), object::id(&acl));
    assert_eq!(profile.npc_id(), NPC_ID);
    assert_eq!(profile.tenant(), tenant());
    assert_eq!(profile.wallet_address(), user_a());
    assert_eq!(profile.profile_faction_key(), b"500012-none".to_string());
    assert_eq!(profile.revision(), 1);
    assert_eq!(profile.incarnation(), 1);
    assert_eq!(profile.active_entity_id(), SHIP_A);
    assert_eq!(profile.deaths(), 0);
    assert!(!profile.is_retired(), 0);
    ts::return_to_sender(&scenario, player_profile);
    ts::return_shared(character);
    ts::return_shared(profile);
    ts::return_shared(registry);
    ts::return_shared(npc_registry);
    ts::return_shared(acl);
    scenario.end();
}

#[test]
fun attaches_legacy_character_without_replacing_player_profile() {
    let mut scenario = ts::begin(governor());
    setup(&mut scenario);
    ts::next_tx(&mut scenario, admin());
    let mut registry = ts::take_shared<ObjectRegistry>(&scenario);
    let acl = ts::take_shared<AdminACL>(&scenario);
    let character = character::create_character(
        &mut registry,
        &acl,
        NPC_ID,
        tenant(),
        100,
        user_a(),
        b"Legacy".to_string(),
        scenario.ctx(),
    );
    let character_id = character.id();
    assert!(!character.is_npc_character(), 0);
    character.share_character(&acl, scenario.ctx());
    ts::return_shared(registry);
    ts::return_shared(acl);
    ts::next_tx(&mut scenario, user_a());
    let player_profile = ts::take_from_sender<PlayerProfile>(&scenario);
    let old_profile_id = character::player_profile_id(&player_profile);
    ts::return_to_sender(&scenario, player_profile);
    ts::next_tx(&mut scenario, admin());
    let mut registry = ts::take_shared<ObjectRegistry>(&scenario);
    let mut npc_registry = ts::take_shared<NpcRegistry>(&scenario);
    let acl = ts::take_shared<AdminACL>(&scenario);
    let mut character = ts::take_shared_by_id<Character>(&scenario, character_id);
    npc::register_profile(
        &mut registry,
        &mut npc_registry,
        &mut character,
        &acl,
        0,
        b"osa".to_string(),
        4,
        SHIP_B,
        2,
        scenario.ctx(),
    );
    assert_eq!(character.id(), character_id);
    ts::return_shared(character);
    ts::return_shared(registry);
    ts::return_shared(npc_registry);
    ts::return_shared(acl);
    ts::next_tx(&mut scenario, user_a());
    let player_profile = ts::take_from_sender<PlayerProfile>(&scenario);
    assert_eq!(character::player_profile_id(&player_profile), old_profile_id);
    ts::return_to_sender(&scenario, player_profile);
    scenario.end();
}

#[test]
fun two_npcs_share_a_faction_wallet_and_allow_upper_reserved_boundary() {
    let mut scenario = ts::begin(governor());
    setup(&mut scenario);
    let (first, first_profile) = create(&mut scenario, NPC_ID, user_a());
    let (second, second_profile) = create(&mut scenario, 1_599_999_999, user_a());
    assert!(first != second && first_profile != second_profile, 0);
    scenario.end();
}

#[test]
#[expected_failure(abort_code = npc::EFactionWalletMismatch)]
fun faction_cannot_acquire_a_second_wallet() {
    let mut scenario = ts::begin(governor());
    setup(&mut scenario);
    create(&mut scenario, NPC_ID, user_a());
    create(&mut scenario, NPC_ID + 1, user_b());
    scenario.end();
}

#[test]
fun canonical_numeric_and_string_only_faction_keys() {
    assert_eq!(npc::faction_key(500012, b"".to_string()), b"500012-none".to_string());
    assert_eq!(npc::faction_key(0, b"osa".to_string()), b"0-osa".to_string());
    assert_eq!(
        npc::faction_key(42, b"blood-raiders_1".to_string()),
        b"42-blood-raiders_1".to_string(),
    );
    assert_eq!(npc::faction_key(0, b"".to_string()), b"0-none".to_string());
}

#[test]
#[expected_failure(abort_code = npc::EInvalidFaction)]
fun rejects_noncanonical_faction_string() { npc::faction_key(0, b"Osa".to_string()); }

#[test]
#[expected_failure(abort_code = npc::EInvalidFaction)]
fun rejects_literal_none_marker() { npc::faction_key(0, b"none".to_string()); }

#[test]
#[expected_failure(abort_code = npc::EInvalidFaction)]
fun rejects_long_faction_string() {
    npc::faction_key(
        0,
        b"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa".to_string(),
    );
}

#[test]
#[expected_failure(abort_code = npc::EInvalidNpcId)]
fun rejects_human_character_ids() {
    let mut scenario = ts::begin(governor());
    setup(&mut scenario);
    create(&mut scenario, 140_000_001, user_a());
    scenario.end();
}

#[test]
#[expected_failure(abort_code = npc::EInvalidNpcId)]
fun rejects_ids_above_reservation() {
    let mut scenario = ts::begin(governor());
    setup(&mut scenario);
    create(&mut scenario, 1_600_000_000, user_a());
    scenario.end();
}

#[test]
#[expected_failure(abort_code = npc::EAlreadyRegistered)]
fun rejects_duplicate_profile_registration() {
    let mut scenario = ts::begin(governor());
    setup(&mut scenario);
    let (id, _) = create(&mut scenario, NPC_ID, user_a());
    ts::next_tx(&mut scenario, admin());
    let mut registry = ts::take_shared<ObjectRegistry>(&scenario);
    let mut npc_registry = ts::take_shared<NpcRegistry>(&scenario);
    let acl = ts::take_shared<AdminACL>(&scenario);
    let mut character = ts::take_shared_by_id<Character>(&scenario, id);
    npc::register_profile(
        &mut registry,
        &mut npc_registry,
        &mut character,
        &acl,
        500012,
        b"".to_string(),
        1,
        SHIP_A,
        0,
        scenario.ctx(),
    );
    ts::return_shared(character);
    ts::return_shared(registry);
    ts::return_shared(npc_registry);
    ts::return_shared(acl);
    scenario.end();
}

#[test]
#[expected_failure(abort_code = npc::ERegistryMismatch)]
fun rejects_a_character_from_another_registry() {
    let mut scenario = ts::begin(governor());
    setup(&mut scenario);
    let (id, _) = create(&mut scenario, NPC_ID, user_a());
    ts::next_tx(&mut scenario, admin());
    object_registry::init_for_testing(scenario.ctx());
    ts::next_tx(&mut scenario, admin());
    let mut registry = ts::take_shared<ObjectRegistry>(&scenario);
    let mut npc_registry = ts::take_shared<NpcRegistry>(&scenario);
    let acl = ts::take_shared<AdminACL>(&scenario);
    let mut character = ts::take_shared_by_id<Character>(&scenario, id);
    npc::register_profile(
        &mut registry,
        &mut npc_registry,
        &mut character,
        &acl,
        500012,
        b"".to_string(),
        1,
        SHIP_A,
        0,
        scenario.ctx(),
    );
    ts::return_shared(character);
    ts::return_shared(registry);
    ts::return_shared(npc_registry);
    ts::return_shared(acl);
    scenario.end();
}

#[test]
fun death_respawn_and_coalesced_lifecycles_preserve_profile_id() {
    let mut scenario = ts::begin(governor());
    setup(&mut scenario);
    let (_, profile_id) = create(&mut scenario, NPC_ID, user_a());
    sync(&mut scenario, profile_id, 1, 1, 0, 1);
    sync(&mut scenario, profile_id, 2, 2, SHIP_B, 1);
    sync(&mut scenario, profile_id, 3, 5, SHIP_B + 3, 4);
    sync(&mut scenario, profile_id, 4, 5, SHIP_B + 3, 4); // No-op.
    ts::next_tx(&mut scenario, admin());
    let profile = ts::take_shared_by_id<NpcProfile>(&scenario, profile_id);
    assert_eq!(profile.id(), profile_id);
    assert_eq!(profile.revision(), 4);
    assert_eq!(profile.incarnation(), 5);
    assert_eq!(profile.deaths(), 4);
    assert_eq!(profile.active_entity_id(), SHIP_B + 3);
    ts::return_shared(profile);
    scenario.end();
}

#[test]
fun despawn_does_not_require_a_death() {
    let mut scenario = ts::begin(governor());
    setup(&mut scenario);
    let (_, id) = create(&mut scenario, NPC_ID, user_a());
    sync(&mut scenario, id, 1, 1, 0, 0);
    sync(&mut scenario, id, 2, 2, SHIP_B, 0);
    scenario.end();
}

#[test]
#[expected_failure(abort_code = npc::EStaleRevision)]
fun delayed_death_cannot_retire_successor() {
    let mut scenario = ts::begin(governor());
    setup(&mut scenario);
    let (_, id) = create(&mut scenario, NPC_ID, user_a());
    sync(&mut scenario, id, 1, 2, SHIP_B, 1);
    sync(&mut scenario, id, 1, 1, 0, 1);
    scenario.end();
}

#[test]
#[expected_failure(abort_code = npc::EStaleIncarnation)]
fun rejects_incarnation_rollback_even_with_current_revision() {
    let mut scenario = ts::begin(governor());
    setup(&mut scenario);
    let (_, id) = create(&mut scenario, NPC_ID, user_a());
    sync(&mut scenario, id, 1, 2, SHIP_B, 1);
    sync(&mut scenario, id, 2, 1, 0, 1);
    scenario.end();
}

#[test]
#[expected_failure(abort_code = npc::EInvalidLifecycle)]
fun rejects_same_incarnation_ship_change() {
    let mut scenario = ts::begin(governor());
    setup(&mut scenario);
    let (_, id) = create(&mut scenario, NPC_ID, user_a());
    sync(&mut scenario, id, 1, 1, SHIP_B, 0);
    scenario.end();
}

#[test]
#[expected_failure(abort_code = npc::EInvalidLifecycle)]
fun rejects_reactivation_without_new_incarnation() {
    let mut scenario = ts::begin(governor());
    setup(&mut scenario);
    let (_, id) = create(&mut scenario, NPC_ID, user_a());
    sync(&mut scenario, id, 1, 1, 0, 0);
    sync(&mut scenario, id, 2, 1, SHIP_A, 0);
    scenario.end();
}

#[test]
#[expected_failure(abort_code = npc::EInvalidLifecycle)]
fun rejects_death_count_change_after_despawn() {
    let mut scenario = ts::begin(governor());
    setup(&mut scenario);
    let (_, id) = create(&mut scenario, NPC_ID, user_a());
    sync(&mut scenario, id, 1, 1, 0, 0);
    sync(&mut scenario, id, 2, 1, 0, 1);
    scenario.end();
}

#[test]
#[expected_failure(abort_code = npc::EInvalidLifecycle)]
fun rejects_impossible_coalesced_deaths() {
    let mut scenario = ts::begin(governor());
    setup(&mut scenario);
    let (_, id) = create(&mut scenario, NPC_ID, user_a());
    sync(&mut scenario, id, 1, 4, 0, 0); // Four despawns, no deaths.
    sync(&mut scenario, id, 2, 5, SHIP_B, 4); // Only one new, active incarnation.
    scenario.end();
}

#[test]
#[expected_failure(abort_code = access::EUnauthorizedSponsor)]
fun unauthorized_wallet_cannot_create_npc_character() {
    let mut scenario = ts::begin(governor());
    setup(&mut scenario);
    ts::next_tx(&mut scenario, @0xBAD);
    let mut registry = ts::take_shared<ObjectRegistry>(&scenario);
    let mut npc_registry = ts::take_shared<NpcRegistry>(&scenario);
    let acl = ts::take_shared<AdminACL>(&scenario);
    let _character = npc::create_npc_character(
        &mut registry,
        &mut npc_registry,
        &acl,
        NPC_ID,
        tenant(),
        100,
        user_a(),
        b"NPC".to_string(),
        500012,
        b"".to_string(),
        1,
        SHIP_A,
        0,
        scenario.ctx(),
    );
    // Fail at this test's location if creation ever omits authorization; do not
    // let a later share_character sponsor check mask that regression.
    abort 0
}

#[test]
#[expected_failure(abort_code = access::EUnauthorizedSponsor)]
fun unauthorized_wallet_cannot_register_legacy_character() {
    let mut scenario = ts::begin(governor());
    setup(&mut scenario);
    ts::next_tx(&mut scenario, admin());
    let mut registry = ts::take_shared<ObjectRegistry>(&scenario);
    let acl = ts::take_shared<AdminACL>(&scenario);
    let character = character::create_character(
        &mut registry,
        &acl,
        NPC_ID,
        tenant(),
        100,
        user_a(),
        b"Legacy".to_string(),
        scenario.ctx(),
    );
    let character_id = character.id();
    character.share_character(&acl, scenario.ctx());
    ts::return_shared(registry);
    ts::return_shared(acl);
    ts::next_tx(&mut scenario, @0xBAD);
    let mut registry = ts::take_shared<ObjectRegistry>(&scenario);
    let mut npc_registry = ts::take_shared<NpcRegistry>(&scenario);
    let acl = ts::take_shared<AdminACL>(&scenario);
    let mut character = ts::take_shared_by_id<Character>(&scenario, character_id);
    npc::register_profile(
        &mut registry,
        &mut npc_registry,
        &mut character,
        &acl,
        500012,
        b"".to_string(),
        1,
        SHIP_A,
        0,
        scenario.ctx(),
    );
    ts::return_shared(character);
    ts::return_shared(registry);
    ts::return_shared(npc_registry);
    ts::return_shared(acl);
    scenario.end();
}

#[test]
#[expected_failure(abort_code = access::EUnauthorizedSponsor)]
fun unauthorized_wallet_cannot_retire_profile() {
    let mut scenario = ts::begin(governor());
    setup(&mut scenario);
    let (_, id) = create(&mut scenario, NPC_ID, user_a());
    ts::next_tx(&mut scenario, @0xBAD);
    let mut profile = ts::take_shared_by_id<NpcProfile>(&scenario, id);
    let acl = ts::take_shared<AdminACL>(&scenario);
    profile.retire(&acl, 1, scenario.ctx());
    ts::return_shared(profile);
    ts::return_shared(acl);
    scenario.end();
}

#[test]
#[expected_failure(abort_code = access::EUnauthorizedSponsor)]
fun unauthorized_wallet_cannot_sync_lifecycle() {
    let mut scenario = ts::begin(governor());
    setup(&mut scenario);
    let (_, id) = create(&mut scenario, NPC_ID, user_a());
    ts::next_tx(&mut scenario, @0xBAD);
    let mut profile = ts::take_shared_by_id<NpcProfile>(&scenario, id);
    let acl = ts::take_shared<AdminACL>(&scenario);
    profile.sync_lifecycle(&acl, 1, 1, 0, 1, scenario.ctx());
    ts::return_shared(profile);
    ts::return_shared(acl);
    scenario.end();
}

#[test]
#[expected_failure(abort_code = npc::EAdminAclMismatch)]
fun another_authorized_acl_cannot_sync_lifecycle() {
    let mut scenario = ts::begin(governor());
    setup(&mut scenario);
    let (_, id) = create(&mut scenario, NPC_ID, user_a());
    ts::next_tx(&mut scenario, governor());
    access::init_for_testing(scenario.ctx());
    ts::next_tx(&mut scenario, governor());
    let mut acl = ts::take_shared<AdminACL>(&scenario);
    let cap = ts::take_from_sender<GovernorCap>(&scenario);
    access::add_sponsor_to_acl(&mut acl, &cap, governor());
    let mut profile = ts::take_shared_by_id<NpcProfile>(&scenario, id);
    profile.sync_lifecycle(&acl, 1, 1, 0, 1, scenario.ctx());
    ts::return_to_sender(&scenario, cap);
    ts::return_shared(profile);
    ts::return_shared(acl);
    scenario.end();
}

#[test]
fun retirement_keeps_character_and_profile() {
    let mut scenario = ts::begin(governor());
    setup(&mut scenario);
    let (character_id, id) = create(&mut scenario, NPC_ID, user_a());
    ts::next_tx(&mut scenario, admin());
    let mut profile = ts::take_shared_by_id<NpcProfile>(&scenario, id);
    let character = ts::take_shared_by_id<Character>(&scenario, character_id);
    let acl = ts::take_shared<AdminACL>(&scenario);
    profile.retire(&acl, 1, scenario.ctx());
    assert!(profile.is_retired(), 0);
    assert_eq!(profile.active_entity_id(), 0);
    assert_eq!(profile.deaths(), 0);
    assert_eq!(profile.revision(), 2);
    assert_eq!(character.npc_profile_id().destroy_some(), id);
    profile.retire(&acl, 2, scenario.ctx()); // Idempotent.
    assert_eq!(profile.revision(), 2);
    ts::return_shared(profile);
    ts::return_shared(character);
    ts::return_shared(acl);
    scenario.end();
}

#[test]
#[expected_failure(abort_code = npc::ERetired)]
fun retirement_blocks_future_respawns() {
    let mut scenario = ts::begin(governor());
    setup(&mut scenario);
    let (_, id) = create(&mut scenario, NPC_ID, user_a());
    ts::next_tx(&mut scenario, admin());
    let mut profile = ts::take_shared_by_id<NpcProfile>(&scenario, id);
    let acl = ts::take_shared<AdminACL>(&scenario);
    profile.retire(&acl, 1, scenario.ctx());
    profile.sync_lifecycle(&acl, 2, 2, SHIP_B, 0, scenario.ctx());
    ts::return_shared(profile);
    ts::return_shared(acl);
    scenario.end();
}

#[test]
#[expected_failure(abort_code = character::ENpcCharacterPermanent)]
fun npc_character_cannot_be_deleted() {
    let mut scenario = ts::begin(governor());
    setup(&mut scenario);
    let (id, _) = create(&mut scenario, NPC_ID, user_a());
    ts::next_tx(&mut scenario, admin());
    let character = ts::take_shared_by_id<Character>(&scenario, id);
    let acl = ts::take_shared<AdminACL>(&scenario);
    character.delete_character(&acl, scenario.ctx());
    ts::return_shared(acl);
    scenario.end();
}

#[test]
#[expected_failure(abort_code = character::ENpcCharacterPermanent)]
fun npc_character_wallet_cannot_be_reassigned() {
    let mut scenario = ts::begin(governor());
    setup(&mut scenario);
    let (id, _) = create(&mut scenario, NPC_ID, user_a());
    ts::next_tx(&mut scenario, admin());
    let mut character = ts::take_shared_by_id<Character>(&scenario, id);
    let acl = ts::take_shared<AdminACL>(&scenario);
    character.update_address(&acl, user_b(), scenario.ctx());
    ts::return_shared(character);
    ts::return_shared(acl);
    scenario.end();
}

#[test]
#[expected_failure(abort_code = character::ENpcCharacterPermanent)]
fun npc_character_tenant_cannot_be_reassigned() {
    let mut scenario = ts::begin(governor());
    setup(&mut scenario);
    let (id, _) = create(&mut scenario, NPC_ID, user_a());
    ts::next_tx(&mut scenario, admin());
    let mut character = ts::take_shared_by_id<Character>(&scenario, id);
    let acl = ts::take_shared<AdminACL>(&scenario);
    character.update_tenant_id(&acl, b"OTHER".to_string(), scenario.ctx());
    ts::return_shared(character);
    ts::return_shared(acl);
    scenario.end();
}

#[test]
#[expected_failure(abort_code = character::ENpcCharacterPermanent)]
fun npc_character_tribe_cannot_be_reassigned() {
    let mut scenario = ts::begin(governor());
    setup(&mut scenario);
    let (id, _) = create(&mut scenario, NPC_ID, user_a());
    ts::next_tx(&mut scenario, admin());
    let mut character = ts::take_shared_by_id<Character>(&scenario, id);
    let acl = ts::take_shared<AdminACL>(&scenario);
    character.update_tribe(&acl, 101, scenario.ctx());
    ts::return_shared(character);
    ts::return_shared(acl);
    scenario.end();
}

#[test]
fun ordinary_human_character_operations_are_unchanged() {
    let mut scenario = ts::begin(governor());
    setup(&mut scenario);
    ts::next_tx(&mut scenario, admin());
    let mut registry = ts::take_shared<ObjectRegistry>(&scenario);
    let acl = ts::take_shared<AdminACL>(&scenario);
    let mut character = character::create_character(
        &mut registry,
        &acl,
        140_000_001,
        tenant(),
        100,
        user_a(),
        b"Human".to_string(),
        scenario.ctx(),
    );
    assert!(!character.is_npc_character(), 0);
    assert!(character.npc_profile_id().is_none(), 0);
    character.update_address(&acl, user_b(), scenario.ctx());
    character.update_tribe(&acl, 101, scenario.ctx());
    character.update_tenant_id(&acl, b"OTHER".to_string(), scenario.ctx());
    character.delete_character(&acl, scenario.ctx());
    ts::return_shared(registry);
    ts::return_shared(acl);
    scenario.end();
}
