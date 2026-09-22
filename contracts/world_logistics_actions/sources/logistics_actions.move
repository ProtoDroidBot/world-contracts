/// Portable, two-phase inventory transfer intents for every assembly class.
///
/// The contract describes custody movement without importing a concrete
/// inventory implementation. The game server must claim the linked Action,
/// revalidate both endpoint revisions, perform the atomic game-state move, and
/// commit a receipt. This keeps ships, field storage, Industry lanes, turrets,
/// Storage Units, and Network Node fuel bays on one protocol.
module world_logistics_actions::logistics_actions;

use std::hash;
use sui::{bcs, clock::Clock, derived_object, event};
use world::access::{Self, OwnerCap, ServerAddressRegistry};
use world_action_queue::action_queue::{Self, Action, AssemblyActionQueue};

#[error(code = 0)]
const ENotAssemblyOwner: vector<u8> = b"OwnerCap does not authorize this logistics root";
#[error(code = 1)]
const ERootMismatch: vector<u8> = b"Logistics and action roots do not describe the same source assembly";
#[error(code = 2)]
const ETransferInvalid: vector<u8> = b"Transfer endpoint, item type, quantity, or ID is invalid";
#[error(code = 3)]
const ETransferStateInvalid: vector<u8> = b"Transfer intent is not in the required settlement state";
#[error(code = 4)]
const EActionMismatch: vector<u8> = b"Transfer intent does not match the linked action";
#[error(code = 5)]
const EServerUnauthorized: vector<u8> = b"Transfer settlement requires an authorized world server";
#[error(code = 6)]
const EReceiptInvalid: vector<u8> = b"Transfer settlement receipt is invalid";

const TRANSFER_VERSION: u8 = 1;
const TRANSFER_ID_LENGTH: u64 = 16;
const COMMITMENT_LENGTH: u64 = 32;

const ENDPOINT_STORAGE: u8 = 0;
const ENDPOINT_INDUSTRY_INPUT: u8 = 1;
const ENDPOINT_INDUSTRY_OUTPUT: u8 = 2;
const ENDPOINT_TURRET: u8 = 3;
const ENDPOINT_NETWORK_NODE_FUEL: u8 = 4;
const ENDPOINT_SHIP: u8 = 5;
const ENDPOINT_FIELD_STORAGE: u8 = 6;
const ENDPOINT_ASSEMBLY: u8 = 7;
const ENDPOINT_MAX: u8 = ENDPOINT_ASSEMBLY;

const STATE_PREPARED: u8 = 0;
const STATE_SETTLING: u8 = 1;
const STATE_SETTLED: u8 = 2;
const STATE_FAILED: u8 = 3;
const STATE_CANCELLED: u8 = 4;

public struct AssemblyTransferRootKey has copy, drop, store { assembly_id: ID }
public struct TransferIntentKey has copy, drop, store { transfer_id: vector<u8> }

public struct LogisticsRegistry has key { id: UID }

public struct AssemblyTransferRoot has key {
    id: UID,
    registry_id: ID,
    assembly_id: ID,
}

/// Stable portable command envelope used as the canonical Action payload.
public struct TransferCommand has copy, drop, store {
    version: u8,
    transfer_id: vector<u8>,
    source_id: ID,
    destination_id: ID,
    source_kind: u8,
    destination_kind: u8,
    type_id: u64,
    quantity: u64,
    expected_source_revision: u64,
    expected_destination_revision: u64,
}

public struct TransferReceipt has copy, drop, store {
    transfer_id: vector<u8>,
    settled_quantity: u64,
    source_revision: u64,
    destination_revision: u64,
    receipt_commitment: vector<u8>,
}

public struct TransferIntent has key {
    id: UID,
    registry_id: ID,
    root_id: ID,
    action_id: ID,
    command: TransferCommand,
    initiator: address,
    state: u8,
    revision: u64,
    claimed_by: address,
    claim_expires_at_ms: u64,
    settled_quantity: u64,
    source_revision: u64,
    destination_revision: u64,
    receipt_commitment: vector<u8>,
    failure_code: u64,
    created_at_ms: u64,
    updated_at_ms: u64,
}

public struct AssemblyTransferRootCreated has copy, drop {
    root_id: ID,
    registry_id: ID,
    assembly_id: ID,
    creator: address,
    server_created: bool,
}

public struct TransferPrepared has copy, drop {
    intent_id: ID,
    action_id: ID,
    transfer_id: vector<u8>,
    source_id: ID,
    destination_id: ID,
    type_id: u64,
    quantity: u64,
    expected_source_revision: u64,
    expected_destination_revision: u64,
}

public struct TransferTransitioned has copy, drop {
    intent_id: ID,
    action_id: ID,
    actor: address,
    state: u8,
    revision: u64,
    at_ms: u64,
}

fun init(ctx: &mut TxContext) {
    transfer::share_object(LogisticsRegistry { id: object::new(ctx) });
}

#[test_only]
public fun init_for_testing(ctx: &mut TxContext) { init(ctx); }

public fun root_key(assembly_id: ID): AssemblyTransferRootKey {
    AssemblyTransferRootKey { assembly_id }
}

public fun intent_key(transfer_id: vector<u8>): TransferIntentKey {
    TransferIntentKey { transfer_id }
}

public fun registry_id(registry: &LogisticsRegistry): ID { object::id(registry) }

public fun root_object_id(registry: &LogisticsRegistry, assembly_id: ID): ID {
    object::id_from_address(derived_object::derive_address(object::id(registry), root_key(assembly_id)))
}

public fun intent_object_id(root: &AssemblyTransferRoot, transfer_id: vector<u8>): ID {
    object::id_from_address(derived_object::derive_address(object::id(root), intent_key(transfer_id)))
}

public fun create_root<T: key>(
    registry: &mut LogisticsRegistry,
    assembly_id: ID,
    owner_cap: &OwnerCap<T>,
    ctx: &mut TxContext,
) {
    assert!(access::is_authorized(owner_cap, assembly_id), ENotAssemblyOwner);
    create_root_internal(registry, assembly_id, false, ctx);
}

public fun create_server_root(
    registry: &mut LogisticsRegistry,
    server_registry: &ServerAddressRegistry,
    assembly_id: ID,
    ctx: &mut TxContext,
) {
    assert_server(server_registry, ctx);
    create_root_internal(registry, assembly_id, true, ctx);
}

fun create_root_internal(
    registry: &mut LogisticsRegistry,
    assembly_id: ID,
    server_created: bool,
    ctx: &mut TxContext,
) {
    let registry_id = object::id(registry);
    let uid = derived_object::claim(&mut registry.id, root_key(assembly_id));
    let root_id = object::uid_to_inner(&uid);
    event::emit(AssemblyTransferRootCreated {
        root_id,
        registry_id,
        assembly_id,
        creator: ctx.sender(),
        server_created,
    });
    transfer::share_object(AssemblyTransferRoot { id: uid, registry_id, assembly_id });
}

public fun new_transfer(
    transfer_id: vector<u8>,
    source_id: ID,
    destination_id: ID,
    source_kind: u8,
    destination_kind: u8,
    type_id: u64,
    quantity: u64,
    expected_source_revision: u64,
    expected_destination_revision: u64,
): TransferCommand {
    let command = TransferCommand {
        version: TRANSFER_VERSION,
        transfer_id,
        source_id,
        destination_id,
        source_kind,
        destination_kind,
        type_id,
        quantity,
        expected_source_revision,
        expected_destination_revision,
    };
    validate_command(&command);
    command
}

/// Phase one: authenticate and publish an immutable transfer description while
/// queueing its executable Action below the same source assembly.
public fun prepare_transfer<T: key>(
    root: &mut AssemblyTransferRoot,
    action_queue_root: &mut AssemblyActionQueue,
    source_owner_cap: &OwnerCap<T>,
    command: TransferCommand,
    priority: u64,
    priority_flags: u64,
    expires_at_ms: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    validate_command(&command);
    assert!(
        root.assembly_id == command.source_id &&
            action_queue::queue_assembly_id(action_queue_root) == command.source_id,
        ERootMismatch,
    );
    assert!(access::is_authorized(source_owner_cap, command.source_id), ENotAssemblyOwner);
    let payload = bcs::to_bytes(&command);
    let payload_commitment = hash::sha2_256(copy payload);
    let action_id = action_queue::action_object_id(action_queue_root, copy command.transfer_id);
    action_queue::queue_action<T>(
        action_queue_root,
        command.destination_id,
        source_owner_cap,
        copy command.transfer_id,
        b"logistics.transfer",
        payload,
        payload_commitment,
        priority,
        priority_flags,
        expires_at_ms,
        clock,
        ctx,
    );
    let uid = derived_object::claim(&mut root.id, intent_key(copy command.transfer_id));
    let intent_id = object::uid_to_inner(&uid);
    let now = clock.timestamp_ms();
    event::emit(TransferPrepared {
        intent_id,
        action_id,
        transfer_id: copy command.transfer_id,
        source_id: command.source_id,
        destination_id: command.destination_id,
        type_id: command.type_id,
        quantity: command.quantity,
        expected_source_revision: command.expected_source_revision,
        expected_destination_revision: command.expected_destination_revision,
    });
    transfer::share_object(TransferIntent {
        id: uid,
        registry_id: root.registry_id,
        root_id: object::id(root),
        action_id,
        command,
        initiator: ctx.sender(),
        state: STATE_PREPARED,
        revision: 1,
        claimed_by: @0x0,
        claim_expires_at_ms: 0,
        settled_quantity: 0,
        source_revision: 0,
        destination_revision: 0,
        receipt_commitment: vector[],
        failure_code: 0,
        created_at_ms: now,
        updated_at_ms: now,
    });
}

/// Phase two begins when the authoritative server claims both projections.
public fun begin_settlement(
    intent: &mut TransferIntent,
    action: &mut Action,
    server_registry: &ServerAddressRegistry,
    claim_ttl_ms: u64,
    clock: &Clock,
    ctx: &TxContext,
) {
    assert_server(server_registry, ctx);
    let now = clock.timestamp_ms();
    assert!(
        intent.state == STATE_PREPARED ||
            (intent.state == STATE_SETTLING && intent.claim_expires_at_ms <= now),
        ETransferStateInvalid,
    );
    assert_link(intent, action);
    action_queue::claim_server_action(action, server_registry, claim_ttl_ms, clock, ctx);
    intent.state = STATE_SETTLING;
    intent.claimed_by = ctx.sender();
    intent.claim_expires_at_ms = action_queue::claim_expires_at_ms(action);
    transition(intent, now, ctx.sender());
}

public fun release_settlement(
    intent: &mut TransferIntent,
    action: &mut Action,
    server_registry: &ServerAddressRegistry,
    clock: &Clock,
    ctx: &TxContext,
) {
    assert_server(server_registry, ctx);
    assert!(intent.state == STATE_SETTLING && intent.claimed_by == ctx.sender(), ETransferStateInvalid);
    assert_link(intent, action);
    action_queue::release_server_action(action, server_registry, clock, ctx);
    intent.state = STATE_PREPARED;
    intent.claimed_by = @0x0;
    intent.claim_expires_at_ms = 0;
    transition(intent, clock.timestamp_ms(), ctx.sender());
}

public fun settle_transfer(
    intent: &mut TransferIntent,
    action: &mut Action,
    server_registry: &ServerAddressRegistry,
    settled_quantity: u64,
    source_revision: u64,
    destination_revision: u64,
    receipt_commitment: vector<u8>,
    clock: &Clock,
    ctx: &TxContext,
) {
    assert_server(server_registry, ctx);
    assert!(intent.state == STATE_SETTLING && intent.claimed_by == ctx.sender(), ETransferStateInvalid);
    assert_link(intent, action);
    assert!(
        settled_quantity == intent.command.quantity &&
            source_revision > intent.command.expected_source_revision &&
            destination_revision > intent.command.expected_destination_revision &&
            receipt_commitment.length() == COMMITMENT_LENGTH,
        EReceiptInvalid,
    );
    let receipt = TransferReceipt {
        transfer_id: copy intent.command.transfer_id,
        settled_quantity,
        source_revision,
        destination_revision,
        receipt_commitment: copy receipt_commitment,
    };
    action_queue::complete_server_action(
        action,
        server_registry,
        true,
        bcs::to_bytes(&receipt),
        clock,
        ctx,
    );
    intent.state = STATE_SETTLED;
    intent.claimed_by = @0x0;
    intent.claim_expires_at_ms = 0;
    intent.settled_quantity = settled_quantity;
    intent.source_revision = source_revision;
    intent.destination_revision = destination_revision;
    intent.receipt_commitment = receipt_commitment;
    transition(intent, clock.timestamp_ms(), ctx.sender());
}

public fun fail_transfer(
    intent: &mut TransferIntent,
    action: &mut Action,
    server_registry: &ServerAddressRegistry,
    failure_code: u64,
    clock: &Clock,
    ctx: &TxContext,
) {
    assert_server(server_registry, ctx);
    assert!(
        intent.state == STATE_SETTLING && intent.claimed_by == ctx.sender() && failure_code > 0,
        ETransferStateInvalid,
    );
    assert_link(intent, action);
    action_queue::complete_server_action(
        action,
        server_registry,
        false,
        bcs::to_bytes(&failure_code),
        clock,
        ctx,
    );
    intent.state = STATE_FAILED;
    intent.failure_code = failure_code;
    intent.claimed_by = @0x0;
    intent.claim_expires_at_ms = 0;
    transition(intent, clock.timestamp_ms(), ctx.sender());
}

public fun cancel_transfer<T: key>(
    intent: &mut TransferIntent,
    action: &mut Action,
    source_owner_cap: &OwnerCap<T>,
    clock: &Clock,
    ctx: &TxContext,
) {
    assert!(intent.state == STATE_PREPARED, ETransferStateInvalid);
    assert_link(intent, action);
    action_queue::cancel_action<T>(action, source_owner_cap, clock, ctx);
    intent.state = STATE_CANCELLED;
    transition(intent, clock.timestamp_ms(), ctx.sender());
}

fun validate_command(command: &TransferCommand) {
    assert!(
        command.version == TRANSFER_VERSION && command.transfer_id.length() == TRANSFER_ID_LENGTH &&
            command.source_id != command.destination_id && command.source_kind <= ENDPOINT_MAX &&
            command.destination_kind <= ENDPOINT_MAX && command.type_id > 0 && command.quantity > 0,
        ETransferInvalid,
    );
}

fun assert_link(intent: &TransferIntent, action: &Action) {
    assert!(
        intent.action_id == object::id(action) &&
            intent.command.source_id == action_queue::source(action) &&
            intent.command.destination_id == action_queue::target(action) &&
            intent.command.transfer_id == action_queue::action_id(action) &&
            *action_queue::action_type(action) == b"logistics.transfer",
        EActionMismatch,
    );
}

fun assert_server(server_registry: &ServerAddressRegistry, ctx: &TxContext) {
    assert!(access::is_authorized_server_address(server_registry, ctx.sender()), EServerUnauthorized);
}

fun transition(intent: &mut TransferIntent, at_ms: u64, actor: address) {
    intent.revision = intent.revision + 1;
    intent.updated_at_ms = at_ms;
    event::emit(TransferTransitioned {
        intent_id: object::id(intent),
        action_id: intent.action_id,
        actor,
        state: intent.state,
        revision: intent.revision,
        at_ms,
    });
}

public fun root_assembly_id(root: &AssemblyTransferRoot): ID { root.assembly_id }
public fun id(intent: &TransferIntent): ID { object::id(intent) }
public fun action_id(intent: &TransferIntent): ID { intent.action_id }
public fun command(intent: &TransferIntent): &TransferCommand { &intent.command }
public fun state(intent: &TransferIntent): u8 { intent.state }
public fun revision(intent: &TransferIntent): u64 { intent.revision }
public fun claimed_by(intent: &TransferIntent): address { intent.claimed_by }
public fun settled_quantity(intent: &TransferIntent): u64 { intent.settled_quantity }
public fun failure_code(intent: &TransferIntent): u64 { intent.failure_code }
public fun transfer_id(command: &TransferCommand): vector<u8> { command.transfer_id }
public fun source_id(command: &TransferCommand): ID { command.source_id }
public fun destination_id(command: &TransferCommand): ID { command.destination_id }
public fun source_kind(command: &TransferCommand): u8 { command.source_kind }
public fun destination_kind(command: &TransferCommand): u8 { command.destination_kind }
public fun type_id(command: &TransferCommand): u64 { command.type_id }
public fun quantity(command: &TransferCommand): u64 { command.quantity }
public fun expected_source_revision(command: &TransferCommand): u64 { command.expected_source_revision }
public fun expected_destination_revision(command: &TransferCommand): u64 { command.expected_destination_revision }

public fun storage_endpoint(): u8 { ENDPOINT_STORAGE }
public fun industry_input_endpoint(): u8 { ENDPOINT_INDUSTRY_INPUT }
public fun industry_output_endpoint(): u8 { ENDPOINT_INDUSTRY_OUTPUT }
public fun turret_endpoint(): u8 { ENDPOINT_TURRET }
public fun network_node_fuel_endpoint(): u8 { ENDPOINT_NETWORK_NODE_FUEL }
public fun ship_endpoint(): u8 { ENDPOINT_SHIP }
public fun field_storage_endpoint(): u8 { ENDPOINT_FIELD_STORAGE }
public fun assembly_endpoint(): u8 { ENDPOINT_ASSEMBLY }
public fun prepared_state(): u8 { STATE_PREPARED }
public fun settling_state(): u8 { STATE_SETTLING }
public fun settled_state(): u8 { STATE_SETTLED }
public fun failed_state(): u8 { STATE_FAILED }
public fun cancelled_state(): u8 { STATE_CANCELLED }
