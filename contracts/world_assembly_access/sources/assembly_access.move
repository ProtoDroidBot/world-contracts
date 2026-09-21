/// Durable Smart Assembly access grants and guarded cross-owner storage moves.
///
/// A policy is derived from the world ObjectRegistry and an assembly object ID.
/// Grants are independently derived beneath that policy from `(policy_id, 16-byte grant_id)`, which
/// lets clients calculate and verify every object ID before accepting it.
///
/// Owner grants require the exact OwnerCap recorded when the policy was made.
/// Delegation is attenuating: children cannot outlive their parent, acquire new
/// capabilities, or retain the same delegation depth. Inventory capabilities
/// are intentionally owner-issued only; this makes every custody transaction
/// independently valid even after an ancestor grant is revoked.
module world_assembly_access::assembly_access;

use std::string::{Self, String};
use sui::{clock::{Self, Clock}, derived_object, event};
use world::{
    access::{Self, OwnerCap, ServerAddressRegistry},
    character::Character,
    in_game_id,
    object_registry::ObjectRegistry,
    storage_unit::{Self, StorageUnit}
};
use world_npc::npc::NpcProfile;

#[error(code = 0)]
const ENotAssemblyOwner: vector<u8> = b"OwnerCap does not authorize this assembly access policy";
#[error(code = 1)]
const EPolicyMismatch: vector<u8> = b"Access policy does not match this registry or assembly";
#[error(code = 2)]
const EGrantIdInvalid: vector<u8> = b"Access grant ID must be exactly 16 bytes";
#[error(code = 3)]
const EPrincipalInvalid: vector<u8> = b"Access principal kind or identifier is invalid";
#[error(code = 4)]
const ECapabilitiesInvalid: vector<u8> =
    b"Access capability mask is empty or contains unknown bits";
#[error(code = 5)]
const EExpiryInvalid: vector<u8> = b"Access grant expiry is invalid";
#[error(code = 6)]
const EDelegationInvalid: vector<u8> = b"Delegated access is amplified or is not delegable";
#[error(code = 7)]
const EGrantInactive: vector<u8> = b"Access grant is revoked, expired, or stale";
#[error(code = 8)]
const ESubjectUnauthorized: vector<u8> = b"Transaction sender is not the access grant subject";
#[error(code = 9)]
const EStaleRevision: vector<u8> = b"Access policy or grant revision changed; read and retry";
#[error(code = 10)]
const ECustodyDelegationForbidden: vector<u8> =
    b"Inventory custody capabilities must be issued directly by the assembly owner";
#[error(code = 11)]
const EStorageBindingMismatch: vector<u8> =
    b"Storage Unit does not match its assembly access policy";
#[error(code = 12)]
const EActionIdInvalid: vector<u8> = b"Assembly action ID must be exactly 16 bytes";
#[error(code = 13)]
const EActionPayloadInvalid: vector<u8> =
    b"Assembly action type, payload, or commitment is invalid";
#[error(code = 14)]
const EActionExpiryInvalid: vector<u8> = b"Assembly action expiry is invalid";
#[error(code = 15)]
const EActionStateInvalid: vector<u8> = b"Assembly action is not in the required state";
#[error(code = 16)]
const EActionClaimInvalid: vector<u8> = b"Assembly action claim duration or claimant is invalid";
#[error(code = 17)]
const EServerUnauthorized: vector<u8> = b"Assembly action requires an authorized world server";

const PRINCIPAL_OWNER: u8 = 0;
const PRINCIPAL_PLAYER: u8 = 1;
const PRINCIPAL_NPC: u8 = 2;
const PRINCIPAL_TRIBE: u8 = 3;
const PRINCIPAL_FACTION: u8 = 4;

const CAP_GUI_VIEW: u64 = 1;
const CAP_OPERATE: u64 = 2;
const CAP_INVENTORY_DEPOSIT: u64 = 4;
const CAP_INVENTORY_WITHDRAW: u64 = 8;
const CAP_CONFIGURE: u64 = 16;
const CAP_MANAGE_ACCESS: u64 = 32;
const CAP_ALL: u64 = 63;
const CAP_CUSTODY: u64 = CAP_INVENTORY_DEPOSIT | CAP_INVENTORY_WITHDRAW;
const GRANT_ID_LENGTH: u64 = 16;
const CUSTODY_OWNED_TO_OPEN: u8 = 1;
const CUSTODY_OPEN_TO_OWNED: u8 = 2;
const CUSTODY_OPEN_TO_OPEN: u8 = 3;
const ACTION_ID_LENGTH: u64 = 16;
const ACTION_COMMITMENT_LENGTH: u64 = 32;
const ACTION_TYPE_MAX_LENGTH: u64 = 96;
const ACTION_PAYLOAD_MAX_LENGTH: u64 = 16384;
const ACTION_OUTCOME_MAX_LENGTH: u64 = 16384;
const ACTION_MAX_TTL_MS: u64 = 7 * 24 * 60 * 60 * 1000;
const ACTION_MAX_CLAIM_TTL_MS: u64 = 5 * 60 * 1000;
const ACTION_QUEUED: u8 = 0;
const ACTION_CLAIMED: u8 = 1;
const ACTION_FULFILLED: u8 = 2;
const ACTION_FAILED: u8 = 3;
const ACTION_CANCELLED: u8 = 4;

public struct AssemblyAccessPolicyKey has copy, drop, store { assembly_id: ID }

public struct AssemblyAccessGrantKey has copy, drop, store {
    policy_id: ID,
    grant_id: vector<u8>,
}

/// Deterministic key shared by the server journal and every dApp queue. UUID
/// bytes are used instead of an address so actions can be prepared offline and
/// retried without creating duplicate objects.
public struct AssemblyActionKey has copy, drop, store { action_id: vector<u8> }

public struct AssemblyAccessPolicy has key {
    id: UID,
    registry_id: ID,
    assembly_id: ID,
    owner_cap_id: ID,
    revision: u64,
}

public struct AssemblyAccessGrant has key {
    id: UID,
    registry_id: ID,
    policy_id: ID,
    assembly_id: ID,
    grant_id: vector<u8>,
    recipient_kind: u8,
    recipient_id: String,
    capabilities: u64,
    grantor_kind: u8,
    grantor_id: String,
    parent_grant_id: Option<ID>,
    expires_at_ms: u64,
    delegable: bool,
    delegation_depth: u8,
    revision: u64,
    policy_revision: u64,
    revoked: bool,
}

/// Authoritative cross-assembly action. The local server journal and dApp task
/// queue are projections of this shared object, never independent queues.
public struct AssemblyAction has key {
    id: UID,
    registry_id: ID,
    action_id: vector<u8>,
    source_assembly_id: ID,
    target_assembly_id: ID,
    creator: address,
    action_type: vector<u8>,
    payload: vector<u8>,
    payload_commitment: vector<u8>,
    priority: u64,
    priority_flags: u64,
    created_at_ms: u64,
    expires_at_ms: u64,
    status: u8,
    revision: u64,
    claimed_by: address,
    claim_expires_at_ms: u64,
    outcome: vector<u8>,
    server_action: bool,
}

/// Package-owned root for deterministic access policies.
public struct AssemblyAccessRegistry has key {
    id: UID,
}

/// Unforgeable witness used only by this module after validating the relevant
/// policy and grant. Storage Units must opt into this exact extension type.
public struct AssemblyAccessWitness has drop {}

public struct AssemblyAccessPolicyCreated has copy, drop {
    policy_id: ID,
    registry_id: ID,
    assembly_id: ID,
    owner_cap_id: ID,
    revision: u64,
}

public struct AssemblyAccessGrantCreated has copy, drop {
    grant_object_id: ID,
    policy_id: ID,
    assembly_id: ID,
    grant_id: vector<u8>,
    recipient_kind: u8,
    recipient_id: String,
    capabilities: u64,
    grantor_kind: u8,
    grantor_id: String,
    parent_grant_id: Option<ID>,
    expires_at_ms: u64,
    delegable: bool,
    delegation_depth: u8,
    policy_revision: u64,
}

public struct AssemblyAccessGrantRevoked has copy, drop {
    grant_object_id: ID,
    policy_id: ID,
    assembly_id: ID,
    grant_id: vector<u8>,
    policy_revision: u64,
    grant_revision: u64,
}

public struct AssemblyCustodyTransferred has copy, drop {
    operation_id: vector<u8>,
    custody_kind: u8,
    source_assembly_id: ID,
    destination_assembly_id: ID,
    actor_character_id: ID,
    type_id: u64,
    quantity: u32,
}

public struct AssemblyActionQueued has copy, drop {
    action_object_id: ID,
    registry_id: ID,
    action_id: vector<u8>,
    source_assembly_id: ID,
    target_assembly_id: ID,
    creator: address,
    action_type: vector<u8>,
    payload_commitment: vector<u8>,
    priority: u64,
    priority_flags: u64,
    created_at_ms: u64,
    expires_at_ms: u64,
    server_action: bool,
}

public struct AssemblyActionTransitioned has copy, drop {
    action_object_id: ID,
    action_id: vector<u8>,
    actor: address,
    status: u8,
    revision: u64,
    at_ms: u64,
}

public fun policy_key(assembly_id: ID): AssemblyAccessPolicyKey {
    AssemblyAccessPolicyKey { assembly_id }
}

public fun grant_key(policy_id: ID, grant_id: vector<u8>): AssemblyAccessGrantKey {
    AssemblyAccessGrantKey { policy_id, grant_id }
}

public fun action_key(action_id: vector<u8>): AssemblyActionKey {
    AssemblyActionKey { action_id }
}

/// Establish the unique policy for any assembly type.
public fun create_policy<T: key>(
    registry: &mut ObjectRegistry,
    access_registry: &mut AssemblyAccessRegistry,
    assembly_id: ID,
    owner_cap: &OwnerCap<T>,
    _ctx: &mut TxContext,
) {
    assert!(access::is_authorized(owner_cap, assembly_id), ENotAssemblyOwner);
    let uid = derived_object::claim(&mut access_registry.id, policy_key(assembly_id));
    let policy_id = object::uid_to_inner(&uid);
    let owner_cap_id = object::id(owner_cap);
    let policy = AssemblyAccessPolicy {
        id: uid,
        registry_id: object::id(registry),
        assembly_id,
        owner_cap_id,
        revision: 1,
    };
    event::emit(AssemblyAccessPolicyCreated {
        policy_id,
        registry_id: object::id(registry),
        assembly_id,
        owner_cap_id,
        revision: 1,
    });
    transfer::share_object(policy);
}

fun init(ctx: &mut TxContext) {
    transfer::share_object(AssemblyAccessRegistry { id: object::new(ctx) });
}

#[test_only]
public fun init_for_testing(ctx: &mut TxContext) {
    init(ctx);
}

public fun access_registry_id(registry: &AssemblyAccessRegistry): ID {
    object::id(registry)
}

/// Queue an owner-authored dApp action. The action is immediately shared so a
/// server, another assembly owner, or an indexer can consume the same object.
public fun queue_action<T: key>(
    access_registry: &mut AssemblyAccessRegistry,
    source_assembly_id: ID,
    target_assembly_id: ID,
    source_owner_cap: &OwnerCap<T>,
    action_id: vector<u8>,
    action_type: vector<u8>,
    payload: vector<u8>,
    payload_commitment: vector<u8>,
    priority: u64,
    priority_flags: u64,
    expires_at_ms: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(access::is_authorized(source_owner_cap, source_assembly_id), ENotAssemblyOwner);
    create_action(
        access_registry,
        source_assembly_id,
        target_assembly_id,
        action_id,
        action_type,
        payload,
        payload_commitment,
        priority,
        priority_flags,
        expires_at_ms,
        false,
        clock,
        ctx,
    );
}

/// Queue a world-observed action such as a neighboring-system scan alert.
/// Only an address registered by the deployed world may use this path.
public fun queue_server_action(
    access_registry: &mut AssemblyAccessRegistry,
    server_registry: &ServerAddressRegistry,
    source_assembly_id: ID,
    target_assembly_id: ID,
    action_id: vector<u8>,
    action_type: vector<u8>,
    payload: vector<u8>,
    payload_commitment: vector<u8>,
    priority: u64,
    priority_flags: u64,
    expires_at_ms: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(
        access::is_authorized_server_address(server_registry, ctx.sender()),
        EServerUnauthorized,
    );
    create_action(
        access_registry,
        source_assembly_id,
        target_assembly_id,
        action_id,
        action_type,
        payload,
        payload_commitment,
        priority,
        priority_flags,
        expires_at_ms,
        true,
        clock,
        ctx,
    );
}

fun create_action(
    access_registry: &mut AssemblyAccessRegistry,
    source_assembly_id: ID,
    target_assembly_id: ID,
    action_id: vector<u8>,
    action_type: vector<u8>,
    payload: vector<u8>,
    payload_commitment: vector<u8>,
    priority: u64,
    priority_flags: u64,
    expires_at_ms: u64,
    server_action: bool,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(action_id.length() == ACTION_ID_LENGTH, EActionIdInvalid);
    assert!(
        !action_type.is_empty() && action_type.length() <= ACTION_TYPE_MAX_LENGTH &&
            payload.length() <= ACTION_PAYLOAD_MAX_LENGTH &&
            payload_commitment.length() == ACTION_COMMITMENT_LENGTH,
        EActionPayloadInvalid,
    );
    let created_at_ms = clock.timestamp_ms();
    assert!(
        expires_at_ms > created_at_ms && expires_at_ms - created_at_ms <= ACTION_MAX_TTL_MS,
        EActionExpiryInvalid,
    );
    let uid = derived_object::claim(&mut access_registry.id, action_key(copy action_id));
    let action_object_id = object::uid_to_inner(&uid);
    let registry_id = object::id(access_registry);
    let creator = ctx.sender();
    event::emit(AssemblyActionQueued {
        action_object_id,
        registry_id,
        action_id: copy action_id,
        source_assembly_id,
        target_assembly_id,
        creator,
        action_type: copy action_type,
        payload_commitment: copy payload_commitment,
        priority,
        priority_flags,
        created_at_ms,
        expires_at_ms,
        server_action,
    });
    transfer::share_object(AssemblyAction {
        id: uid,
        registry_id,
        action_id,
        source_assembly_id,
        target_assembly_id,
        creator,
        action_type,
        payload,
        payload_commitment,
        priority,
        priority_flags,
        created_at_ms,
        expires_at_ms,
        status: ACTION_QUEUED,
        revision: 1,
        claimed_by: @0x0,
        claim_expires_at_ms: 0,
        outcome: vector[],
        server_action,
    });
}

public fun claim_action<T: key>(
    action: &mut AssemblyAction,
    target_owner_cap: &OwnerCap<T>,
    claim_ttl_ms: u64,
    clock: &Clock,
    ctx: &TxContext,
) {
    assert!(access::is_authorized(target_owner_cap, action.target_assembly_id), ENotAssemblyOwner);
    claim(action, claim_ttl_ms, clock, ctx.sender());
}

public fun claim_server_action(
    action: &mut AssemblyAction,
    server_registry: &ServerAddressRegistry,
    claim_ttl_ms: u64,
    clock: &Clock,
    ctx: &TxContext,
) {
    assert!(
        access::is_authorized_server_address(server_registry, ctx.sender()),
        EServerUnauthorized,
    );
    claim(action, claim_ttl_ms, clock, ctx.sender());
}

fun claim(action: &mut AssemblyAction, claim_ttl_ms: u64, clock: &Clock, actor: address) {
    let at_ms = clock.timestamp_ms();
    assert!(at_ms < action.expires_at_ms, EActionExpiryInvalid);
    if (
        action.status == ACTION_CLAIMED && action.claimed_by == actor &&
            action.claim_expires_at_ms > at_ms
    ) {
        return
    };
    if (action.status == ACTION_CLAIMED && action.claim_expires_at_ms <= at_ms) {
        action.status = ACTION_QUEUED;
        action.claimed_by = @0x0;
        action.claim_expires_at_ms = 0;
    };
    assert!(action.status == ACTION_QUEUED, EActionStateInvalid);
    assert!(claim_ttl_ms > 0 && claim_ttl_ms <= ACTION_MAX_CLAIM_TTL_MS, EActionClaimInvalid);
    action.status = ACTION_CLAIMED;
    action.claimed_by = actor;
    action.claim_expires_at_ms = at_ms + claim_ttl_ms;
    action.revision = action.revision + 1;
    emit_action_transition(action, actor, at_ms);
}

public fun release_server_action(
    action: &mut AssemblyAction,
    server_registry: &ServerAddressRegistry,
    clock: &Clock,
    ctx: &TxContext,
) {
    assert!(
        access::is_authorized_server_address(server_registry, ctx.sender()),
        EServerUnauthorized,
    );
    assert!(
        action.status == ACTION_CLAIMED && action.claimed_by == ctx.sender(),
        EActionClaimInvalid,
    );
    action.status = ACTION_QUEUED;
    action.claimed_by = @0x0;
    action.claim_expires_at_ms = 0;
    action.revision = action.revision + 1;
    emit_action_transition(action, ctx.sender(), clock.timestamp_ms());
}

public fun complete_server_action(
    action: &mut AssemblyAction,
    server_registry: &ServerAddressRegistry,
    succeeded: bool,
    outcome: vector<u8>,
    clock: &Clock,
    ctx: &TxContext,
) {
    assert!(
        access::is_authorized_server_address(server_registry, ctx.sender()),
        EServerUnauthorized,
    );
    assert!(
        action.status == ACTION_CLAIMED && action.claimed_by == ctx.sender(),
        EActionClaimInvalid,
    );
    assert!(outcome.length() <= ACTION_OUTCOME_MAX_LENGTH, EActionPayloadInvalid);
    action.status = if (succeeded) ACTION_FULFILLED else ACTION_FAILED;
    action.outcome = outcome;
    action.claimed_by = @0x0;
    action.claim_expires_at_ms = 0;
    action.revision = action.revision + 1;
    emit_action_transition(action, ctx.sender(), clock.timestamp_ms());
}

public fun cancel_action<T: key>(
    action: &mut AssemblyAction,
    source_owner_cap: &OwnerCap<T>,
    clock: &Clock,
    ctx: &TxContext,
) {
    assert!(access::is_authorized(source_owner_cap, action.source_assembly_id), ENotAssemblyOwner);
    let at_ms = clock.timestamp_ms();
    assert!(
        action.status == ACTION_QUEUED ||
            (action.status == ACTION_CLAIMED && action.claim_expires_at_ms <= at_ms),
        EActionStateInvalid,
    );
    action.status = ACTION_CANCELLED;
    action.claimed_by = @0x0;
    action.claim_expires_at_ms = 0;
    action.revision = action.revision + 1;
    emit_action_transition(action, ctx.sender(), at_ms);
}

fun emit_action_transition(action: &AssemblyAction, actor: address, at_ms: u64) {
    event::emit(AssemblyActionTransitioned {
        action_object_id: object::id(action),
        action_id: copy action.action_id,
        actor,
        status: action.status,
        revision: action.revision,
        at_ms,
    });
}

public fun action_id(action: &AssemblyAction): vector<u8> { action.action_id }

public fun action_source(action: &AssemblyAction): ID { action.source_assembly_id }

public fun action_target(action: &AssemblyAction): ID { action.target_assembly_id }

public fun action_type(action: &AssemblyAction): &vector<u8> { &action.action_type }

public fun action_payload(action: &AssemblyAction): &vector<u8> { &action.payload }

public fun action_payload_commitment(action: &AssemblyAction): &vector<u8> {
    &action.payload_commitment
}

public fun action_priority(action: &AssemblyAction): u64 { action.priority }

public fun action_priority_flags(action: &AssemblyAction): u64 { action.priority_flags }

public fun action_status(action: &AssemblyAction): u8 { action.status }

public fun action_revision(action: &AssemblyAction): u64 { action.revision }

public fun action_expires_at_ms(action: &AssemblyAction): u64 { action.expires_at_ms }

public fun action_outcome(action: &AssemblyAction): &vector<u8> { &action.outcome }

public fun action_is_server_authored(action: &AssemblyAction): bool { action.server_action }

public fun action_queued_status(): u8 { ACTION_QUEUED }

public fun action_claimed_status(): u8 { ACTION_CLAIMED }

public fun action_fulfilled_status(): u8 { ACTION_FULFILLED }

public fun action_failed_status(): u8 { ACTION_FAILED }

public fun action_cancelled_status(): u8 { ACTION_CANCELLED }

/// Configure a Storage Unit to accept access-checked open-inventory moves.
public fun bind_storage_unit(
    policy: &AssemblyAccessPolicy,
    storage_unit: &mut StorageUnit,
    owner_cap: &OwnerCap<StorageUnit>,
) {
    assert_owner(policy, owner_cap);
    assert!(storage_unit.id() == policy.assembly_id, EStorageBindingMismatch);
    storage_unit::authorize_extension<AssemblyAccessWitness>(storage_unit, owner_cap);
}

/// Direct owner issuance. This is the only path that may issue deposit or
/// withdraw capabilities.
public fun grant_by_owner<T: key>(
    registry: &mut ObjectRegistry,
    policy: &mut AssemblyAccessPolicy,
    owner_cap: &OwnerCap<T>,
    grant_id: vector<u8>,
    recipient_kind: u8,
    recipient_id: String,
    capabilities: u64,
    grantor_kind: u8,
    grantor_id: String,
    expires_at_ms: u64,
    delegable: bool,
    delegation_depth: u8,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert_owner(policy, owner_cap);
    create_grant(
        registry,
        policy,
        grant_id,
        recipient_kind,
        recipient_id,
        capabilities,
        grantor_kind,
        grantor_id,
        option::none(),
        expires_at_ms,
        delegable,
        delegation_depth,
        clock,
        ctx,
    );
}

/// Attenuated delegation by a player Character. Custody rights cannot be
/// delegated, because a revoked ancestor must not leave a usable asset grant.
public fun delegate_by_character(
    registry: &mut ObjectRegistry,
    policy: &mut AssemblyAccessPolicy,
    parent: &AssemblyAccessGrant,
    character: &Character,
    grant_id: vector<u8>,
    recipient_kind: u8,
    recipient_id: String,
    capabilities: u64,
    expires_at_ms: u64,
    delegable: bool,
    delegation_depth: u8,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert_character_subject(parent, character, clock, ctx);
    assert_delegation(policy, parent, capabilities, expires_at_ms, delegation_depth);
    assert!(capabilities & CAP_CUSTODY == 0, ECustodyDelegationForbidden);
    let grantor_id = in_game_id::item_id(&character.key()).to_string();
    create_grant(
        registry,
        policy,
        grant_id,
        recipient_kind,
        recipient_id,
        capabilities,
        PRINCIPAL_PLAYER,
        grantor_id,
        option::some(object::id(parent)),
        expires_at_ms,
        delegable,
        delegation_depth,
        clock,
        ctx,
    );
}

/// Attenuated delegation by an NPC profile bound to its faction wallet.
public fun delegate_by_npc(
    registry: &mut ObjectRegistry,
    policy: &mut AssemblyAccessPolicy,
    parent: &AssemblyAccessGrant,
    profile: &NpcProfile,
    grant_id: vector<u8>,
    recipient_kind: u8,
    recipient_id: String,
    capabilities: u64,
    expires_at_ms: u64,
    delegable: bool,
    delegation_depth: u8,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert_npc_subject(parent, profile, clock, ctx);
    assert_delegation(policy, parent, capabilities, expires_at_ms, delegation_depth);
    assert!(capabilities & CAP_CUSTODY == 0, ECustodyDelegationForbidden);
    create_grant(
        registry,
        policy,
        grant_id,
        recipient_kind,
        recipient_id,
        capabilities,
        PRINCIPAL_NPC,
        profile.npc_id().to_string(),
        option::some(object::id(parent)),
        expires_at_ms,
        delegable,
        delegation_depth,
        clock,
        ctx,
    );
}

public fun revoke_by_owner<T: key>(
    policy: &mut AssemblyAccessPolicy,
    grant: &mut AssemblyAccessGrant,
    owner_cap: &OwnerCap<T>,
    expected_policy_revision: u64,
    expected_grant_revision: u64,
) {
    assert_owner(policy, owner_cap);
    assert_revisions(policy, grant, expected_policy_revision, expected_grant_revision);
    revoke(policy, grant);
}

/// A player may revoke grants they personally issued, or relinquish a grant
/// addressed directly to their Character. Tribe grants remain group-scoped.
public fun revoke_by_character(
    policy: &mut AssemblyAccessPolicy,
    grant: &mut AssemblyAccessGrant,
    character: &Character,
    expected_policy_revision: u64,
    expected_grant_revision: u64,
    ctx: &TxContext,
) {
    assert_revisions(policy, grant, expected_policy_revision, expected_grant_revision);
    assert!(character.character_address() == ctx.sender(), ESubjectUnauthorized);
    let identifier = in_game_id::item_id(&character.key()).to_string();
    let issued = grant.grantor_kind == PRINCIPAL_PLAYER && grant.grantor_id == identifier;
    let direct_recipient =
        grant.recipient_kind == PRINCIPAL_PLAYER && grant.recipient_id == identifier;
    assert!(issued || direct_recipient, ESubjectUnauthorized);
    revoke(policy, grant);
}

public fun revoke_by_npc(
    policy: &mut AssemblyAccessPolicy,
    grant: &mut AssemblyAccessGrant,
    profile: &NpcProfile,
    expected_policy_revision: u64,
    expected_grant_revision: u64,
    ctx: &TxContext,
) {
    assert_revisions(policy, grant, expected_policy_revision, expected_grant_revision);
    assert!(
        !profile.is_retired() && profile.wallet_address() == ctx.sender(),
        ESubjectUnauthorized,
    );
    let identifier = profile.npc_id().to_string();
    let issued = grant.grantor_kind == PRINCIPAL_NPC && grant.grantor_id == identifier;
    let direct_recipient =
        grant.recipient_kind == PRINCIPAL_NPC && grant.recipient_id == identifier;
    assert!(issued || direct_recipient, ESubjectUnauthorized);
    revoke(policy, grant);
}

/// Move items from a Character's owned partition into shared/open custody.
public fun move_owned_to_open<T: key>(
    policy: &AssemblyAccessPolicy,
    grant: &AssemblyAccessGrant,
    storage_unit: &mut StorageUnit,
    character: &Character,
    owner_cap: &OwnerCap<T>,
    operation_id: vector<u8>,
    type_id: u64,
    quantity: u32,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(operation_id.length() == GRANT_ID_LENGTH, EGrantIdInvalid);
    assert!(storage_unit.id() == policy.assembly_id, EStorageBindingMismatch);
    assert_character_capability(policy, grant, character, CAP_INVENTORY_DEPOSIT, clock, ctx);
    let item = storage_unit.withdraw_by_owner(character, owner_cap, type_id, quantity, ctx);
    storage_unit.deposit_to_open_inventory(character, item, AssemblyAccessWitness {}, ctx);
    emit_custody(
        operation_id,
        CUSTODY_OWNED_TO_OPEN,
        storage_unit.id(),
        storage_unit.id(),
        character.id(),
        type_id,
        quantity,
    );
}

/// NPC equivalent of `move_owned_to_open`. The active NpcProfile binds the
/// wallet, durable NPC ID/faction, and compatible Character used by inventory.
public fun move_owned_to_open_by_npc<T: key>(
    policy: &AssemblyAccessPolicy,
    grant: &AssemblyAccessGrant,
    storage_unit: &mut StorageUnit,
    character: &Character,
    profile: &NpcProfile,
    owner_cap: &OwnerCap<T>,
    operation_id: vector<u8>,
    type_id: u64,
    quantity: u32,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(operation_id.length() == GRANT_ID_LENGTH, EGrantIdInvalid);
    assert!(storage_unit.id() == policy.assembly_id, EStorageBindingMismatch);
    assert_npc_character_capability(
        policy,
        grant,
        character,
        profile,
        CAP_INVENTORY_DEPOSIT,
        clock,
        ctx,
    );
    let item = storage_unit.withdraw_by_owner(character, owner_cap, type_id, quantity, ctx);
    storage_unit.deposit_to_open_inventory(character, item, AssemblyAccessWitness {}, ctx);
    emit_custody(
        operation_id,
        CUSTODY_OWNED_TO_OPEN,
        storage_unit.id(),
        storage_unit.id(),
        character.id(),
        type_id,
        quantity,
    );
}

/// Move shared/open custody into a Character's owned partition.
public fun move_open_to_owned(
    policy: &AssemblyAccessPolicy,
    grant: &AssemblyAccessGrant,
    storage_unit: &mut StorageUnit,
    character: &Character,
    operation_id: vector<u8>,
    type_id: u64,
    quantity: u32,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(operation_id.length() == GRANT_ID_LENGTH, EGrantIdInvalid);
    assert!(storage_unit.id() == policy.assembly_id, EStorageBindingMismatch);
    assert_character_capability(policy, grant, character, CAP_INVENTORY_WITHDRAW, clock, ctx);
    let item = storage_unit.withdraw_from_open_inventory(
        character,
        AssemblyAccessWitness {},
        type_id,
        quantity,
        ctx,
    );
    storage_unit.deposit_to_owned(character, item, AssemblyAccessWitness {}, ctx);
    emit_custody(
        operation_id,
        CUSTODY_OPEN_TO_OWNED,
        storage_unit.id(),
        storage_unit.id(),
        character.id(),
        type_id,
        quantity,
    );
}

/// NPC equivalent of `move_open_to_owned`.
public fun move_open_to_owned_by_npc(
    policy: &AssemblyAccessPolicy,
    grant: &AssemblyAccessGrant,
    storage_unit: &mut StorageUnit,
    character: &Character,
    profile: &NpcProfile,
    operation_id: vector<u8>,
    type_id: u64,
    quantity: u32,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(operation_id.length() == GRANT_ID_LENGTH, EGrantIdInvalid);
    assert!(storage_unit.id() == policy.assembly_id, EStorageBindingMismatch);
    assert_npc_character_capability(
        policy,
        grant,
        character,
        profile,
        CAP_INVENTORY_WITHDRAW,
        clock,
        ctx,
    );
    let item = storage_unit.withdraw_from_open_inventory(
        character,
        AssemblyAccessWitness {},
        type_id,
        quantity,
        ctx,
    );
    storage_unit.deposit_to_owned(character, item, AssemblyAccessWitness {}, ctx);
    emit_custody(
        operation_id,
        CUSTODY_OPEN_TO_OWNED,
        storage_unit.id(),
        storage_unit.id(),
        character.id(),
        type_id,
        quantity,
    );
}

/// Atomic cross-assembly custody transfer. Both source-withdraw and
/// destination-deposit grants are checked against the same Character and Clock.
public fun move_open_between_storage_units(
    source_policy: &AssemblyAccessPolicy,
    source_grant: &AssemblyAccessGrant,
    source: &mut StorageUnit,
    destination_policy: &AssemblyAccessPolicy,
    destination_grant: &AssemblyAccessGrant,
    destination: &mut StorageUnit,
    character: &Character,
    operation_id: vector<u8>,
    type_id: u64,
    quantity: u32,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(operation_id.length() == GRANT_ID_LENGTH, EGrantIdInvalid);
    assert!(source.id() == source_policy.assembly_id, EStorageBindingMismatch);
    assert!(destination.id() == destination_policy.assembly_id, EStorageBindingMismatch);
    assert_character_capability(
        source_policy,
        source_grant,
        character,
        CAP_INVENTORY_WITHDRAW,
        clock,
        ctx,
    );
    assert_character_capability(
        destination_policy,
        destination_grant,
        character,
        CAP_INVENTORY_DEPOSIT,
        clock,
        ctx,
    );
    let item = source.withdraw_from_open_inventory(
        character,
        AssemblyAccessWitness {},
        type_id,
        quantity,
        ctx,
    );
    destination.deposit_external_to_open_inventory(
        source,
        character,
        item,
        AssemblyAccessWitness {},
        ctx,
    );
    emit_custody(
        operation_id,
        CUSTODY_OPEN_TO_OPEN,
        source.id(),
        destination.id(),
        character.id(),
        type_id,
        quantity,
    );
}

/// Atomic NPC/faction-scoped cross-assembly custody transfer.
public fun move_open_between_storage_units_by_npc(
    source_policy: &AssemblyAccessPolicy,
    source_grant: &AssemblyAccessGrant,
    source: &mut StorageUnit,
    destination_policy: &AssemblyAccessPolicy,
    destination_grant: &AssemblyAccessGrant,
    destination: &mut StorageUnit,
    character: &Character,
    profile: &NpcProfile,
    operation_id: vector<u8>,
    type_id: u64,
    quantity: u32,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(operation_id.length() == GRANT_ID_LENGTH, EGrantIdInvalid);
    assert!(source.id() == source_policy.assembly_id, EStorageBindingMismatch);
    assert!(destination.id() == destination_policy.assembly_id, EStorageBindingMismatch);
    assert_npc_character_capability(
        source_policy,
        source_grant,
        character,
        profile,
        CAP_INVENTORY_WITHDRAW,
        clock,
        ctx,
    );
    assert_npc_character_capability(
        destination_policy,
        destination_grant,
        character,
        profile,
        CAP_INVENTORY_DEPOSIT,
        clock,
        ctx,
    );
    let item = source.withdraw_from_open_inventory(
        character,
        AssemblyAccessWitness {},
        type_id,
        quantity,
        ctx,
    );
    destination.deposit_external_to_open_inventory(
        source,
        character,
        item,
        AssemblyAccessWitness {},
        ctx,
    );
    emit_custody(
        operation_id,
        CUSTODY_OPEN_TO_OPEN,
        source.id(),
        destination.id(),
        character.id(),
        type_id,
        quantity,
    );
}

fun create_grant(
    registry: &mut ObjectRegistry,
    policy: &mut AssemblyAccessPolicy,
    grant_id: vector<u8>,
    recipient_kind: u8,
    recipient_id: String,
    capabilities: u64,
    grantor_kind: u8,
    grantor_id: String,
    parent_grant_id: Option<ID>,
    expires_at_ms: u64,
    delegable: bool,
    delegation_depth: u8,
    clock: &Clock,
    _ctx: &mut TxContext,
) {
    assert!(policy.registry_id == object::id(registry), EPolicyMismatch);
    assert!(grant_id.length() == GRANT_ID_LENGTH, EGrantIdInvalid);
    validate_principal(recipient_kind, &recipient_id, false);
    validate_principal(grantor_kind, &grantor_id, true);
    validate_capabilities(capabilities);
    assert!(expires_at_ms > clock::timestamp_ms(clock), EExpiryInvalid);
    assert!(
        (delegable && delegation_depth > 0) || (!delegable && delegation_depth == 0),
        EDelegationInvalid,
    );
    let policy_id = object::id(policy);
    let uid = derived_object::claim(
        &mut policy.id,
        grant_key(policy_id, grant_id),
    );
    let grant_object_id = object::uid_to_inner(&uid);
    policy.revision = policy.revision + 1;
    let grant = AssemblyAccessGrant {
        id: uid,
        registry_id: policy.registry_id,
        policy_id,
        assembly_id: policy.assembly_id,
        grant_id,
        recipient_kind,
        recipient_id,
        capabilities,
        grantor_kind,
        grantor_id,
        parent_grant_id,
        expires_at_ms,
        delegable,
        delegation_depth,
        revision: 1,
        policy_revision: policy.revision,
        revoked: false,
    };
    event::emit(AssemblyAccessGrantCreated {
        grant_object_id,
        policy_id,
        assembly_id: grant.assembly_id,
        grant_id,
        recipient_kind,
        recipient_id,
        capabilities,
        grantor_kind,
        grantor_id,
        parent_grant_id,
        expires_at_ms,
        delegable,
        delegation_depth,
        policy_revision: policy.revision,
    });
    transfer::share_object(grant);
}

fun assert_owner<T: key>(policy: &AssemblyAccessPolicy, owner_cap: &OwnerCap<T>) {
    assert!(
        object::id(owner_cap) == policy.owner_cap_id &&
            access::is_authorized(owner_cap, policy.assembly_id),
        ENotAssemblyOwner,
    );
}

fun assert_delegation(
    policy: &AssemblyAccessPolicy,
    parent: &AssemblyAccessGrant,
    capabilities: u64,
    expires_at_ms: u64,
    delegation_depth: u8,
) {
    assert_grant_policy(policy, parent);
    validate_capabilities(capabilities);
    assert!(
        !parent.revoked &&
            parent.delegable &&
            parent.delegation_depth > 0 &&
            delegation_depth < parent.delegation_depth &&
            capabilities & parent.capabilities == capabilities &&
            parent.capabilities & CAP_MANAGE_ACCESS != 0 &&
            expires_at_ms <= parent.expires_at_ms,
        EDelegationInvalid,
    );
}

fun assert_revisions(
    policy: &AssemblyAccessPolicy,
    grant: &AssemblyAccessGrant,
    expected_policy_revision: u64,
    expected_grant_revision: u64,
) {
    assert_grant_policy(policy, grant);
    assert!(
        policy.revision == expected_policy_revision && grant.revision == expected_grant_revision,
        EStaleRevision,
    );
    assert!(!grant.revoked, EGrantInactive);
}

fun revoke(policy: &mut AssemblyAccessPolicy, grant: &mut AssemblyAccessGrant) {
    grant.revoked = true;
    grant.revision = grant.revision + 1;
    policy.revision = policy.revision + 1;
    grant.policy_revision = policy.revision;
    event::emit(AssemblyAccessGrantRevoked {
        grant_object_id: object::id(grant),
        policy_id: object::id(policy),
        assembly_id: policy.assembly_id,
        grant_id: grant.grant_id,
        policy_revision: policy.revision,
        grant_revision: grant.revision,
    });
}

fun assert_character_capability(
    policy: &AssemblyAccessPolicy,
    grant: &AssemblyAccessGrant,
    character: &Character,
    capability: u64,
    clock: &Clock,
    ctx: &TxContext,
) {
    assert!(option::is_none(&grant.parent_grant_id), ECustodyDelegationForbidden);
    assert_character_subject(grant, character, clock, ctx);
    assert_grant_policy(policy, grant);
    assert!(grant.capabilities & capability == capability, ECapabilitiesInvalid);
}

fun assert_character_subject(
    grant: &AssemblyAccessGrant,
    character: &Character,
    clock: &Clock,
    ctx: &TxContext,
) {
    assert_active(grant, clock);
    assert!(character.character_address() == ctx.sender(), ESubjectUnauthorized);
    let direct = in_game_id::item_id(&character.key()).to_string();
    let tribe = character.tribe().to_string();
    assert!(
        (grant.recipient_kind == PRINCIPAL_PLAYER && grant.recipient_id == direct) ||
            (grant.recipient_kind == PRINCIPAL_TRIBE && grant.recipient_id == tribe),
        ESubjectUnauthorized,
    );
}

fun assert_npc_character_capability(
    policy: &AssemblyAccessPolicy,
    grant: &AssemblyAccessGrant,
    character: &Character,
    profile: &NpcProfile,
    capability: u64,
    clock: &Clock,
    ctx: &TxContext,
) {
    assert!(option::is_none(&grant.parent_grant_id), ECustodyDelegationForbidden);
    assert!(profile.character_id() == character.id(), ESubjectUnauthorized);
    assert_npc_subject(grant, profile, clock, ctx);
    assert_grant_policy(policy, grant);
    assert!(grant.capabilities & capability == capability, ECapabilitiesInvalid);
}

fun assert_npc_subject(
    grant: &AssemblyAccessGrant,
    profile: &NpcProfile,
    clock: &Clock,
    ctx: &TxContext,
) {
    assert_active(grant, clock);
    assert!(
        !profile.is_retired() && profile.wallet_address() == ctx.sender(),
        ESubjectUnauthorized,
    );
    assert!(
        (grant.recipient_kind == PRINCIPAL_NPC && grant.recipient_id == profile.npc_id().to_string()) ||
            (grant.recipient_kind == PRINCIPAL_FACTION &&
                grant.recipient_id == profile.profile_faction_key()),
        ESubjectUnauthorized,
    );
}

fun assert_active(grant: &AssemblyAccessGrant, clock: &Clock) {
    assert!(!grant.revoked && grant.expires_at_ms > clock::timestamp_ms(clock), EGrantInactive);
}

fun assert_grant_policy(policy: &AssemblyAccessPolicy, grant: &AssemblyAccessGrant) {
    assert!(
        grant.registry_id == policy.registry_id &&
            grant.policy_id == object::id(policy) &&
            grant.assembly_id == policy.assembly_id,
        EPolicyMismatch,
    );
}

fun validate_principal(kind: u8, identifier: &String, allow_owner: bool) {
    let valid_kind =
        (allow_owner && kind == PRINCIPAL_OWNER) ||
        kind == PRINCIPAL_PLAYER || kind == PRINCIPAL_NPC ||
        kind == PRINCIPAL_TRIBE || kind == PRINCIPAL_FACTION;
    assert!(
        valid_kind && identifier.length() <= 128 &&
        ((allow_owner && kind == PRINCIPAL_OWNER) || !identifier.is_empty()),
        EPrincipalInvalid,
    );
}

fun validate_capabilities(capabilities: u64) {
    assert!(capabilities > 0 && capabilities & CAP_ALL == capabilities, ECapabilitiesInvalid);
}

fun emit_custody(
    operation_id: vector<u8>,
    custody_kind: u8,
    source_assembly_id: ID,
    destination_assembly_id: ID,
    actor_character_id: ID,
    type_id: u64,
    quantity: u32,
) {
    event::emit(AssemblyCustodyTransferred {
        operation_id,
        custody_kind,
        source_assembly_id,
        destination_assembly_id,
        actor_character_id,
        type_id,
        quantity,
    });
}

public fun id(policy: &AssemblyAccessPolicy): ID { object::id(policy) }

public fun registry_id(policy: &AssemblyAccessPolicy): ID { policy.registry_id }

public fun assembly_id(policy: &AssemblyAccessPolicy): ID { policy.assembly_id }

public fun owner_cap_id(policy: &AssemblyAccessPolicy): ID { policy.owner_cap_id }

public fun policy_revision(policy: &AssemblyAccessPolicy): u64 { policy.revision }

public fun grant_object_id(grant: &AssemblyAccessGrant): ID { object::id(grant) }

public fun grant_policy_id(grant: &AssemblyAccessGrant): ID { grant.policy_id }

public fun grant_assembly_id(grant: &AssemblyAccessGrant): ID { grant.assembly_id }

public fun grant_identifier(grant: &AssemblyAccessGrant): vector<u8> { grant.grant_id }

public fun recipient_kind(grant: &AssemblyAccessGrant): u8 { grant.recipient_kind }

public fun recipient_id(grant: &AssemblyAccessGrant): String { grant.recipient_id }

public fun capabilities(grant: &AssemblyAccessGrant): u64 { grant.capabilities }

public fun grantor_kind(grant: &AssemblyAccessGrant): u8 { grant.grantor_kind }

public fun grantor_id(grant: &AssemblyAccessGrant): String { grant.grantor_id }

public fun parent_grant_id(grant: &AssemblyAccessGrant): Option<ID> { grant.parent_grant_id }

public fun expires_at_ms(grant: &AssemblyAccessGrant): u64 { grant.expires_at_ms }

public fun is_delegable(grant: &AssemblyAccessGrant): bool { grant.delegable }

public fun delegation_depth(grant: &AssemblyAccessGrant): u8 { grant.delegation_depth }

public fun grant_revision(grant: &AssemblyAccessGrant): u64 { grant.revision }

public fun grant_policy_revision(grant: &AssemblyAccessGrant): u64 { grant.policy_revision }

public fun is_revoked(grant: &AssemblyAccessGrant): bool { grant.revoked }

public fun player_principal(): u8 { PRINCIPAL_PLAYER }

public fun npc_principal(): u8 { PRINCIPAL_NPC }

public fun tribe_principal(): u8 { PRINCIPAL_TRIBE }

public fun faction_principal(): u8 { PRINCIPAL_FACTION }

public fun gui_view_capability(): u64 { CAP_GUI_VIEW }

public fun operate_capability(): u64 { CAP_OPERATE }

public fun inventory_deposit_capability(): u64 { CAP_INVENTORY_DEPOSIT }

public fun inventory_withdraw_capability(): u64 { CAP_INVENTORY_WITHDRAW }

public fun configure_capability(): u64 { CAP_CONFIGURE }

public fun manage_access_capability(): u64 { CAP_MANAGE_ACCESS }
