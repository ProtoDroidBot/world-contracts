/// Typed infrastructure commands carried by the canonical action queue.
///
/// Commands are revision-bound intents. The server remains authoritative for
/// collision, range, inventory, fuel recipes, power headroom, and simulation
/// state, then completes the common Action with its durable receipt.
module world_infrastructure_actions::infrastructure_actions;

use std::hash;
use sui::{bcs, clock::Clock, event};
use world::access::{OwnerCap, ServerAddressRegistry};
use world_action_queue::action_queue::{Self, AssemblyActionQueue};

#[error(code = 0)]
const ECommandInvalid: vector<u8> = b"Infrastructure command shape is invalid";
#[error(code = 1)]
const ESourceMismatch: vector<u8> = b"Infrastructure command source does not match its action queue";

const COMMAND_VERSION: u8 = 1;
const KIND_ASSEMBLY_STATE: u8 = 0;
const KIND_ENERGY_CONNECT: u8 = 1;
const KIND_ENERGY_DISCONNECT: u8 = 2;
const KIND_GATE_LINK: u8 = 3;
const KIND_GATE_UNLINK: u8 = 4;
const KIND_REFUEL: u8 = 5;
const KIND_REACTIVATE: u8 = 6;
const KIND_MAX: u8 = KIND_REACTIVATE;
const COMMITMENT_LENGTH: u64 = 32;

public struct InfrastructureActionRegistry has key { id: UID }

/// A stable envelope with zero/empty unused fields for unambiguous BCS
/// decoding across Network Nodes, gates, and other Smart Assemblies.
public struct InfrastructureCommand has copy, drop, store {
    version: u8,
    kind: u8,
    source_assembly_id: ID,
    target_id: ID,
    expected_source_revision: u64,
    expected_target_revision: u64,
    desired_state: u8,
    resource_type_id: u64,
    resource_quantity: u64,
    requirements_commitment: vector<u8>,
}

public struct InfrastructureActionQueued has copy, drop {
    infrastructure_registry_id: ID,
    action_object_id: ID,
    action_id: vector<u8>,
    source_assembly_id: ID,
    target_id: ID,
    kind: u8,
    expected_source_revision: u64,
    expected_target_revision: u64,
    server_authored: bool,
}

fun init(ctx: &mut TxContext) {
    transfer::share_object(InfrastructureActionRegistry { id: object::new(ctx) });
}

#[test_only]
public fun init_for_testing(ctx: &mut TxContext) { init(ctx); }

public fun registry_id(registry: &InfrastructureActionRegistry): ID { object::id(registry) }

public fun assembly_state_command(
    assembly_id: ID,
    expected_revision: u64,
    desired_state: u8,
): InfrastructureCommand {
    build(
        KIND_ASSEMBLY_STATE,
        assembly_id,
        assembly_id,
        expected_revision,
        0,
        desired_state,
        0,
        0,
        vector[],
    )
}

public fun energy_connection_command(
    source_assembly_id: ID,
    target_id: ID,
    expected_source_revision: u64,
    expected_target_revision: u64,
    connect: bool,
): InfrastructureCommand {
    build(
        if (connect) KIND_ENERGY_CONNECT else KIND_ENERGY_DISCONNECT,
        source_assembly_id,
        target_id,
        expected_source_revision,
        expected_target_revision,
        0,
        0,
        0,
        vector[],
    )
}

public fun gate_link_command(
    source_gate_id: ID,
    destination_gate_id: ID,
    expected_source_revision: u64,
    expected_destination_revision: u64,
    link: bool,
): InfrastructureCommand {
    build(
        if (link) KIND_GATE_LINK else KIND_GATE_UNLINK,
        source_gate_id,
        destination_gate_id,
        expected_source_revision,
        expected_destination_revision,
        0,
        0,
        0,
        vector[],
    )
}

public fun refuel_command(
    assembly_id: ID,
    fuel_source_id: ID,
    expected_assembly_revision: u64,
    expected_fuel_source_revision: u64,
    fuel_type_id: u64,
    quantity: u64,
): InfrastructureCommand {
    build(
        KIND_REFUEL,
        assembly_id,
        fuel_source_id,
        expected_assembly_revision,
        expected_fuel_source_revision,
        0,
        fuel_type_id,
        quantity,
        vector[],
    )
}

public fun reactivate_command(
    infrastructure_id: ID,
    material_source_id: ID,
    expected_infrastructure_revision: u64,
    expected_material_source_revision: u64,
    fuel_type_id: u64,
    fuel_quantity: u64,
    requirements_commitment: vector<u8>,
): InfrastructureCommand {
    build(
        KIND_REACTIVATE,
        infrastructure_id,
        material_source_id,
        expected_infrastructure_revision,
        expected_material_source_revision,
        0,
        fuel_type_id,
        fuel_quantity,
        requirements_commitment,
    )
}

fun build(
    kind: u8,
    source_assembly_id: ID,
    target_id: ID,
    expected_source_revision: u64,
    expected_target_revision: u64,
    desired_state: u8,
    resource_type_id: u64,
    resource_quantity: u64,
    requirements_commitment: vector<u8>,
): InfrastructureCommand {
    let command = InfrastructureCommand {
        version: COMMAND_VERSION,
        kind,
        source_assembly_id,
        target_id,
        expected_source_revision,
        expected_target_revision,
        desired_state,
        resource_type_id,
        resource_quantity,
        requirements_commitment,
    };
    validate(&command);
    command
}

public fun queue_command<T: key>(
    queue: &mut AssemblyActionQueue,
    registry: &InfrastructureActionRegistry,
    owner_cap: &OwnerCap<T>,
    action_id: vector<u8>,
    command: InfrastructureCommand,
    priority: u64,
    priority_flags: u64,
    expires_at_ms: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    validate(&command);
    assert!(action_queue::queue_assembly_id(queue) == command.source_assembly_id, ESourceMismatch);
    let kind = command.kind;
    let source_assembly_id = command.source_assembly_id;
    let target_id = command.target_id;
    let expected_source_revision = command.expected_source_revision;
    let expected_target_revision = command.expected_target_revision;
    let payload = bcs::to_bytes(&command);
    let commitment = hash::sha2_256(copy payload);
    let action_object_id = action_queue::action_object_id(queue, copy action_id);
    action_queue::queue_action<T>(
        queue,
        target_id,
        owner_cap,
        copy action_id,
        action_type(kind),
        payload,
        commitment,
        priority,
        priority_flags,
        expires_at_ms,
        clock,
        ctx,
    );
    emit_queued(
        registry,
        action_object_id,
        action_id,
        source_assembly_id,
        target_id,
        kind,
        expected_source_revision,
        expected_target_revision,
        false,
    );
}

/// Authorized keepers may author NPC refuel/reactivation and world-maintenance
/// commands while retaining the exact same payload and receipt protocol.
public fun queue_server_command(
    queue: &mut AssemblyActionQueue,
    registry: &InfrastructureActionRegistry,
    server_registry: &ServerAddressRegistry,
    action_id: vector<u8>,
    command: InfrastructureCommand,
    priority: u64,
    priority_flags: u64,
    expires_at_ms: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    validate(&command);
    assert!(action_queue::queue_assembly_id(queue) == command.source_assembly_id, ESourceMismatch);
    let kind = command.kind;
    let source_assembly_id = command.source_assembly_id;
    let target_id = command.target_id;
    let expected_source_revision = command.expected_source_revision;
    let expected_target_revision = command.expected_target_revision;
    let payload = bcs::to_bytes(&command);
    let commitment = hash::sha2_256(copy payload);
    let action_object_id = action_queue::action_object_id(queue, copy action_id);
    action_queue::queue_server_action(
        queue,
        server_registry,
        target_id,
        copy action_id,
        action_type(kind),
        payload,
        commitment,
        priority,
        priority_flags,
        expires_at_ms,
        clock,
        ctx,
    );
    emit_queued(
        registry,
        action_object_id,
        action_id,
        source_assembly_id,
        target_id,
        kind,
        expected_source_revision,
        expected_target_revision,
        true,
    );
}

fun emit_queued(
    registry: &InfrastructureActionRegistry,
    action_object_id: ID,
    action_id: vector<u8>,
    source_assembly_id: ID,
    target_id: ID,
    kind: u8,
    expected_source_revision: u64,
    expected_target_revision: u64,
    server_authored: bool,
) {
    event::emit(InfrastructureActionQueued {
        infrastructure_registry_id: object::id(registry),
        action_object_id,
        action_id,
        source_assembly_id,
        target_id,
        kind,
        expected_source_revision,
        expected_target_revision,
        server_authored,
    });
}

fun validate(command: &InfrastructureCommand) {
    assert!(command.version == COMMAND_VERSION && command.kind <= KIND_MAX, ECommandInvalid);
    if (command.kind == KIND_ASSEMBLY_STATE) {
        assert!(
            command.target_id == command.source_assembly_id && command.desired_state <= 1 &&
                empty_resources(command),
            ECommandInvalid,
        );
    } else if (
        command.kind == KIND_ENERGY_CONNECT || command.kind == KIND_ENERGY_DISCONNECT ||
            command.kind == KIND_GATE_LINK || command.kind == KIND_GATE_UNLINK
    ) {
        assert!(
            command.target_id != command.source_assembly_id && command.desired_state == 0 &&
                empty_resources(command),
            ECommandInvalid,
        );
    } else if (command.kind == KIND_REFUEL) {
        assert!(
            command.target_id != command.source_assembly_id && command.desired_state == 0 &&
                command.resource_type_id > 0 && command.resource_quantity > 0 &&
                command.requirements_commitment.is_empty(),
            ECommandInvalid,
        );
    } else {
        assert!(
            command.target_id != command.source_assembly_id && command.desired_state == 0 &&
                command.resource_type_id > 0 && command.resource_quantity > 0 &&
                command.requirements_commitment.length() == COMMITMENT_LENGTH,
            ECommandInvalid,
        );
    };
}

fun empty_resources(command: &InfrastructureCommand): bool {
    command.resource_type_id == 0 && command.resource_quantity == 0 &&
        command.requirements_commitment.is_empty()
}

fun action_type(kind: u8): vector<u8> {
    if (kind == KIND_ASSEMBLY_STATE) b"infrastructure.assembly-state"
    else if (kind == KIND_ENERGY_CONNECT) b"infrastructure.energy-connect"
    else if (kind == KIND_ENERGY_DISCONNECT) b"infrastructure.energy-disconnect"
    else if (kind == KIND_GATE_LINK) b"infrastructure.gate-link"
    else if (kind == KIND_GATE_UNLINK) b"infrastructure.gate-unlink"
    else if (kind == KIND_REFUEL) b"infrastructure.refuel"
    else if (kind == KIND_REACTIVATE) b"infrastructure.reactivate"
    else abort ECommandInvalid
}

public fun kind(command: &InfrastructureCommand): u8 { command.kind }
public fun source_assembly_id(command: &InfrastructureCommand): ID { command.source_assembly_id }
public fun target_id(command: &InfrastructureCommand): ID { command.target_id }
public fun expected_source_revision(command: &InfrastructureCommand): u64 { command.expected_source_revision }
public fun expected_target_revision(command: &InfrastructureCommand): u64 { command.expected_target_revision }
public fun desired_state(command: &InfrastructureCommand): u8 { command.desired_state }
public fun resource_type_id(command: &InfrastructureCommand): u64 { command.resource_type_id }
public fun resource_quantity(command: &InfrastructureCommand): u64 { command.resource_quantity }
public fun requirements_commitment(command: &InfrastructureCommand): &vector<u8> {
    &command.requirements_commitment
}
public fun assembly_state_kind(): u8 { KIND_ASSEMBLY_STATE }
public fun energy_connect_kind(): u8 { KIND_ENERGY_CONNECT }
public fun energy_disconnect_kind(): u8 { KIND_ENERGY_DISCONNECT }
public fun gate_link_kind(): u8 { KIND_GATE_LINK }
public fun gate_unlink_kind(): u8 { KIND_GATE_UNLINK }
public fun refuel_kind(): u8 { KIND_REFUEL }
public fun reactivate_kind(): u8 { KIND_REACTIVATE }
