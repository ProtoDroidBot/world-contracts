/// One-way Smart Catapult routes for the Slingshot assembly family.
///
/// A Catapult is a deterministic sidecar for an existing Gate object. The game
/// server selects one destination solar system and attests its source-system
/// distance. No destination Gate object is required. Route changes require the
/// source Gate to be offline; jumps require it to be online.
module world_catapult::catapult;

use sui::{clock::{Self, Clock}, derived_object, event};
use world::{
    access::AdminACL,
    character::{Self, Character},
    gate::{Self, Gate, GateConfig},
    in_game_id::TenantItemId,
};

#[error(code = 0)]
const ENotCatapultType: vector<u8> = b"Gate type is not a Smart Catapult";
#[error(code = 1)]
const EGateLinked: vector<u8> = b"Smart Catapult cannot have a paired gate link";
#[error(code = 2)]
const EGateOnline: vector<u8> = b"Smart Catapult must be offline to change destination";
#[error(code = 3)]
const EGateOffline: vector<u8> = b"Smart Catapult must be online to jump";
#[error(code = 4)]
const EInvalidSolarSystem: vector<u8> = b"Source and destination solar systems must be distinct and nonzero";
#[error(code = 5)]
const EOutOfRange: vector<u8> = b"Destination exceeds the Smart Catapult range";
#[error(code = 6)]
const ECatapultMismatch: vector<u8> = b"Catapult record belongs to another gate";
#[error(code = 7)]
const EStaleRevision: vector<u8> = b"Catapult route revision changed; read and retry";
#[error(code = 8)]
const ENoDestination: vector<u8> = b"Smart Catapult has no destination";

// Client build 3502403 Slingshot and Heavy Slingshot assembly type IDs.
const CATAPULT_TYPE_ID: u64 = 95_627;
const HEAVY_CATAPULT_TYPE_ID: u64 = 95_677;

/// Distinct derived-object namespace; BCS layout is the source Gate ID.
public struct CatapultKey has copy, drop, store {
    gate_id: ID,
}

public struct Catapult has key {
    id: UID,
    gate_id: ID,
    gate_key: TenantItemId,
    type_id: u64,
    source_solar_system_id: u64,
    destination_solar_system_id: Option<u64>,
    distance: u64,
    revision: u64,
    updated_at_ms: u64,
}

/// Package-owned root for deterministic Catapult sidecars.
public struct CatapultRegistry has key {
    id: UID,
}

public struct CatapultCreatedEvent has copy, drop {
    catapult_id: ID,
    gate_id: ID,
    gate_key: TenantItemId,
    type_id: u64,
    source_solar_system_id: u64,
    destination_solar_system_id: Option<u64>,
    distance: u64,
    revision: u64,
}

public struct CatapultDestinationChangedEvent has copy, drop {
    catapult_id: ID,
    gate_id: ID,
    source_solar_system_id: u64,
    destination_solar_system_id: Option<u64>,
    distance: u64,
    revision: u64,
}

public struct CatapultJumpEvent has copy, drop {
    catapult_id: ID,
    gate_id: ID,
    gate_key: TenantItemId,
    source_solar_system_id: u64,
    destination_solar_system_id: u64,
    character_id: ID,
    character_key: TenantItemId,
    revision: u64,
}

public fun new_catapult_key(gate_id: ID): CatapultKey {
    CatapultKey { gate_id }
}

/// Creates the unique route sidecar. A zero destination creates an unconfigured
/// record and requires a zero distance.
public fun create(
    registry: &mut CatapultRegistry,
    gate: &Gate,
    gate_config: &GateConfig,
    admin_acl: &AdminACL,
    source_solar_system_id: u64,
    destination_solar_system_id: u64,
    distance: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    admin_acl.verify_sponsor(ctx);
    validate_gate(gate);
    validate_route(
        gate,
        gate_config,
        source_solar_system_id,
        destination_solar_system_id,
        distance,
    );
    let gate_id = gate::id(gate);
    let gate_key = gate::key(gate);
    let type_id = gate::type_id(gate);
    let id = derived_object::claim(&mut registry.id, new_catapult_key(gate_id));
    let catapult_id = object::uid_to_inner(&id);
    let destination = destination_option(destination_solar_system_id);
    let catapult = Catapult {
        id,
        gate_id,
        gate_key,
        type_id,
        source_solar_system_id,
        destination_solar_system_id: destination,
        distance,
        revision: 1,
        updated_at_ms: clock::timestamp_ms(clock),
    };
    event::emit(CatapultCreatedEvent {
        catapult_id,
        gate_id,
        gate_key,
        type_id,
        source_solar_system_id,
        destination_solar_system_id: destination,
        distance,
        revision: 1,
    });
    transfer::share_object(catapult);
}

fun init(ctx: &mut TxContext) {
    transfer::share_object(CatapultRegistry { id: object::new(ctx) });
}

#[test_only]
public fun init_for_testing(ctx: &mut TxContext) {
    init(ctx);
}

public fun registry_id(registry: &CatapultRegistry): ID {
    object::id(registry)
}

/// Replaces or clears the route. `destination_solar_system_id == 0` clears it.
public fun sync_destination(
    catapult: &mut Catapult,
    gate: &Gate,
    gate_config: &GateConfig,
    admin_acl: &AdminACL,
    expected_revision: u64,
    source_solar_system_id: u64,
    destination_solar_system_id: u64,
    distance: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    admin_acl.verify_sponsor(ctx);
    assert!(catapult.revision == expected_revision, EStaleRevision);
    assert!(catapult.gate_id == gate::id(gate) && catapult.gate_key == gate::key(gate)
        && catapult.type_id == gate::type_id(gate), ECatapultMismatch);
    assert!(catapult.source_solar_system_id == source_solar_system_id, ECatapultMismatch);
    validate_gate(gate);
    validate_route(
        gate,
        gate_config,
        source_solar_system_id,
        destination_solar_system_id,
        distance,
    );
    catapult.destination_solar_system_id = destination_option(destination_solar_system_id);
    catapult.distance = distance;
    catapult.revision = catapult.revision + 1;
    catapult.updated_at_ms = clock::timestamp_ms(clock);
    event::emit(CatapultDestinationChangedEvent {
        catapult_id: object::id(catapult),
        gate_id: catapult.gate_id,
        source_solar_system_id,
        destination_solar_system_id: catapult.destination_solar_system_id,
        distance,
        revision: catapult.revision,
    });
}

/// Emits an auditable one-way jump authorization. The game server performs the
/// actual session transfer after validating the same route.
public fun jump(
    catapult: &Catapult,
    gate: &Gate,
    gate_config: &GateConfig,
    character: &Character,
    admin_acl: &AdminACL,
    ctx: &TxContext,
) {
    admin_acl.verify_sponsor(ctx);
    assert!(catapult.gate_id == gate::id(gate) && catapult.gate_key == gate::key(gate)
        && catapult.type_id == gate::type_id(gate), ECatapultMismatch);
    assert!(gate::is_online(gate), EGateOffline);
    assert!(option::is_none(&gate::linked_gate_id(gate)), EGateLinked);
    assert!(option::is_some(&catapult.destination_solar_system_id), ENoDestination);
    assert!(catapult.distance <= gate::max_distance(gate_config, catapult.type_id), EOutOfRange);
    event::emit(CatapultJumpEvent {
        catapult_id: object::id(catapult),
        gate_id: catapult.gate_id,
        gate_key: catapult.gate_key,
        source_solar_system_id: catapult.source_solar_system_id,
        destination_solar_system_id: *option::borrow(&catapult.destination_solar_system_id),
        character_id: object::id(character),
        character_key: character::key(character),
        revision: catapult.revision,
    });
}

public fun is_catapult_type(type_id: u64): bool {
    type_id == CATAPULT_TYPE_ID || type_id == HEAVY_CATAPULT_TYPE_ID
}

public fun id(catapult: &Catapult): ID { object::id(catapult) }
public fun gate_id(catapult: &Catapult): ID { catapult.gate_id }
public fun source_solar_system_id(catapult: &Catapult): u64 { catapult.source_solar_system_id }
public fun destination_solar_system_id(catapult: &Catapult): Option<u64> {
    catapult.destination_solar_system_id
}
public fun distance(catapult: &Catapult): u64 { catapult.distance }
public fun revision(catapult: &Catapult): u64 { catapult.revision }
public fun updated_at_ms(catapult: &Catapult): u64 { catapult.updated_at_ms }

fun validate_gate(gate: &Gate) {
    assert!(is_catapult_type(gate::type_id(gate)), ENotCatapultType);
    assert!(option::is_none(&gate::linked_gate_id(gate)), EGateLinked);
    assert!(!gate::is_online(gate), EGateOnline);
}

fun validate_route(
    gate: &Gate,
    gate_config: &GateConfig,
    source_solar_system_id: u64,
    destination_solar_system_id: u64,
    distance: u64,
) {
    assert!(source_solar_system_id > 0, EInvalidSolarSystem);
    if (destination_solar_system_id == 0) {
        assert!(distance == 0, EInvalidSolarSystem);
    } else {
        assert!(source_solar_system_id != destination_solar_system_id, EInvalidSolarSystem);
        assert!(distance <= gate::max_distance(gate_config, gate::type_id(gate)), EOutOfRange);
    }
}

fun destination_option(destination_solar_system_id: u64): Option<u64> {
    if (destination_solar_system_id == 0) option::none()
    else option::some(destination_solar_system_id)
}
