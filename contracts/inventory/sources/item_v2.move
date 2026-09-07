/// Tenant-bound, catalog-authenticated fungible items used by industry.
/// Legacy Item objects have no conversion path into this supply domain.
module inventory::item_v2;

use inventory::item_type::{Self, ItemTypeRegistry};
use std::string::String;
use sui::event;

// === Errors ===

#[error(code = 0)]
const EWrongVersion: vector<u8> = b"Item schema version is unsupported";
#[error(code = 1)]
const EWrongRegistry: vector<u8> = b"Item belongs to a different canonical catalog";
#[error(code = 2)]
const EWrongTenant: vector<u8> = b"Item belongs to a different tenant";
#[error(code = 3)]
const EWrongVolume: vector<u8> = b"Item volume differs from its canonical definition";
#[error(code = 4)]
const EInvalidAmount: vector<u8> = b"Type ID and quantity must be positive";
#[error(code = 5)]
const ETooManyLines: vector<u8> = b"Amount arrays must contain 1 to 32 unique types";
#[error(code = 6)]
const ETooManyItems: vector<u8> = b"Actual item arrays must contain 1 to 64 stacks";
#[error(code = 7)]
const EDuplicateType: vector<u8> = b"Amount arrays must not contain duplicate type IDs";
#[error(code = 8)]
const EOverflow: vector<u8> = b"Item quantity or volume exceeds u64 range";
#[error(code = 9)]
const EInsufficientQuantity: vector<u8> = b"Split requires a positive remainder";
#[error(code = 10)]
const EWrongType: vector<u8> = b"Only identical canonical item types may merge";

// === Constants ===

const VERSION: u64 = 1;
const MAX_LINES: u64 = 32;
const MAX_ITEMS: u64 = 64;
const MAX_U64: u128 = 18446744073709551615;

// === Structs ===

/// Owned or escrowed fungible asset; every construction binds canonical metadata.
public struct ItemV2 has key, store {
    id: UID,
    version: u64,
    registry_id: ID,
    tenant: String,
    type_id: u64,
    quantity: u64,
    volume: u64,
}

/// An exact per-type amount; the containing catalog or job supplies provenance.
public struct ItemAmount has copy, drop, store {
    type_id: u64,
    quantity: u64,
}

// === Events ===

/// Industry supply creation, distinct from game bridge events.
public struct ProductionMinted has copy, drop {
    job_id: ID,
    registry_id: ID,
    tenant: String,
    type_id: u64,
    quantity: u64,
}

/// Industry supply consumption, distinct from game bridge events.
public struct ProductionBurned has copy, drop {
    job_id: ID,
    registry_id: ID,
    tenant: String,
    type_id: u64,
    quantity: u64,
}

// === Public Functions ===

/// Construct a positive exact item amount.
public fun amount(type_id: u64, quantity: u64): ItemAmount {
    assert!(type_id > 0 && quantity > 0, EInvalidAmount);
    ItemAmount { type_id, quantity }
}

/// Split off a positive quantity while retaining a positive original stack.
public fun split(item: &mut ItemV2, quantity: u64, ctx: &mut TxContext): ItemV2 {
    assert_item_version(item);
    assert!(quantity > 0, EInvalidAmount);
    assert!(quantity < item.quantity, EInsufficientQuantity);
    item.quantity = item.quantity - quantity;
    ItemV2 {
        id: object::new(ctx),
        version: VERSION,
        registry_id: item.registry_id,
        tenant: item.tenant,
        type_id: item.type_id,
        quantity,
        volume: item.volume,
    }
}

/// Merge two stacks from the same tenant, catalog and canonical type.
public fun merge(item: &mut ItemV2, other: ItemV2) {
    assert_item_version(item);
    assert_item_version(&other);
    assert!(item.registry_id == other.registry_id, EWrongRegistry);
    assert!(item.tenant == other.tenant, EWrongTenant);
    assert!(item.type_id == other.type_id, EWrongType);
    assert!(item.volume == other.volume, EWrongVolume);
    item.quantity = checked_add(item.quantity, other.quantity);
    let ItemV2 { id, version: _, registry_id: _, tenant: _, type_id: _, quantity: _, volume: _ } =
        other;
    id.delete();
}

/// Concatenate separately withdrawn asset vectors without changing supply.
public fun concat(mut first: vector<ItemV2>, second: vector<ItemV2>): vector<ItemV2> {
    assert!(first.length() + second.length() <= MAX_ITEMS, ETooManyItems);
    first.append(second);
    first
}

/// Transfer every result or refund in an atomic PTB command.
public fun transfer_all(items: vector<ItemV2>, recipient: address) {
    assert!(items.length() > 0 && items.length() <= MAX_ITEMS, ETooManyItems);
    items.do!(|item| {
        assert_item_version(&item);
        transfer::public_transfer(item, recipient);
    });
}

/// Validate positive unique per-type commitments before economic calculations.
public fun validate_amounts(amounts: &vector<ItemAmount>) {
    assert!(amounts.length() > 0 && amounts.length() <= MAX_LINES, ETooManyLines);
    let mut i = 0;
    while (i < amounts.length()) {
        let line = &amounts[i];
        assert!(line.type_id > 0 && line.quantity > 0, EInvalidAmount);
        let mut j = 0;
        while (j < i) {
            assert!(amounts[j].type_id != line.type_id, EDuplicateType);
            j = j + 1;
        };
        i = i + 1;
    };
}

/// Check each actual asset and aggregate fragmented stacks by canonical type.
public fun aggregate(registry: &ItemTypeRegistry, items: &vector<ItemV2>): vector<ItemAmount> {
    assert!(items.length() > 0 && items.length() <= MAX_ITEMS, ETooManyItems);
    let mut amounts: vector<ItemAmount> = vector[];
    items.do_ref!(|item| {
        assert_canonical(registry, item);
        let mut i = 0;
        while (i < amounts.length() && amounts[i].type_id != item.type_id) i = i + 1;
        if (i == amounts.length()) {
            assert!(amounts.length() < MAX_LINES, ETooManyLines);
            amounts.push_back(amount(item.type_id, item.quantity));
        } else {
            amounts[i].quantity = checked_add(amounts[i].quantity, item.quantity);
        };
    });
    amounts
}

/// Require a supported item with exact catalog, tenant, volume and positive quantity.
public fun assert_canonical(registry: &ItemTypeRegistry, item: &ItemV2) {
    assert_item_version(item);
    assert!(item.registry_id == object::id(registry), EWrongRegistry);
    assert!(item.tenant == item_type::tenant(registry), EWrongTenant);
    assert!(item.volume == item_type::volume(registry, item.type_id), EWrongVolume);
    assert!(item.type_id > 0 && item.quantity > 0, EInvalidAmount);
}

// === View Functions ===

public fun version(item: &ItemV2): u64 { item.version }

public fun registry_id(item: &ItemV2): ID { item.registry_id }

public fun tenant(item: &ItemV2): String { item.tenant }

public fun type_id(item: &ItemV2): u64 { item.type_id }

public fun quantity(item: &ItemV2): u64 { item.quantity }

public fun volume(item: &ItemV2): u64 { item.volume }

public fun amount_type_id(amount: &ItemAmount): u64 { amount.type_id }

public fun amount_quantity(amount: &ItemAmount): u64 { amount.quantity }

public fun max_lines(): u64 { MAX_LINES }

public fun max_items(): u64 { MAX_ITEMS }

public fun minted_job_id(event: &ProductionMinted): ID { event.job_id }

public fun minted_registry_id(event: &ProductionMinted): ID { event.registry_id }

public fun minted_tenant(event: &ProductionMinted): String { event.tenant }

public fun minted_type_id(event: &ProductionMinted): u64 { event.type_id }

public fun minted_quantity(event: &ProductionMinted): u64 { event.quantity }

public fun burned_job_id(event: &ProductionBurned): ID { event.job_id }

public fun burned_registry_id(event: &ProductionBurned): ID { event.registry_id }

public fun burned_tenant(event: &ProductionBurned): String { event.tenant }

public fun burned_type_id(event: &ProductionBurned): u64 { event.type_id }

public fun burned_quantity(event: &ProductionBurned): u64 { event.quantity }

/// Compare entire unique amount sets independently of line order.
public fun matches(actual: &vector<ItemAmount>, expected: &vector<ItemAmount>): bool {
    validate_amounts(actual);
    validate_amounts(expected);
    actual.length() == expected.length() && actual.all!(|line| expected.contains(line))
}

/// Calculate canonical aggregate volume using checked wide intermediates.
public fun total_volume(registry: &ItemTypeRegistry, amounts: &vector<ItemAmount>): u64 {
    validate_amounts(amounts);
    let mut total = 0;
    amounts.do_ref!(|line| {
        let added = (item_type::volume(registry, line.type_id) as u128) * (line.quantity as u128);
        assert!(added <= MAX_U64, EOverflow);
        total = checked_add(total, added as u64);
    });
    total
}

/// Add two quantities without truncating an out-of-range result.
public fun checked_add(left: u64, right: u64): u64 {
    let result = (left as u128) + (right as u128);
    assert!(result <= MAX_U64, EOverflow);
    result as u64
}

// === Package Functions ===

/// Create committed industry output only from its approved canonical definition.
public(package) fun mint_production(
    registry: &ItemTypeRegistry,
    type_id: u64,
    quantity: u64,
    job_id: ID,
    ctx: &mut TxContext,
): ItemV2 {
    item_type::assert_production_enabled(registry, type_id);
    let item = from_storage(registry, type_id, quantity, ctx);
    event::emit(ProductionMinted {
        job_id,
        registry_id: item.registry_id,
        tenant: item.tenant,
        type_id,
        quantity,
    });
    item
}

/// Consume escrowed production input with a job-specific supply event.
public(package) fun burn_production(item: ItemV2, job_id: ID) {
    assert_item_version(&item);
    let ItemV2 { id, version: _, registry_id, tenant, type_id, quantity, volume: _ } = item;
    event::emit(ProductionBurned { job_id, registry_id, tenant, type_id, quantity });
    id.delete();
}

/// Materialize supply removed from a typed storage balance or authenticated import.
public(package) fun from_storage(
    registry: &ItemTypeRegistry,
    type_id: u64,
    quantity: u64,
    ctx: &mut TxContext,
): ItemV2 {
    assert!(type_id > 0 && quantity > 0, EInvalidAmount);
    ItemV2 {
        id: object::new(ctx),
        version: VERSION,
        registry_id: object::id(registry),
        tenant: item_type::tenant(registry),
        type_id,
        quantity,
        volume: item_type::volume(registry, type_id),
    }
}

/// Consume a canonical object while conserving its quantity in typed storage.
public(package) fun into_storage(registry: &ItemTypeRegistry, item: ItemV2): ItemAmount {
    assert_canonical(registry, &item);
    let ItemV2 { id, version: _, registry_id: _, tenant: _, type_id, quantity, volume: _ } = item;
    id.delete();
    amount(type_id, quantity)
}

// === Private Functions ===

fun assert_item_version(item: &ItemV2) {
    assert!(item.version == VERSION, EWrongVersion);
}
