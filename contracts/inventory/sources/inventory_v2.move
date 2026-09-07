/// Catalog-bound typed storage for array-based industry and authenticated bridges.
/// Owner actions define explicit per-type ceilings; beneficiaries retain direct
/// withdrawal and export access independently of owner-configured actions.
module inventory::inventory_v2;

use core::{
    access_cap::{Self, AccessCap},
    admin_service::AdminACL,
    entity::Entity,
    mod::{Self, Module},
    request::{Request, Frame},
    requirement::{Self, Requirement}
};
use inventory::{item_type::{Self, ItemTypeRegistry}, item_v2::{Self, ItemV2, ItemAmount}};
use std::{internal::Permit, string::String};
use sui::{bcs, event, linked_table::{Self, LinkedTable}, vec_map::{Self, VecMap}};

// === Errors ===

#[error(code = 0)]
const EWrongVersion: vector<u8> = b"Storage inventory schema is unsupported";
#[error(code = 1)]
const EWrongRegistry: vector<u8> = b"Storage is pinned to a different item catalog";
#[error(code = 2)]
const EWrongTenant: vector<u8> = b"Entity and item catalog tenants differ";
#[error(code = 3)]
const EOverCapacity: vector<u8> = b"Aggregate operation exceeds inventory capacity";
#[error(code = 4)]
const ENotAuthorized: vector<u8> = b"Personal inventory operations require an authenticated caller";
#[error(code = 5)]
const ETypeNotAllowed: vector<u8> = b"Batch contains a type outside the action policy";
#[error(code = 6)]
const EAmountAboveLimit: vector<u8> = b"Batch quantity exceeds the per-type action limit";
#[error(code = 7)]
const EInsufficientBalance: vector<u8> = b"Inventory cannot fund the entire requested array";
#[error(code = 8)]
const ENonEmptyStorage: vector<u8> = b"Storage cannot be removed while holding beneficiary assets";
#[error(code = 9)]
const EInvalidRequirement: vector<u8> = b"Batch requirement BCS contains trailing data";
#[error(code = 10)]
const EAmountMismatch: vector<u8> =
    b"Supplied assets differ from the declared exact deposit amounts";

// === Constants ===

const VERSION: u64 = 1;

// === Structs ===

/// One beneficiary's balances and canonical volume allocation.
public struct InventoryV2 has store {
    version: u64,
    capacity: u64,
    used: u64,
    balances: VecMap<u64, u64>,
}

/// Installed storage state pinned to a tenant's authenticated item catalog.
public struct StorageInventoryV2 has store {
    version: u64,
    registry_id: ID,
    type_id: u64,
    ephemeral_capacity: u64,
    inventories: LinkedTable<ID, InventoryV2>,
}

/// Each line allows only its type and caps its total quantity for this operation.
public struct BatchRule has copy, drop, store {
    ephemeral: bool,
    limits: vector<ItemAmount>,
}

public struct BatchWithdrawal(BatchRule) has drop;
public struct BatchDeposit(BatchRule) has drop;
public struct ProtectedOperation() has drop;

// === Events ===

/// Supply-preserving storage ingress.
public struct ItemsDeposited has copy, drop {
    entity_id: ID,
    module_id: u64,
    registry_id: ID,
    beneficiary: ID,
    amounts: vector<ItemAmount>,
}

/// Supply-preserving storage egress.
public struct ItemsWithdrawn has copy, drop {
    entity_id: ID,
    module_id: u64,
    registry_id: ID,
    beneficiary: ID,
    amounts: vector<ItemAmount>,
}

/// A replay-protected game import binds its complete destination and amounts.
public struct GameItemsImported has copy, drop {
    transfer_id: vector<u8>,
    registry_id: ID,
    tenant: String,
    entity_id: ID,
    module_id: u64,
    beneficiary: ID,
    amounts: vector<ItemAmount>,
}

/// A beneficiary-authorized game export carries a globally unique object ID.
public struct GameItemsExported has copy, drop {
    export_id: ID,
    registry_id: ID,
    tenant: String,
    entity_id: ID,
    module_id: u64,
    beneficiary: ID,
    amounts: vector<ItemAmount>,
}

// === Public Functions ===

/// Install catalog-bound storage after verifying the catalog's pinned admin ACL.
public fun install(
    entity: &mut Entity,
    registry: &ItemTypeRegistry,
    acl: &AdminACL,
    module_id: u64,
    type_id: u64,
    name: Option<String>,
    main_capacity: u64,
    ephemeral_capacity: u64,
    ctx: &mut TxContext,
): Request {
    item_type::assert_admin(registry, acl, ctx);
    assert!(entity.key().tenant() == item_type::tenant(registry), EWrongTenant);
    let mut inventories = linked_table::new(ctx);
    inventories.push_back(entity.id(), new_inventory(main_capacity));
    entity.install(
        module_id,
        name,
        StorageInventoryV2 {
            version: VERSION,
            registry_id: object::id(registry),
            type_id,
            ephemeral_capacity,
            inventories,
        },
        VERSION,
        permit(),
        ctx,
    )
}

/// Remove only completely empty storage; beneficiary assets can never be burned.
public fun uninstall(
    entity: &mut Entity,
    registry: &ItemTypeRegistry,
    acl: &AdminACL,
    module_id: u64,
    ctx: &mut TxContext,
): Request {
    item_type::assert_admin(registry, acl, ctx);
    assert_registry(storage(entity, module_id), registry);
    let (inv_module, req) = entity.uninstall<StorageInventoryV2>(module_id, permit(), ctx);
    let StorageInventoryV2 {
        version: _,
        registry_id: _,
        type_id: _,
        ephemeral_capacity: _,
        mut inventories,
    } = inv_module.unwrap(permit());
    while (!inventories.is_empty()) {
        let (_, InventoryV2 { version: _, capacity: _, used, balances }) = inventories.pop_front();
        assert!(used == 0 && balances.is_empty(), ENonEmptyStorage);
    };
    inventories.destroy_empty();
    req
}

/// Withdraw an entire exact array after enforcing every per-type policy limit.
public fun withdraw_many(
    entity: &mut Entity,
    registry: &ItemTypeRegistry,
    req: &mut Request,
    amounts: vector<ItemAmount>,
    ctx: &mut TxContext,
): vector<ItemV2> {
    let entity_id = entity.id();
    let module_id = req.next().module_id().destroy_or!(abort EInvalidRequirement);
    let caller = req.authorized_id();
    let (requirement, frame, storage) = take(entity, req, internal::permit<BatchWithdrawal>());
    assert_registry(storage, registry);
    let ephemeral = enforce_rule(&requirement, &amounts);
    let beneficiary = route_key(caller, entity_id, ephemeral);
    let result = withdraw_from(storage, registry, beneficiary, &amounts, ctx);
    event::emit(ItemsWithdrawn {
        entity_id,
        module_id,
        registry_id: object::id(registry),
        beneficiary,
        amounts,
    });
    req.enqueue(frame);
    result
}

/// Deposit actual assets only if their aggregate exactly matches the supplied array.
public fun deposit_many(
    entity: &mut Entity,
    registry: &ItemTypeRegistry,
    req: &mut Request,
    items: vector<ItemV2>,
    amounts: vector<ItemAmount>,
    ctx: &mut TxContext,
) {
    let actual = item_v2::aggregate(registry, &items);
    assert!(item_v2::matches(&actual, &amounts), EAmountMismatch);
    let entity_id = entity.id();
    let module_id = req.next().module_id().destroy_or!(abort EInvalidRequirement);
    let caller = req.authorized_id();
    let (requirement, frame, storage) = take(entity, req, internal::permit<BatchDeposit>());
    assert_registry(storage, registry);
    let ephemeral = enforce_rule(&requirement, &amounts);
    let beneficiary = route_key(caller, entity_id, ephemeral);
    deposit_into(storage, registry, beneficiary, &amounts, ctx);
    items.do!(|item| { let _ = item_v2::into_storage(registry, item); });
    event::emit(ItemsDeposited {
        entity_id,
        module_id,
        registry_id: object::id(registry),
        beneficiary,
        amounts,
    });
    req.enqueue(frame);
}

/// Build an explicitly bounded per-type withdrawal policy.
public fun batch_withdrawal_requirement(
    module_id: u64,
    ephemeral: bool,
    limits: vector<ItemAmount>,
): Requirement {
    item_v2::validate_amounts(&limits);
    requirement::from_config(
        option::some(module_id),
        BatchWithdrawal(BatchRule { ephemeral, limits }),
    )
}

/// Build an explicitly bounded per-type deposit policy.
public fun batch_deposit_requirement(
    module_id: u64,
    ephemeral: bool,
    limits: vector<ItemAmount>,
): Requirement {
    item_v2::validate_amounts(&limits);
    requirement::from_config(option::some(module_id), BatchDeposit(BatchRule { ephemeral, limits }))
}

/// Recover the capability holder's own assets even if normal actions are disabled.
public fun withdraw_owned(
    entity: &mut Entity,
    registry: &ItemTypeRegistry,
    cap: &AccessCap,
    module_id: u64,
    amounts: vector<ItemAmount>,
    ctx: &mut TxContext,
): vector<ItemV2> {
    access_cap::assert_valid(cap);
    let entity_id = entity.id();
    let beneficiary = cap.entity();
    let mut req = begin_protected(entity, module_id);
    let (_, frame, storage) = take(entity, &mut req, internal::permit<ProtectedOperation>());
    assert_registry(storage, registry);
    let result = withdraw_from(storage, registry, beneficiary, &amounts, ctx);
    event::emit(ItemsWithdrawn {
        entity_id,
        module_id,
        registry_id: object::id(registry),
        beneficiary,
        amounts,
    });
    frame.destroy_empty_frame();
    entity.complete_request(req);
    result
}

/// Export the capability holder's own array with a unique game reconciliation ID.
public fun export_items(
    entity: &mut Entity,
    registry: &ItemTypeRegistry,
    cap: &AccessCap,
    module_id: u64,
    amounts: vector<ItemAmount>,
    ctx: &mut TxContext,
): ID {
    access_cap::assert_valid(cap);
    let entity_id = entity.id();
    let beneficiary = cap.entity();
    let mut req = begin_protected(entity, module_id);
    let (_, frame, storage) = take(entity, &mut req, internal::permit<ProtectedOperation>());
    assert_registry(storage, registry);
    subtract(storage, registry, beneficiary, &amounts);
    let export_uid = object::new(ctx);
    let export_id = export_uid.to_inner();
    export_uid.delete();
    event::emit(GameItemsExported {
        export_id,
        registry_id: object::id(registry),
        tenant: item_type::tenant(registry),
        entity_id,
        module_id,
        beneficiary,
        amounts,
    });
    frame.destroy_empty_frame();
    entity.complete_request(req);
    export_id
}

// === View Functions ===

/// Read catalog-bound storage after validating both schema layers.
public fun storage(entity: &Entity, module_id: u64): &StorageInventoryV2 {
    let inv_module: &Module<StorageInventoryV2> = entity.module_ref(module_id, permit());
    assert!(mod::version(inv_module) == VERSION, EWrongVersion);
    let storage = inv_module.inner();
    assert!(storage.version == VERSION, EWrongVersion);
    storage
}

public fun version(storage: &StorageInventoryV2): u64 { storage.version }

public fun registry_id(storage: &StorageInventoryV2): ID { storage.registry_id }

public fun type_id(storage: &StorageInventoryV2): u64 { storage.type_id }

public fun ephemeral_capacity(storage: &StorageInventoryV2): u64 { storage.ephemeral_capacity }

public fun inventories(storage: &StorageInventoryV2): &LinkedTable<ID, InventoryV2> {
    &storage.inventories
}

public fun inventory_version(inventory: &InventoryV2): u64 { inventory.version }

public fun capacity(inventory: &InventoryV2): u64 { inventory.capacity }

public fun used(inventory: &InventoryV2): u64 { inventory.used }

public fun balances(inventory: &InventoryV2): &VecMap<u64, u64> { &inventory.balances }

public fun ephemeral(rule: &BatchRule): bool { rule.ephemeral }

public fun limits(rule: &BatchRule): &vector<ItemAmount> { &rule.limits }

/// Read a beneficiary's existing inventory.
public fun inventory(storage: &StorageInventoryV2, beneficiary: ID): &InventoryV2 {
    assert!(storage.version == VERSION, EWrongVersion);
    assert!(storage.inventories.contains(beneficiary), EInsufficientBalance);
    let inv = &storage.inventories[beneficiary];
    assert!(inv.version == VERSION, EWrongVersion);
    inv
}

/// Read zero for absent inventories or types.
public fun balance_of(entity: &Entity, module_id: u64, beneficiary: ID, type_id: u64): u64 {
    let storage = storage(entity, module_id);
    if (!storage.inventories.contains(beneficiary)) return 0;
    let inventory = inventory(storage, beneficiary);
    if (inventory.balances.contains(&type_id)) inventory.balances[&type_id] else 0
}

public fun imported_transfer_id(event: &GameItemsImported): vector<u8> { event.transfer_id }

public fun imported_registry_id(event: &GameItemsImported): ID { event.registry_id }

public fun imported_tenant(event: &GameItemsImported): String { event.tenant }

public fun imported_entity_id(event: &GameItemsImported): ID { event.entity_id }

public fun imported_module_id(event: &GameItemsImported): u64 { event.module_id }

public fun imported_beneficiary(event: &GameItemsImported): ID { event.beneficiary }

public fun imported_amounts(event: &GameItemsImported): &vector<ItemAmount> { &event.amounts }

public fun exported_export_id(event: &GameItemsExported): ID { event.export_id }

public fun exported_registry_id(event: &GameItemsExported): ID { event.registry_id }

public fun exported_tenant(event: &GameItemsExported): String { event.tenant }

public fun exported_entity_id(event: &GameItemsExported): ID { event.entity_id }

public fun exported_module_id(event: &GameItemsExported): u64 { event.module_id }

public fun exported_beneficiary(event: &GameItemsExported): ID { event.beneficiary }

public fun exported_amounts(event: &GameItemsExported): &vector<ItemAmount> { &event.amounts }

public fun deposited_entity_id(event: &ItemsDeposited): ID { event.entity_id }

public fun deposited_module_id(event: &ItemsDeposited): u64 { event.module_id }

public fun deposited_registry_id(event: &ItemsDeposited): ID { event.registry_id }

public fun deposited_beneficiary(event: &ItemsDeposited): ID { event.beneficiary }

public fun deposited_amounts(event: &ItemsDeposited): &vector<ItemAmount> { &event.amounts }

public fun withdrawn_entity_id(event: &ItemsWithdrawn): ID { event.entity_id }

public fun withdrawn_module_id(event: &ItemsWithdrawn): u64 { event.module_id }

public fun withdrawn_registry_id(event: &ItemsWithdrawn): ID { event.registry_id }

public fun withdrawn_beneficiary(event: &ItemsWithdrawn): ID { event.beneficiary }

public fun withdrawn_amounts(event: &ItemsWithdrawn): &vector<ItemAmount> { &event.amounts }

// === Admin Functions ===

/// Import an authenticated transfer exactly once, binding every output destination.
public fun import_items(
    entity: &mut Entity,
    registry: &mut ItemTypeRegistry,
    acl: &AdminACL,
    module_id: u64,
    beneficiary: ID,
    transfer_id: vector<u8>,
    amounts: vector<ItemAmount>,
    ctx: &mut TxContext,
) {
    item_type::consume_import(registry, acl, transfer_id, ctx);
    let entity_id = entity.id();
    let mut req = begin_protected(entity, module_id);
    let (_, frame, storage) = take(entity, &mut req, internal::permit<ProtectedOperation>());
    assert_registry(storage, registry);
    deposit_into(storage, registry, beneficiary, &amounts, ctx);
    event::emit(GameItemsImported {
        transfer_id,
        registry_id: object::id(registry),
        tenant: item_type::tenant(registry),
        entity_id,
        module_id,
        beneficiary,
        amounts,
    });
    frame.destroy_empty_frame();
    entity.complete_request(req);
}

// === Private Functions ===

fun new_inventory(capacity: u64): InventoryV2 {
    InventoryV2 { version: VERSION, capacity, used: 0, balances: vec_map::empty() }
}

fun assert_registry(storage: &StorageInventoryV2, registry: &ItemTypeRegistry) {
    assert!(storage.version == VERSION, EWrongVersion);
    item_type::assert_valid(registry);
    assert!(storage.registry_id == object::id(registry), EWrongRegistry);
}

fun take<T: drop>(
    entity: &mut Entity,
    req: &mut Request,
    witness: Permit<T>,
): (Requirement, Frame, &mut StorageInventoryV2) {
    let inv_module: &mut Module<StorageInventoryV2> = entity.module_mut(req, permit());
    assert!(mod::version(inv_module) == VERSION, EWrongVersion);
    let storage = inv_module.inner_mut();
    assert!(storage.version == VERSION, EWrongVersion);
    let (requirement, frame) = req.take_next(witness);
    (requirement, frame, storage)
}

fun begin_protected(entity: &mut Entity, module_id: u64): Request {
    entity.begin_module_request(
        module_id,
        requirement::from_config(option::some(module_id), ProtectedOperation()),
        permit(),
    )
}

fun enforce_rule(requirement: &Requirement, amounts: &vector<ItemAmount>): bool {
    item_v2::validate_amounts(amounts);
    let mut parser = bcs::new(requirement.data());
    let ephemeral = parser.peel_bool();
    let length = parser.peel_vec_length();
    assert!(length > 0 && length <= item_v2::max_lines(), EInvalidRequirement);
    let limits = vector::tabulate!(
        length,
        |_| item_v2::amount(parser.peel_u64(), parser.peel_u64()),
    );
    assert!(parser.into_remainder_bytes().is_empty(), EInvalidRequirement);
    item_v2::validate_amounts(&limits);
    amounts.do_ref!(|amount| {
        let mut index = 0;
        while (
            index < limits.length() && item_v2::amount_type_id(&limits[index]) != item_v2::amount_type_id(amount)
        ) index = index + 1;
        assert!(index < limits.length(), ETypeNotAllowed);
        assert!(
            item_v2::amount_quantity(amount) <= item_v2::amount_quantity(&limits[index]),
            EAmountAboveLimit,
        );
    });
    ephemeral
}

fun route_key(caller: Option<ID>, entity_id: ID, ephemeral: bool): ID {
    if (ephemeral) caller.destroy_or!(abort ENotAuthorized) else entity_id
}

fun deposit_into(
    storage: &mut StorageInventoryV2,
    registry: &ItemTypeRegistry,
    beneficiary: ID,
    amounts: &vector<ItemAmount>,
    _ctx: &mut TxContext,
) {
    let added = item_v2::total_volume(registry, amounts);
    if (!storage.inventories.contains(beneficiary))
        storage.inventories.push_back(beneficiary, new_inventory(storage.ephemeral_capacity));
    let inv = &mut storage.inventories[beneficiary];
    assert!(inv.version == VERSION, EWrongVersion);
    let used = item_v2::checked_add(inv.used, added);
    assert!(used <= inv.capacity, EOverCapacity);
    inv.used = used;
    amounts.do_ref!(|line| {
        let type_id = item_v2::amount_type_id(line);
        let quantity = item_v2::amount_quantity(line);
        if (inv.balances.contains(&type_id)) {
            let balance = &mut inv.balances[&type_id];
            *balance = item_v2::checked_add(*balance, quantity);
        } else inv.balances.insert(type_id, quantity);
    });
}

fun subtract(
    storage: &mut StorageInventoryV2,
    registry: &ItemTypeRegistry,
    beneficiary: ID,
    amounts: &vector<ItemAmount>,
) {
    let removed = item_v2::total_volume(registry, amounts);
    assert!(storage.inventories.contains(beneficiary), EInsufficientBalance);
    let inv = &mut storage.inventories[beneficiary];
    assert!(inv.version == VERSION, EWrongVersion);
    amounts.do_ref!(|line| {
        let type_id = item_v2::amount_type_id(line);
        let quantity = item_v2::amount_quantity(line);
        assert!(inv.balances.contains(&type_id), EInsufficientBalance);
        assert!(inv.balances[&type_id] >= quantity, EInsufficientBalance);
        let balance = &mut inv.balances[&type_id];
        *balance = *balance - quantity;
        if (inv.balances[&type_id] == 0) { let (_, _) = inv.balances.remove(&type_id); };
    });
    inv.used = inv.used - removed;
}

fun withdraw_from(
    storage: &mut StorageInventoryV2,
    registry: &ItemTypeRegistry,
    beneficiary: ID,
    amounts: &vector<ItemAmount>,
    ctx: &mut TxContext,
): vector<ItemV2> {
    subtract(storage, registry, beneficiary, amounts);
    amounts.map_ref!(
        |line| item_v2::from_storage(
            registry,
            item_v2::amount_type_id(line),
            item_v2::amount_quantity(line),
            ctx,
        ),
    )
}

fun permit(): Permit<StorageInventoryV2> { internal::permit<StorageInventoryV2>() }
