/// Private-code commitments for tribe and NPC-faction transponders.
///
/// Sui objects and transaction inputs are public. This module therefore never accepts a
/// plaintext transponder code or its salt. Clients commit to a domain-separated BLAKE2b-256
/// digest off-chain and distribute the code plus a cryptographically-random salt through a
/// trusted off-chain channel. A recipient can recompute the commitment without revealing
/// either secret to the chain.
module world_transponder::transponder;

use std::string::String;
use sui::{derived_object, event};
use world::{
    character::Character,
    object_registry::ObjectRegistry,
};
use world_npc::npc::NpcProfile;

#[error(code = 0)]
const EInvalidCommitment: vector<u8> = b"Transponder commitment must be exactly 32 bytes";
#[error(code = 1)]
const ERegistryMismatch: vector<u8> = b"Transponder scope does not belong to this world registry";
#[error(code = 2)]
const EUnauthorized: vector<u8> = b"Sender is not authorized to author this transponder commitment";
#[error(code = 3)]
const EScopeMismatch: vector<u8> = b"Character or NPC profile does not belong to the commitment scope";
#[error(code = 4)]
const EStaleRevision: vector<u8> = b"Transponder revision changed; read and retry";
#[error(code = 5)]
const ERetiredNpc: vector<u8> = b"A retired NPC profile cannot author faction transponders";

const SCOPE_TRIBE: u8 = 1;
const SCOPE_FACTION: u8 = 2;
const HASH_SCHEME_BLAKE2B_256_V1: u8 = 1;
const COMMITMENT_LENGTH: u64 = 32;

/// A distinct derived-object key gives each registry/tenant/scope exactly one record.
public struct TransponderScopeKey has copy, drop, store {
    tenant: String,
    scope_kind: u8,
    scope_id: String,
}

/// The only secret-derived value stored on-chain is `commitment`.
/// `authority` controls rotations; scope membership is rechecked for every mutation.
public struct TransponderCommitment has key {
    id: UID,
    registry_id: ID,
    tenant: String,
    scope_kind: u8,
    scope_id: String,
    authority: address,
    hash_scheme: u8,
    commitment: vector<u8>,
    revision: u64,
    revoked: bool,
}

/// Package-owned root for deterministic transponder commitments.
public struct TransponderRegistry has key {
    id: UID,
}

public struct TransponderAuthored has copy, drop {
    commitment_id: ID,
    registry_id: ID,
    tenant: String,
    scope_kind: u8,
    scope_id: String,
    authority: address,
    hash_scheme: u8,
    commitment: vector<u8>,
    revision: u64,
}

public struct TransponderRotated has copy, drop {
    commitment_id: ID,
    authority: address,
    commitment: vector<u8>,
    revision: u64,
}

public struct TransponderRevoked has copy, drop {
    commitment_id: ID,
    authority: address,
    revision: u64,
}

public struct TransponderAuthorityTransferred has copy, drop {
    commitment_id: ID,
    previous_authority: address,
    new_authority: address,
    revision: u64,
}

public fun tribe_scope_key(tenant: String, tribe_id: u32): TransponderScopeKey {
    TransponderScopeKey { tenant, scope_kind: SCOPE_TRIBE, scope_id: tribe_id.to_string() }
}

public fun faction_scope_key(tenant: String, faction_key: String): TransponderScopeKey {
    TransponderScopeKey { tenant, scope_kind: SCOPE_FACTION, scope_id: faction_key }
}

/// Author the first commitment for a tribe. The character wallet becomes the authority.
public fun author_for_tribe(
    registry: &mut ObjectRegistry,
    transponder_registry: &mut TransponderRegistry,
    character: &Character,
    commitment: vector<u8>,
    ctx: &mut TxContext,
) {
    validate_commitment(&commitment);
    assert_character_registry(registry, character);
    assert!(character.character_address() == ctx.sender(), EUnauthorized);
    let tenant = character.tenant();
    let scope_id = character.tribe().to_string();
    create(
        registry,
        transponder_registry,
        tenant,
        SCOPE_TRIBE,
        scope_id,
        commitment,
        ctx.sender(),
    );
}

/// Author the first commitment for an NPC faction. Every profile in the faction is bound to
/// the same wallet, so no NPC identity or respawn can silently acquire another authority.
public fun author_for_faction(
    registry: &mut ObjectRegistry,
    transponder_registry: &mut TransponderRegistry,
    character: &Character,
    profile: &NpcProfile,
    commitment: vector<u8>,
    ctx: &mut TxContext,
) {
    validate_commitment(&commitment);
    assert_character_registry(registry, character);
    assert_faction_registry(registry, profile);
    assert!(profile.character_id() == character.id(), EScopeMismatch);
    assert!(profile.tenant() == character.tenant(), EScopeMismatch);
    assert!(!profile.is_retired(), ERetiredNpc);
    assert!(
        profile.wallet_address() == ctx.sender() &&
            character.character_address() == ctx.sender(),
        EUnauthorized,
    );
    let tenant = profile.tenant();
    let scope_id = profile.profile_faction_key();
    create(
        registry,
        transponder_registry,
        tenant,
        SCOPE_FACTION,
        scope_id,
        commitment,
        ctx.sender(),
    );
}

fun init(ctx: &mut TxContext) {
    transfer::share_object(TransponderRegistry { id: object::new(ctx) });
}

#[test_only]
public fun init_for_testing(ctx: &mut TxContext) {
    init(ctx);
}

public fun transponder_registry_id(registry: &TransponderRegistry): ID {
    object::id(registry)
}

/// Rotate a tribe commitment. The digest must be computed for `expected_revision + 1`.
public fun rotate_for_tribe(
    record: &mut TransponderCommitment,
    character: &Character,
    expected_revision: u64,
    commitment: vector<u8>,
    ctx: &TxContext,
) {
    authorize_tribe(record, character, expected_revision, ctx);
    rotate(record, commitment);
}

/// Rotate a faction commitment. The digest must be computed for `expected_revision + 1`.
public fun rotate_for_faction(
    record: &mut TransponderCommitment,
    profile: &NpcProfile,
    expected_revision: u64,
    commitment: vector<u8>,
    ctx: &TxContext,
) {
    authorize_faction(record, profile, expected_revision, ctx);
    rotate(record, commitment);
}

/// Revoke without publishing the preimage. The record remains so its deterministic ID and
/// revision history cannot be claimed again.
public fun revoke_for_tribe(
    record: &mut TransponderCommitment,
    character: &Character,
    expected_revision: u64,
    ctx: &TxContext,
) {
    authorize_tribe(record, character, expected_revision, ctx);
    revoke(record);
}

public fun revoke_for_faction(
    record: &mut TransponderCommitment,
    profile: &NpcProfile,
    expected_revision: u64,
    ctx: &TxContext,
) {
    authorize_faction(record, profile, expected_revision, ctx);
    revoke(record);
}

/// Hand a tribe record to another wallet that currently owns a character in the same tribe.
/// The current commitment is revoked because it was authored by the previous authority; the
/// successor must rotate a fresh commitment for the next revision.
public fun transfer_tribe_authority(
    record: &mut TransponderCommitment,
    current_character: &Character,
    new_authority_character: &Character,
    expected_revision: u64,
    ctx: &TxContext,
) {
    authorize_tribe(record, current_character, expected_revision, ctx);
    assert_character_scope(record, new_authority_character);
    let previous_authority = record.authority;
    let new_authority = new_authority_character.character_address();
    assert!(new_authority != @0x0, EUnauthorized);
    record.authority = new_authority;
    record.commitment = vector[];
    record.revision = record.revision + 1;
    record.revoked = true;
    event::emit(TransponderAuthorityTransferred {
        commitment_id: object::id(record),
        previous_authority,
        new_authority,
        revision: record.revision,
    });
}

fun create(
    registry: &mut ObjectRegistry,
    transponder_registry: &mut TransponderRegistry,
    tenant: String,
    scope_kind: u8,
    scope_id: String,
    commitment: vector<u8>,
    authority: address,
) {
    let key = TransponderScopeKey { tenant, scope_kind, scope_id };
    let uid = derived_object::claim(&mut transponder_registry.id, key);
    let commitment_id = object::uid_to_inner(&uid);
    let record = TransponderCommitment {
        id: uid,
        registry_id: object::id(registry),
        tenant,
        scope_kind,
        scope_id,
        authority,
        hash_scheme: HASH_SCHEME_BLAKE2B_256_V1,
        commitment,
        revision: 1,
        revoked: false,
    };
    event::emit(TransponderAuthored {
        commitment_id,
        registry_id: record.registry_id,
        tenant,
        scope_kind,
        scope_id,
        authority,
        hash_scheme: record.hash_scheme,
        commitment,
        revision: 1,
    });
    transfer::share_object(record);
}

fun rotate(record: &mut TransponderCommitment, commitment: vector<u8>) {
    validate_commitment(&commitment);
    record.commitment = commitment;
    record.revision = record.revision + 1;
    record.revoked = false;
    event::emit(TransponderRotated {
        commitment_id: object::id(record),
        authority: record.authority,
        commitment,
        revision: record.revision,
    });
}

fun revoke(record: &mut TransponderCommitment) {
    if (record.revoked) return;
    record.commitment = vector[];
    record.revision = record.revision + 1;
    record.revoked = true;
    event::emit(TransponderRevoked {
        commitment_id: object::id(record),
        authority: record.authority,
        revision: record.revision,
    });
}

fun authorize_tribe(
    record: &TransponderCommitment,
    character: &Character,
    expected_revision: u64,
    ctx: &TxContext,
) {
    assert!(record.revision == expected_revision, EStaleRevision);
    assert!(record.authority == ctx.sender() && character.character_address() == ctx.sender(), EUnauthorized);
    assert_character_scope(record, character);
}

fun authorize_faction(
    record: &TransponderCommitment,
    profile: &NpcProfile,
    expected_revision: u64,
    ctx: &TxContext,
) {
    assert!(record.revision == expected_revision, EStaleRevision);
    assert!(!profile.is_retired(), ERetiredNpc);
    assert!(record.authority == ctx.sender() && profile.wallet_address() == ctx.sender(), EUnauthorized);
    assert!(record.scope_kind == SCOPE_FACTION &&
        record.registry_id == profile.registry_id() &&
        record.tenant == profile.tenant() &&
        record.scope_id == profile.profile_faction_key(), EScopeMismatch);
}

fun assert_character_scope(record: &TransponderCommitment, character: &Character) {
    let character_id = object::id(character);
    let expected = object::id_from_address(derived_object::derive_address(
        record.registry_id,
        character.key(),
    ));
    assert!(character_id == expected &&
        record.scope_kind == SCOPE_TRIBE &&
        record.tenant == character.tenant() &&
        record.scope_id == character.tribe().to_string(), EScopeMismatch);
}

fun assert_character_registry(registry: &ObjectRegistry, character: &Character) {
    let key = character.key();
    assert!(registry.object_exists(key) && object::id(character) == object::id_from_address(
        derived_object::derive_address(object::id(registry), key),
    ), ERegistryMismatch);
}

fun assert_faction_registry(registry: &ObjectRegistry, profile: &NpcProfile) {
    assert!(profile.registry_id() == object::id(registry), ERegistryMismatch);
}

fun validate_commitment(commitment: &vector<u8>) {
    assert!(commitment.length() == COMMITMENT_LENGTH, EInvalidCommitment);
}

public fun id(record: &TransponderCommitment): ID { object::id(record) }
public fun registry_id(record: &TransponderCommitment): ID { record.registry_id }
public fun tenant(record: &TransponderCommitment): String { record.tenant }
public fun scope_kind(record: &TransponderCommitment): u8 { record.scope_kind }
public fun scope_id(record: &TransponderCommitment): String { record.scope_id }
public fun authority(record: &TransponderCommitment): address { record.authority }
public fun hash_scheme(record: &TransponderCommitment): u8 { record.hash_scheme }
public fun commitment(record: &TransponderCommitment): vector<u8> { record.commitment }
public fun revision(record: &TransponderCommitment): u64 { record.revision }
public fun is_revoked(record: &TransponderCommitment): bool { record.revoked }
public fun tribe_scope(): u8 { SCOPE_TRIBE }
public fun faction_scope(): u8 { SCOPE_FACTION }
public fun blake2b_256_v1(): u8 { HASH_SCHEME_BLAKE2B_256_V1 }
