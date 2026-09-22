/// Typed industry commands carried by the canonical world action queue.
///
/// These objects are authenticated intents, not an alternate production or
/// inventory authority. The game server claims each Action, revalidates the
/// mirrored revision and custody permissions, executes against game state,
/// then records a bounded outcome on the same Action object.
module world_industry_actions::industry_actions;

use std::hash;
use sui::{bcs, clock::Clock, event};
use world::access::OwnerCap;
use world_action_queue::action_queue::{Self, AssemblyActionQueue};
use world_smart_industry::smart_industry::{Self, SmartIndustry};

#[error(code = 0)]
const ECommandVersionInvalid: vector<u8> = b"Industry command version is unsupported";
#[error(code = 1)]
const ECommandKindInvalid: vector<u8> = b"Industry command kind is invalid";
#[error(code = 2)]
const EFacilityMismatch: vector<u8> = b"Industry command does not match the mirrored facility";
#[error(code = 3)]
const EStaleRevision: vector<u8> = b"Industry command expected revision is stale";
#[error(code = 4)]
const EBlueprintInvalid: vector<u8> = b"Industry command blueprint is invalid";
#[error(code = 5)]
const EProductionStateInvalid: vector<u8> = b"Industry command is invalid for production state";
#[error(code = 6)]
const ETransferInvalid: vector<u8> = b"Industry transfer direction, side, type, or quantity is invalid";
#[error(code = 7)]
const ETargetInvalid: vector<u8> = b"Industry command target assembly is invalid";

const COMMAND_VERSION: u8 = 1;
const KIND_START: u8 = 0;
const KIND_DISCONTINUE: u8 = 1;
const KIND_SELECT_BLUEPRINT: u8 = 2;
const KIND_EMPTY: u8 = 3;
const KIND_TRANSFER: u8 = 4;

const DIRECTION_DEPOSIT: u8 = 0;
const DIRECTION_WITHDRAW: u8 = 1;
const SIDE_INPUTS: u8 = 0;
const SIDE_OUTPUTS: u8 = 1;
const BLUEPRINT_HASH_LENGTH: u64 = 32;

const PRODUCTION_IDLE: u8 = 0;
const PRODUCTION_RUNNING: u8 = 1;
const PRODUCTION_DISCONTINUING: u8 = 2;
const PRODUCTION_STOPPED: u8 = 3;

public struct IndustryActionRegistry has key { id: UID }

/// Stable BCS command envelope. Unused fields are zero/empty for each kind so
/// off-chain decoders can use one schema without accepting ambiguous commands.
public struct IndustryCommand has copy, drop, store {
    version: u8,
    kind: u8,
    facility_id: ID,
    target_assembly_id: ID,
    expected_revision: u64,
    lane_id: u64,
    blueprint_id: u64,
    blueprint_hash: vector<u8>,
    requested_runs: u64,
    direction: u8,
    side: u8,
    type_id: u64,
    quantity: u64,
}

public struct IndustryActionQueued has copy, drop {
    industry_action_registry_id: ID,
    action_object_id: ID,
    action_id: vector<u8>,
    facility_id: ID,
    target_assembly_id: ID,
    kind: u8,
    expected_revision: u64,
    lane_id: u64,
}

fun init(ctx: &mut TxContext) {
    transfer::share_object(IndustryActionRegistry { id: object::new(ctx) });
}

#[test_only]
public fun init_for_testing(ctx: &mut TxContext) {
    init(ctx);
}

public fun registry_id(registry: &IndustryActionRegistry): ID {
    object::id(registry)
}

public fun start_command(
    facility_id: ID,
    expected_revision: u64,
    lane_id: u64,
    blueprint_id: u64,
    blueprint_hash: vector<u8>,
    requested_runs: u64,
): IndustryCommand {
    let command = IndustryCommand {
        version: COMMAND_VERSION,
        kind: KIND_START,
        facility_id,
        target_assembly_id: facility_id,
        expected_revision,
        lane_id,
        blueprint_id,
        blueprint_hash,
        requested_runs,
        direction: 0,
        side: 0,
        type_id: 0,
        quantity: 0,
    };
    validate_shape(&command);
    command
}

public fun discontinue_command(
    facility_id: ID,
    expected_revision: u64,
    lane_id: u64,
): IndustryCommand {
    IndustryCommand {
        version: COMMAND_VERSION,
        kind: KIND_DISCONTINUE,
        facility_id,
        target_assembly_id: facility_id,
        expected_revision,
        lane_id,
        blueprint_id: 0,
        blueprint_hash: vector[],
        requested_runs: 0,
        direction: 0,
        side: 0,
        type_id: 0,
        quantity: 0,
    }
}

public fun select_blueprint_command(
    facility_id: ID,
    expected_revision: u64,
    lane_id: u64,
    blueprint_id: u64,
    blueprint_hash: vector<u8>,
): IndustryCommand {
    let command = IndustryCommand {
        version: COMMAND_VERSION,
        kind: KIND_SELECT_BLUEPRINT,
        facility_id,
        target_assembly_id: facility_id,
        expected_revision,
        lane_id,
        blueprint_id,
        blueprint_hash,
        requested_runs: 0,
        direction: 0,
        side: 0,
        type_id: 0,
        quantity: 0,
    };
    validate_shape(&command);
    command
}

public fun empty_command(
    facility_id: ID,
    destination_assembly_id: ID,
    expected_revision: u64,
    lane_id: u64,
): IndustryCommand {
    assert!(destination_assembly_id != facility_id, ETargetInvalid);
    IndustryCommand {
        version: COMMAND_VERSION,
        kind: KIND_EMPTY,
        facility_id,
        target_assembly_id: destination_assembly_id,
        expected_revision,
        lane_id,
        blueprint_id: 0,
        blueprint_hash: vector[],
        requested_runs: 0,
        direction: DIRECTION_WITHDRAW,
        side: SIDE_OUTPUTS,
        type_id: 0,
        quantity: 0,
    }
}

public fun transfer_command(
    facility_id: ID,
    other_assembly_id: ID,
    expected_revision: u64,
    lane_id: u64,
    direction: u8,
    side: u8,
    type_id: u64,
    quantity: u64,
): IndustryCommand {
    assert!(other_assembly_id != facility_id, ETargetInvalid);
    let command = IndustryCommand {
        version: COMMAND_VERSION,
        kind: KIND_TRANSFER,
        facility_id,
        target_assembly_id: other_assembly_id,
        expected_revision,
        lane_id,
        blueprint_id: 0,
        blueprint_hash: vector[],
        requested_runs: 0,
        direction,
        side,
        type_id,
        quantity,
    };
    validate_shape(&command);
    command
}

/// Validate the typed command against the latest Smart Industry mirror and
/// queue it through the facility owner's source authorization.
public fun queue_command<T: key>(
    action_queue_root: &mut AssemblyActionQueue,
    industry_action_registry: &IndustryActionRegistry,
    industry: &SmartIndustry,
    facility_owner_cap: &OwnerCap<T>,
    action_id: vector<u8>,
    command: IndustryCommand,
    priority: u64,
    priority_flags: u64,
    expires_at_ms: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    validate_against_industry(&command, industry);
    let facility_id = command.facility_id;
    let target_assembly_id = command.target_assembly_id;
    let kind = command.kind;
    let expected_revision = command.expected_revision;
    let lane_id = command.lane_id;
    assert!(
        action_queue::queue_assembly_id(action_queue_root) == facility_id,
        EFacilityMismatch,
    );
    let payload = bcs::to_bytes(&command);
    let payload_commitment = hash::sha2_256(copy payload);
    let action_object_id = action_queue::action_object_id(action_queue_root, copy action_id);
    action_queue::queue_action<T>(
        action_queue_root,
        target_assembly_id,
        facility_owner_cap,
        copy action_id,
        action_type_for_kind(kind),
        payload,
        payload_commitment,
        priority,
        priority_flags,
        expires_at_ms,
        clock,
        ctx,
    );
    event::emit(IndustryActionQueued {
        industry_action_registry_id: object::id(industry_action_registry),
        action_object_id,
        action_id,
        facility_id,
        target_assembly_id,
        kind,
        expected_revision,
        lane_id,
    });
}

public fun validate_against_industry(command: &IndustryCommand, industry: &SmartIndustry) {
    validate_shape(command);
    assert!(command.facility_id == smart_industry::assembly_id(industry), EFacilityMismatch);
    assert!(command.expected_revision == smart_industry::revision(industry), EStaleRevision);
    let production = smart_industry::production(industry);
    let state = smart_industry::production_state(&production);
    if (command.kind == KIND_START) {
        assert!(
            state == PRODUCTION_IDLE || state == PRODUCTION_STOPPED,
            EProductionStateInvalid,
        );
        assert!(
            command.blueprint_id == smart_industry::blueprint_id(smart_industry::snapshot(industry)),
            EBlueprintInvalid,
        );
    } else if (command.kind == KIND_DISCONTINUE) {
        assert!(
            state == PRODUCTION_RUNNING || state == PRODUCTION_DISCONTINUING,
            EProductionStateInvalid,
        );
    } else if (command.kind == KIND_SELECT_BLUEPRINT) {
        assert!(
            state == PRODUCTION_IDLE || state == PRODUCTION_STOPPED,
            EProductionStateInvalid,
        );
    } else if (command.kind == KIND_EMPTY || command.kind == KIND_TRANSFER) {
        assert!(state != PRODUCTION_RUNNING, EProductionStateInvalid);
    } else {
        abort ECommandKindInvalid
    };
}

fun validate_shape(command: &IndustryCommand) {
    assert!(command.version == COMMAND_VERSION, ECommandVersionInvalid);
    assert!(command.kind <= KIND_TRANSFER, ECommandKindInvalid);
    if (command.kind == KIND_START) {
        assert!(
            command.target_assembly_id == command.facility_id && command.lane_id > 0 &&
                command.blueprint_id > 0 &&
                command.blueprint_hash.length() == BLUEPRINT_HASH_LENGTH &&
                command.requested_runs > 0,
            EBlueprintInvalid,
        );
        assert!(
            command.direction == 0 && command.side == 0 && command.type_id == 0 &&
                command.quantity == 0,
            ETransferInvalid,
        );
    } else if (command.kind == KIND_DISCONTINUE) {
        assert!(command.target_assembly_id == command.facility_id && command.lane_id > 0, ETargetInvalid);
        assert!(empty_non_transfer_fields(command), ETransferInvalid);
    } else if (command.kind == KIND_SELECT_BLUEPRINT) {
        assert!(
            command.target_assembly_id == command.facility_id && command.lane_id > 0 &&
                command.blueprint_id > 0 &&
                command.blueprint_hash.length() == BLUEPRINT_HASH_LENGTH,
            EBlueprintInvalid,
        );
        assert!(
            command.requested_runs == 0 && command.direction == 0 && command.side == 0 &&
                command.type_id == 0 && command.quantity == 0,
            ETransferInvalid,
        );
    } else if (command.kind == KIND_EMPTY) {
        assert!(command.target_assembly_id != command.facility_id && command.lane_id > 0, ETargetInvalid);
        assert!(
            command.blueprint_id == 0 && command.blueprint_hash.is_empty() &&
                command.requested_runs == 0 && command.direction == DIRECTION_WITHDRAW &&
                command.side == SIDE_OUTPUTS && command.type_id == 0 && command.quantity == 0,
            ETransferInvalid,
        );
    } else {
        assert!(command.target_assembly_id != command.facility_id && command.lane_id > 0, ETargetInvalid);
        assert!(
            command.blueprint_id == 0 && command.blueprint_hash.is_empty() &&
                command.requested_runs == 0 &&
                (command.direction == DIRECTION_DEPOSIT || command.direction == DIRECTION_WITHDRAW) &&
                (command.side == SIDE_INPUTS || command.side == SIDE_OUTPUTS) &&
                command.type_id > 0 && command.quantity > 0,
            ETransferInvalid,
        );
        assert!(
            command.direction != DIRECTION_DEPOSIT || command.side == SIDE_INPUTS,
            ETransferInvalid,
        );
    };
}

fun empty_non_transfer_fields(command: &IndustryCommand): bool {
    command.blueprint_id == 0 && command.blueprint_hash.is_empty() &&
        command.requested_runs == 0 && command.direction == 0 && command.side == 0 &&
        command.type_id == 0 && command.quantity == 0
}

fun action_type_for_kind(kind: u8): vector<u8> {
    if (kind == KIND_START) b"industry.start"
    else if (kind == KIND_DISCONTINUE) b"industry.discontinue"
    else if (kind == KIND_SELECT_BLUEPRINT) b"industry.select-blueprint"
    else if (kind == KIND_EMPTY) b"industry.empty"
    else if (kind == KIND_TRANSFER) b"industry.transfer"
    else abort ECommandKindInvalid
}

public fun version(command: &IndustryCommand): u8 { command.version }

public fun kind(command: &IndustryCommand): u8 { command.kind }

public fun facility_id(command: &IndustryCommand): ID { command.facility_id }

public fun target_assembly_id(command: &IndustryCommand): ID { command.target_assembly_id }

public fun expected_revision(command: &IndustryCommand): u64 { command.expected_revision }

public fun lane_id(command: &IndustryCommand): u64 { command.lane_id }

public fun blueprint_id(command: &IndustryCommand): u64 { command.blueprint_id }

public fun blueprint_hash(command: &IndustryCommand): &vector<u8> { &command.blueprint_hash }

public fun requested_runs(command: &IndustryCommand): u64 { command.requested_runs }

public fun direction(command: &IndustryCommand): u8 { command.direction }

public fun side(command: &IndustryCommand): u8 { command.side }

public fun type_id(command: &IndustryCommand): u64 { command.type_id }

public fun quantity(command: &IndustryCommand): u64 { command.quantity }

public fun command_version(): u8 { COMMAND_VERSION }

public fun start_kind(): u8 { KIND_START }

public fun discontinue_kind(): u8 { KIND_DISCONTINUE }

public fun select_blueprint_kind(): u8 { KIND_SELECT_BLUEPRINT }

public fun empty_kind(): u8 { KIND_EMPTY }

public fun transfer_kind(): u8 { KIND_TRANSFER }

public fun deposit_direction(): u8 { DIRECTION_DEPOSIT }

public fun withdraw_direction(): u8 { DIRECTION_WITHDRAW }

public fun inputs_side(): u8 { SIDE_INPUTS }

public fun outputs_side(): u8 { SIDE_OUTPUTS }
