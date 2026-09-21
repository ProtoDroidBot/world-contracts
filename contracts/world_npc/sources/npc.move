/// Permanent NPC profiles attached to ordinary Characters and PlayerProfiles.
/// The game server attests ship incarnations; death never deletes identity.
module world_npc::npc;

use std::string::{Self, String};
use sui::{derived_object, dynamic_field, event};
use world::{
    access::AdminACL,
    character::{Self, Character},
    in_game_id,
    object_registry::ObjectRegistry
};

#[error(code = 0)]
const EInvalidNpcId: vector<u8> = b"NPC character ID is outside the reserved interval";
#[error(code = 1)]
const EInvalidFaction: vector<u8> =
    b"NPC faction string must be a lowercase ASCII slug of at most 96 bytes";
#[error(code = 2)]
const ERegistryMismatch: vector<u8> = b"Character was not derived in this registry";
#[error(code = 3)]
const EAlreadyRegistered: vector<u8> = b"Character already has an NPC profile";
#[error(code = 4)]
const EFactionWalletMismatch: vector<u8> =
    b"Faction wallet or ACL differs from its permanent binding";
#[error(code = 5)]
const EAdminAclMismatch: vector<u8> = b"NPC profile belongs to another AdminACL";
#[error(code = 6)]
const EInvalidLifecycle: vector<u8> = b"NPC lifecycle counters or active entity are inconsistent";
#[error(code = 7)]
const EStaleRevision: vector<u8> = b"NPC revision changed; read and retry";
#[error(code = 8)]
const EStaleIncarnation: vector<u8> = b"NPC incarnation or death count cannot move backwards";
#[error(code = 9)]
const ERetired: vector<u8> = b"NPC profile is permanently retired";

const MIN_NPC_ID: u64 = 1_500_000_000;
const MAX_NPC_ID: u64 = 1_599_999_999;

/// Distinct key type avoids consuming another in-game TenantItemId.
public struct NpcProfileKey has copy, drop, store {
    character_id: ID,
}

/// Scoped to this world registry and tenant, independent of individual pilots.
public struct NpcFactionKey has copy, drop, store {
    tenant: String,
    faction_key: String,
}

public struct NpcFactionBinding has copy, drop, store {
    wallet_address: address,
    admin_acl_id: ID,
}

/// Package-owned root for deterministic NPC profiles and faction bindings.
public struct NpcRegistry has key {
    id: UID,
}

public struct NpcProfile has key {
    id: UID,
    character_id: ID,
    registry_id: ID,
    admin_acl_id: ID,
    tenant: String,
    npc_id: u32,
    faction_key: String,
    wallet_address: address,
    revision: u64,
    incarnation: u64,
    active_entity_id: u64,
    deaths: u64,
    retired: bool,
}

public struct NpcProfileRegistered has copy, drop {
    profile_id: ID,
    character_id: ID,
    registry_id: ID,
    npc_id: u32,
    tenant: String,
    faction_key: String,
    wallet_address: address,
    revision: u64,
    incarnation: u64,
    active_entity_id: u64,
    deaths: u64,
}

public struct NpcLifecycleSynced has copy, drop {
    profile_id: ID,
    character_id: ID,
    revision: u64,
    incarnation: u64,
    active_entity_id: u64,
    deaths: u64,
    retired: bool,
}

public fun new_profile_key(character_id: ID): NpcProfileKey {
    NpcProfileKey { character_id }
}

public fun new_faction_key(tenant: String, faction_key: String): NpcFactionKey {
    NpcFactionKey { tenant, faction_key }
}

/// Numeric factions use "<id>-none"; string-only factions use "0-<slug>".
public fun faction_key(faction_id: u32, faction_string_id: String): String {
    assert!(faction_string_id.length() <= 96, EInvalidFaction);
    assert!(faction_string_id != string::utf8(b"none"), EInvalidFaction);
    let bytes = faction_string_id.as_bytes();
    let mut i = 0;
    while (i < bytes.length()) {
        let byte = bytes[i];
        let alphanumeric = (byte >= 97 && byte <= 122) || (byte >= 48 && byte <= 57);
        assert!(alphanumeric || (i > 0 && (byte == 45 || byte == 95)), EInvalidFaction);
        i = i + 1;
    };
    let mut key = faction_id.to_string();
    key.append(string::utf8(b"-"));
    key.append(if (faction_string_id.is_empty()) string::utf8(b"none") else faction_string_id);
    key
}

/// Attach an existing localnet Character without replacing its PlayerProfile.
/// The first NPC in a faction fixes that faction's wallet and authorized ACL.
public fun register_profile(
    registry: &mut ObjectRegistry,
    npc_registry: &mut NpcRegistry,
    character: &mut Character,
    acl: &AdminACL,
    faction_id: u32,
    faction_string_id: String,
    incarnation: u64,
    active_entity_id: u64,
    deaths: u64,
    ctx: &mut TxContext,
) {
    acl.verify_sponsor(ctx);
    let character_id = character.id();
    let character_key = character.key();
    let npc_id = in_game_id::item_id(&character_key);
    assert!(npc_id >= MIN_NPC_ID && npc_id <= MAX_NPC_ID, EInvalidNpcId);
    assert!(
        character_id == object::id_from_address(derived_object::derive_address(
        object::id(registry), character_key,
    )) && registry.object_exists(character_key),
        ERegistryMismatch,
    );
    assert!(!character.is_npc_character(), EAlreadyRegistered);
    validate_lifecycle(incarnation, active_entity_id, deaths);
    let tenant = character.tenant();
    let faction_key = faction_key(faction_id, faction_string_id);
    let wallet_address = character.character_address();
    let admin_acl_id = object::id(acl);
    let binding_key = new_faction_key(tenant, faction_key);
    if (dynamic_field::exists(&npc_registry.id, binding_key)) {
        let binding = dynamic_field::borrow<NpcFactionKey, NpcFactionBinding>(
            &npc_registry.id,
            binding_key,
        );
        assert!(
            binding.wallet_address == wallet_address && binding.admin_acl_id == admin_acl_id,
            EFactionWalletMismatch,
        );
    } else {
        dynamic_field::add(
            &mut npc_registry.id,
            binding_key,
            NpcFactionBinding { wallet_address, admin_acl_id },
        );
    };
    let uid = derived_object::claim(&mut npc_registry.id, new_profile_key(character_id));
    let profile_id = object::uid_to_inner(&uid);
    character::link_npc_profile_sponsored(character, profile_id, acl, ctx);
    let profile = NpcProfile {
        id: uid,
        character_id,
        registry_id: object::id(registry),
        admin_acl_id,
        tenant,
        npc_id: npc_id as u32,
        faction_key,
        wallet_address,
        revision: 1,
        incarnation,
        active_entity_id,
        deaths,
        retired: false,
    };
    event::emit(NpcProfileRegistered {
        profile_id,
        character_id,
        registry_id: profile.registry_id,
        npc_id: profile.npc_id,
        tenant,
        faction_key,
        wallet_address,
        revision: 1,
        incarnation,
        active_entity_id,
        deaths,
    });
    transfer::share_object(profile);
}

/// Creates an ordinary Character and wallet-owned PlayerProfile, then marks it as NPC.
public fun create_npc_character(
    registry: &mut ObjectRegistry,
    npc_registry: &mut NpcRegistry,
    acl: &AdminACL,
    game_character_id: u32,
    tenant: String,
    tribe_id: u32,
    character_address: address,
    name: String,
    faction_id: u32,
    faction_string_id: String,
    incarnation: u64,
    active_entity_id: u64,
    deaths: u64,
    ctx: &mut TxContext,
): Character {
    let mut character = character::create_character(
        registry,
        acl,
        game_character_id,
        tenant,
        tribe_id,
        character_address,
        name,
        ctx,
    );
    register_profile(
        registry,
        npc_registry,
        &mut character,
        acl,
        faction_id,
        faction_string_id,
        incarnation,
        active_entity_id,
        deaths,
        ctx,
    );
    character
}

fun init(ctx: &mut TxContext) {
    transfer::share_object(NpcRegistry { id: object::new(ctx) });
}

#[test_only]
public fun init_for_testing(ctx: &mut TxContext) {
    init(ctx);
}

public fun npc_registry_id(registry: &NpcRegistry): ID {
    object::id(registry)
}

/// Reconcile server observations, allowing several unseen incarnations to coalesce.
/// expected_revision protects against delayed submissions overwriting a successor.
public fun sync_lifecycle(
    profile: &mut NpcProfile,
    acl: &AdminACL,
    expected_revision: u64,
    incarnation: u64,
    active_entity_id: u64,
    deaths: u64,
    ctx: &TxContext,
) {
    authorize(profile, acl, expected_revision, ctx);
    assert!(!profile.retired, ERetired);
    validate_lifecycle(incarnation, active_entity_id, deaths);
    assert!(incarnation >= profile.incarnation && deaths >= profile.deaths, EStaleIncarnation);
    if (incarnation == profile.incarnation) {
        assert!(
            active_entity_id == profile.active_entity_id ||
            (profile.active_entity_id > 0 && active_entity_id == 0),
            EInvalidLifecycle,
        );
        let allowed_deaths = if (profile.active_entity_id > 0 && active_entity_id == 0) 1 else 0;
        assert!(deaths - profile.deaths <= allowed_deaths, EInvalidLifecycle);
    } else {
        assert!(
            active_entity_id == 0 || active_entity_id != profile.active_entity_id,
            EInvalidLifecycle,
        );
        let completed_incarnations =
            incarnation - profile.incarnation +
            (if (profile.active_entity_id > 0) 1 else 0) - (if (active_entity_id > 0) 1 else 0);
        assert!(deaths - profile.deaths <= completed_incarnations, EInvalidLifecycle);
    };
    if (
        profile.incarnation == incarnation && profile.active_entity_id == active_entity_id &&
        profile.deaths == deaths
    ) return;
    profile.incarnation = incarnation;
    profile.active_entity_id = active_entity_id;
    profile.deaths = deaths;
    profile.revision = profile.revision + 1;
    emit_lifecycle(profile);
}

/// Permanent administrative retirement. Objects and historical counters remain intact.
public fun retire(
    profile: &mut NpcProfile,
    acl: &AdminACL,
    expected_revision: u64,
    ctx: &TxContext,
) {
    authorize(profile, acl, expected_revision, ctx);
    if (profile.retired) return;
    profile.retired = true;
    profile.active_entity_id = 0;
    profile.revision = profile.revision + 1;
    emit_lifecycle(profile);
}

fun authorize(profile: &NpcProfile, acl: &AdminACL, expected_revision: u64, ctx: &TxContext) {
    acl.verify_sponsor(ctx);
    assert!(profile.admin_acl_id == object::id(acl), EAdminAclMismatch);
    assert!(profile.revision == expected_revision, EStaleRevision);
}

fun validate_lifecycle(incarnation: u64, active_entity_id: u64, deaths: u64) {
    assert!(
        incarnation > 0 && deaths <= incarnation &&
        (active_entity_id == 0 || deaths < incarnation),
        EInvalidLifecycle,
    );
}

fun emit_lifecycle(profile: &NpcProfile) {
    event::emit(NpcLifecycleSynced {
        profile_id: object::id(profile),
        character_id: profile.character_id,
        revision: profile.revision,
        incarnation: profile.incarnation,
        active_entity_id: profile.active_entity_id,
        deaths: profile.deaths,
        retired: profile.retired,
    });
}

public fun id(profile: &NpcProfile): ID { object::id(profile) }

public fun character_id(profile: &NpcProfile): ID { profile.character_id }

public fun registry_id(profile: &NpcProfile): ID { profile.registry_id }

public fun admin_acl_id(profile: &NpcProfile): ID { profile.admin_acl_id }

public fun tenant(profile: &NpcProfile): String { profile.tenant }

public fun npc_id(profile: &NpcProfile): u32 { profile.npc_id }

public fun profile_faction_key(profile: &NpcProfile): String { profile.faction_key }

public fun wallet_address(profile: &NpcProfile): address { profile.wallet_address }

public fun revision(profile: &NpcProfile): u64 { profile.revision }

public fun incarnation(profile: &NpcProfile): u64 { profile.incarnation }

public fun active_entity_id(profile: &NpcProfile): u64 { profile.active_entity_id }

public fun deaths(profile: &NpcProfile): u64 { profile.deaths }

public fun is_retired(profile: &NpcProfile): bool { profile.retired }
