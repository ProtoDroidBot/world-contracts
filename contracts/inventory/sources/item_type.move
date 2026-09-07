/// Governed fungible item definitions for one tenant. A registry's ID is its
/// provenance boundary; immutable definitions keep escrow and capacity meaningful.
module inventory::item_type;

use core::admin_service::{Self, AdminACL};
use std::string::String;
use sui::{event, table::{Self, Table}};

// === Errors ===

#[error(code = 0)]
const EWrongVersion: vector<u8> = b"Item registry version is unsupported";
#[error(code = 1)]
const ENotAdmin: vector<u8> = b"Sender is not an admin of the pinned ACL";
#[error(code = 2)]
const EWrongACL: vector<u8> = b"Admin ACL does not match the registry";
#[error(code = 3)]
const EEmptyTenant: vector<u8> = b"Tenant must not be empty";
#[error(code = 4)]
const EInvalidType: vector<u8> = b"Type ID and canonical volume must be positive";
#[error(code = 5)]
const ETypeExists: vector<u8> = b"Registered item types are immutable";
#[error(code = 6)]
const EUnknownType: vector<u8> = b"Item type is not registered";
#[error(code = 7)]
const EProductionDisabled: vector<u8> = b"Item type is not eligible for industry";
#[error(code = 8)]
const ETransferReplayed: vector<u8> = b"Game import transfer ID has already been consumed";
#[error(code = 9)]
const EInvalidTransferID: vector<u8> = b"Game import transfer ID must contain 1 to 64 bytes";

// === Constants ===

const VERSION: u64 = 1;

// === Structs ===

/// Shared, admin-created catalog. Import replay history survives storage removal.
public struct ItemTypeRegistry has key {
    id: UID,
    version: u64,
    admin_acl_id: ID,
    tenant: String,
    types: Table<u64, ItemType>,
    imported_transfers: Table<vector<u8>, bool>,
}

/// A permanently fixed canonical volume and industry eligibility decision.
public struct ItemType has copy, drop, store {
    version: u64,
    type_id: u64,
    volume: u64,
    production_enabled: bool,
}

// === Events ===

/// Announces the catalog's tenant and governing ACL.
public struct ItemTypeRegistryCreated has copy, drop {
    registry_id: ID,
    admin_acl_id: ID,
    tenant: String,
}

/// Announces an immutable canonical item definition.
public struct ItemTypeRegistered has copy, drop {
    registry_id: ID,
    definition: ItemType,
}

// === Public Functions ===

/// Create and share a catalog governed by this ACL, returning its ID.
public fun create(acl: &AdminACL, tenant: String, ctx: &mut TxContext): ID {
    assert!(admin_service::is_admin(acl, ctx.sender()), ENotAdmin);
    assert!(tenant.length() > 0, EEmptyTenant);
    let registry = ItemTypeRegistry {
        id: object::new(ctx),
        version: VERSION,
        admin_acl_id: object::id(acl),
        tenant,
        types: table::new(ctx),
        imported_transfers: table::new(ctx),
    };
    let registry_id = object::id(&registry);
    event::emit(ItemTypeRegistryCreated { registry_id, admin_acl_id: object::id(acl), tenant });
    transfer::share_object(registry);
    registry_id
}

/// Verify the catalog schema and its pinned admin authority.
public fun assert_admin(registry: &ItemTypeRegistry, acl: &AdminACL, ctx: &TxContext) {
    assert_valid(registry);
    assert!(registry.admin_acl_id == object::id(acl), EWrongACL);
    assert!(admin_service::is_admin(acl, ctx.sender()), ENotAdmin);
}

/// Verify this registry's supported schema.
public fun assert_valid(registry: &ItemTypeRegistry) {
    assert!(registry.version == VERSION, EWrongVersion);
}

/// Verify an item definition can enter the industry engine.
public fun assert_production_enabled(registry: &ItemTypeRegistry, type_id: u64) {
    assert!(definition(registry, type_id).production_enabled, EProductionDisabled);
}

// === View Functions ===

public fun version(registry: &ItemTypeRegistry): u64 { registry.version }

public fun admin_acl_id(registry: &ItemTypeRegistry): ID { registry.admin_acl_id }

public fun tenant(registry: &ItemTypeRegistry): String { registry.tenant }

public fun types(registry: &ItemTypeRegistry): &Table<u64, ItemType> { &registry.types }

public fun imported_transfers(registry: &ItemTypeRegistry): &Table<vector<u8>, bool> {
    &registry.imported_transfers
}

public fun definition_version(definition: &ItemType): u64 { definition.version }

public fun type_id(definition: &ItemType): u64 { definition.type_id }

public fun canonical_volume(definition: &ItemType): u64 { definition.volume }

public fun production_enabled(definition: &ItemType): bool { definition.production_enabled }

public fun created_registry_id(event: &ItemTypeRegistryCreated): ID { event.registry_id }

public fun created_admin_acl_id(event: &ItemTypeRegistryCreated): ID { event.admin_acl_id }

public fun created_tenant(event: &ItemTypeRegistryCreated): String { event.tenant }

public fun registered_registry_id(event: &ItemTypeRegistered): ID { event.registry_id }

public fun registered_definition(event: &ItemTypeRegistered): ItemType { event.definition }

/// Read a registered canonical definition.
public fun definition(registry: &ItemTypeRegistry, type_id: u64): &ItemType {
    assert_valid(registry);
    assert!(registry.types.contains(type_id), EUnknownType);
    let definition = &registry.types[type_id];
    assert!(definition.version == VERSION, EWrongVersion);
    definition
}

/// Read canonical integer volume units per item.
public fun volume(registry: &ItemTypeRegistry, type_id: u64): u64 {
    definition(registry, type_id).volume
}

/// Check whether a game import transfer has already been consumed.
public fun was_imported(registry: &ItemTypeRegistry, transfer_id: vector<u8>): bool {
    assert_valid(registry);
    registry.imported_transfers.contains(transfer_id)
}

// === Admin Functions ===

/// Register a canonical type once; changing definitions requires a new catalog.
public fun register(
    registry: &mut ItemTypeRegistry,
    acl: &AdminACL,
    type_id: u64,
    volume: u64,
    production_enabled: bool,
    ctx: &mut TxContext,
) {
    assert_admin(registry, acl, ctx);
    assert!(type_id > 0 && volume > 0, EInvalidType);
    assert!(!registry.types.contains(type_id), ETypeExists);
    let definition = ItemType { version: VERSION, type_id, volume, production_enabled };
    registry.types.add(type_id, definition);
    event::emit(ItemTypeRegistered { registry_id: object::id(registry), definition });
}

// === Package Functions ===

/// Consume an authenticated import ID globally across this catalog's storages.
public(package) fun consume_import(
    registry: &mut ItemTypeRegistry,
    acl: &AdminACL,
    transfer_id: vector<u8>,
    ctx: &TxContext,
) {
    assert_admin(registry, acl, ctx);
    assert!(transfer_id.length() > 0 && transfer_id.length() <= 64, EInvalidTransferID);
    assert!(!registry.imported_transfers.contains(transfer_id), ETransferReplayed);
    registry.imported_transfers.add(transfer_id, true);
}
