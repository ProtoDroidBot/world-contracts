/// Governed, immutable industry recipes shared by refining and manufacturing.
/// A registry pins one tenant-aware item catalog; accepted revisions are frozen.
module inventory::recipe;

use core::admin_service::AdminACL;
use inventory::{item_type::{Self, ItemTypeRegistry}, item_v2::{Self, ItemAmount}};
use std::string::String;
use sui::{event, hash, table::{Self, Table}};

// === Errors ===

#[error(code = 0)]
const EWrongVersion: vector<u8> = b"Unsupported recipe schema";
#[error(code = 1)]
const EWrongRegistry: vector<u8> = b"Recipe or catalog belongs to another registry";
#[error(code = 2)]
const EInvalidKind: vector<u8> = b"Unknown industry process kind";
#[error(code = 3)]
const EInvalidLines: vector<u8> =
    b"Recipe lines must be nonempty, bounded, positive and sorted by unique type";
#[error(code = 4)]
const EInvalidFacilities: vector<u8> =
    b"Facility types must be nonempty, bounded and sorted uniquely";
#[error(code = 5)]
const EInvalidBatches: vector<u8> = b"Batch count exceeds the recipe bounds";
#[error(code = 6)]
const EOverflow: vector<u8> = b"Recipe arithmetic exceeds u64";
#[error(code = 7)]
const ERecipeDisabled: vector<u8> = b"Recipe revision is not enabled for new jobs";
#[error(code = 8)]
const EWrongFacility: vector<u8> = b"Facility type or tier cannot execute this recipe";
#[error(code = 9)]
const ENotAdmin: vector<u8> = b"Sender is not a recipe registry admin";

// === Constants ===

const VERSION: u64 = 1;
const MAX_LINES: u64 = 32;
const MAX_FACILITIES: u64 = 32;
const MAX_BATCHES: u64 = 1000000;
const MAX_U64: u128 = 18446744073709551615;

// === Structs ===

/// A positive per-batch quantity of a canonical item type.
public struct RecipeLine has copy, drop, store {
    type_id: u64,
    quantity_per_batch: u64,
}

/// Governed catalog of recipe revisions. Enablement applies only to new starts.
public struct RecipeRegistry has key {
    id: UID,
    version: u64,
    item_registry_id: ID,
    admin_acl_id: ID,
    tenant: String,
    revisions: Table<u64, u64>,
    enabled: Table<ID, bool>,
}

/// Immutable economic terms. Kind is descriptive eligibility data, not a code path.
public struct RecipeRevision has key, store {
    id: UID,
    version: u64,
    registry_id: ID,
    item_registry_id: ID,
    tenant: String,
    logical_id: u64,
    revision: u64,
    kind: u8,
    inputs: vector<RecipeLine>,
    outputs: vector<RecipeLine>,
    facility_types: vector<u64>,
    min_tier: u64,
    max_batches: u64,
    duration_ms_per_batch: u64,
    digest: vector<u8>,
}

// === Events ===

/// Event describing this committed industry change.
public struct RecipeRegistryCreated has copy, drop {
    registry_id: ID,
    item_registry_id: ID,
    tenant: String,
}

/// Event describing this committed industry change.
public struct RecipePublished has copy, drop {
    registry_id: ID,
    recipe_id: ID,
    logical_id: u64,
    revision: u64,
    kind: u8,
    digest: vector<u8>,
}

/// Event describing this committed industry change.
public struct RecipeEnablementChanged has copy, drop {
    registry_id: ID,
    recipe_id: ID,
    enabled: bool,
}

// === Public Functions ===

/// Create a shared registry bound to an admin's existing tenant item catalog.
public fun create(types: &ItemTypeRegistry, acl: &AdminACL, ctx: &mut TxContext): ID {
    item_type::assert_admin(types, acl, ctx);
    let registry = RecipeRegistry {
        id: object::new(ctx),
        version: VERSION,
        item_registry_id: object::id(types),
        admin_acl_id: object::id(acl),
        tenant: item_type::tenant(types),
        revisions: table::new(ctx),
        enabled: table::new(ctx),
    };
    let id = object::id(&registry);
    event::emit(RecipeRegistryCreated {
        registry_id: id,
        item_registry_id: registry.item_registry_id,
        tenant: registry.tenant,
    });
    transfer::share_object(registry);
    id
}

/// Build one recipe line; publish validates ordering and canonical type metadata.
public fun line(type_id: u64, quantity_per_batch: u64): RecipeLine {
    assert!(quantity_per_batch > 0, EInvalidLines);
    RecipeLine { type_id, quantity_per_batch }
}

/// Validate provenance, enablement and batch bounds before accepting a new job.
public fun assert_enabled(registry: &RecipeRegistry, recipe: &RecipeRevision, batches: u64) {
    assert!(registry.version == VERSION && recipe.version == VERSION, EWrongVersion);
    assert!(
        recipe.registry_id == object::id(registry) && recipe.item_registry_id == registry.item_registry_id,
        EWrongRegistry,
    );
    assert!(registry.enabled.contains(object::id(recipe)), ERecipeDisabled);
    assert!(registry.enabled[object::id(recipe)], ERecipeDisabled);
    assert!(batches > 0 && batches <= recipe.max_batches, EInvalidBatches);
}

/// Validate the admin-attested facility against the immutable recipe.
public fun assert_facility(recipe: &RecipeRevision, facility_type: u64, tier: u64) {
    assert!(recipe.version == VERSION, EWrongVersion);
    assert!(
        recipe.facility_types.contains(&facility_type) && tier >= recipe.min_tier,
        EWrongFacility,
    );
}

/// Derive the complete canonical input and output arrays for a batch count.
public fun amounts(
    recipe: &RecipeRevision,
    batches: u64,
): (vector<ItemAmount>, vector<ItemAmount>) {
    assert!(recipe.version == VERSION, EWrongVersion);
    assert!(batches > 0 && batches <= recipe.max_batches, EInvalidBatches);
    (scale(&recipe.inputs, batches), scale(&recipe.outputs, batches))
}

/// Read a recipe's total processing duration with checked arithmetic.
public fun duration(recipe: &RecipeRevision, batches: u64): u64 {
    assert!(recipe.version == VERSION, EWrongVersion);
    assert!(batches > 0 && batches <= recipe.max_batches, EInvalidBatches);
    checked_product(recipe.duration_ms_per_batch, batches)
}

/// Kinds are shared across the single engine: 0 refining, 1 manufacturing.
public fun assert_kind(kind: u8) {
    assert!(kind <= 1, EInvalidKind);
}

// === View Functions ===

/// Read refining.
public fun refining(): u8 { 0 }

/// Read manufacturing.
public fun manufacturing(): u8 { 1 }

/// Read max lines.
public fun max_lines(): u64 { MAX_LINES }

/// Read type id.
public fun type_id(line: &RecipeLine): u64 { line.type_id }

/// Read quantity per batch.
public fun quantity_per_batch(line: &RecipeLine): u64 { line.quantity_per_batch }

/// Read registry version.
public fun registry_version(registry: &RecipeRegistry): u64 { registry.version }

/// Read registry item registry id.
public fun registry_item_registry_id(registry: &RecipeRegistry): ID { registry.item_registry_id }

/// Read admin acl id.
public fun admin_acl_id(registry: &RecipeRegistry): ID { registry.admin_acl_id }

/// Read registry tenant.
public fun registry_tenant(registry: &RecipeRegistry): String { registry.tenant }

/// Read revisions.
public fun revisions(registry: &RecipeRegistry): &Table<u64, u64> { &registry.revisions }

/// Read enabled.
public fun enabled(registry: &RecipeRegistry): &Table<ID, bool> { &registry.enabled }

/// Read version.
public fun version(recipe: &RecipeRevision): u64 { recipe.version }

/// Read registry id.
public fun registry_id(recipe: &RecipeRevision): ID { recipe.registry_id }

/// Read item registry id.
public fun item_registry_id(recipe: &RecipeRevision): ID { recipe.item_registry_id }

/// Read tenant.
public fun tenant(recipe: &RecipeRevision): String { recipe.tenant }

/// Read logical id.
public fun logical_id(recipe: &RecipeRevision): u64 { recipe.logical_id }

/// Read revision.
public fun revision(recipe: &RecipeRevision): u64 { recipe.revision }

/// Read kind.
public fun kind(recipe: &RecipeRevision): u8 { recipe.kind }

/// Read inputs.
public fun inputs(recipe: &RecipeRevision): &vector<RecipeLine> { &recipe.inputs }

/// Read outputs.
public fun outputs(recipe: &RecipeRevision): &vector<RecipeLine> { &recipe.outputs }

/// Read facility types.
public fun facility_types(recipe: &RecipeRevision): &vector<u64> { &recipe.facility_types }

/// Read min tier.
public fun min_tier(recipe: &RecipeRevision): u64 { recipe.min_tier }

/// Read max batches.
public fun max_batches(recipe: &RecipeRevision): u64 { recipe.max_batches }

/// Read duration ms per batch.
public fun duration_ms_per_batch(recipe: &RecipeRevision): u64 { recipe.duration_ms_per_batch }

/// Read digest.
public fun digest(recipe: &RecipeRevision): &vector<u8> { &recipe.digest }

/// Read registry id from the created projection.
public fun created_registry_id(value: &RecipeRegistryCreated): ID { value.registry_id }

/// Read item registry id from the created projection.
public fun created_item_registry_id(value: &RecipeRegistryCreated): ID { value.item_registry_id }

/// Read tenant from the created projection.
public fun created_tenant(value: &RecipeRegistryCreated): String { value.tenant }

/// Read registry id from the published projection.
public fun published_registry_id(value: &RecipePublished): ID { value.registry_id }

/// Read recipe id from the published projection.
public fun published_recipe_id(value: &RecipePublished): ID { value.recipe_id }

/// Read logical id from the published projection.
public fun published_logical_id(value: &RecipePublished): u64 { value.logical_id }

/// Read revision from the published projection.
public fun published_revision(value: &RecipePublished): u64 { value.revision }

/// Read kind from the published projection.
public fun published_kind(value: &RecipePublished): u8 { value.kind }

/// Read digest from the published projection.
public fun published_digest(value: &RecipePublished): &vector<u8> { &value.digest }

/// Read registry id from the enablement changed projection.
public fun enablement_changed_registry_id(value: &RecipeEnablementChanged): ID { value.registry_id }

/// Read recipe id from the enablement changed projection.
public fun enablement_changed_recipe_id(value: &RecipeEnablementChanged): ID { value.recipe_id }

/// Read enabled from the enablement changed projection.
public fun enablement_changed_enabled(value: &RecipeEnablementChanged): bool { value.enabled }

// === Admin Functions ===

/// Publish and freeze a new revision. Existing jobs retain their previous terms.
public fun publish(
    registry: &mut RecipeRegistry,
    types: &ItemTypeRegistry,
    acl: &AdminACL,
    logical_id: u64,
    kind: u8,
    inputs: vector<RecipeLine>,
    outputs: vector<RecipeLine>,
    facility_types: vector<u64>,
    min_tier: u64,
    max_batches: u64,
    duration_ms_per_batch: u64,
    ctx: &mut TxContext,
): ID {
    assert!(registry.version == VERSION, EWrongVersion);
    assert!(registry.item_registry_id == object::id(types), EWrongRegistry);
    item_type::assert_admin(types, acl, ctx);
    assert!(registry.admin_acl_id == object::id(acl), EWrongRegistry);
    assert_kind(kind);
    validate_lines(types, &inputs);
    validate_lines(types, &outputs);
    assert!(max_batches > 0 && max_batches <= MAX_BATCHES, EInvalidBatches);
    assert!(
        !facility_types.is_empty() && facility_types.length() <= MAX_FACILITIES,
        EInvalidFacilities,
    );
    let mut i = 1;
    while (i < facility_types.length()) {
        assert!(facility_types[i - 1] < facility_types[i], EInvalidFacilities);
        i = i + 1;
    };
    // Reject recipes whose advertised maximum batch cannot be represented.
    let _ = scale(&inputs, max_batches);
    let _ = scale(&outputs, max_batches);
    let _ = checked_product(duration_ms_per_batch, max_batches);
    let revision = if (registry.revisions.contains(logical_id)) {
        let previous = &mut registry.revisions[logical_id];
        assert!((*previous as u128) < MAX_U64, EOverflow);
        *previous = *previous + 1;
        *previous
    } else {
        registry.revisions.add(logical_id, 1);
        1
    };
    let mut value = RecipeRevision {
        id: object::new(ctx),
        version: VERSION,
        registry_id: object::id(registry),
        item_registry_id: object::id(types),
        tenant: registry.tenant,
        logical_id,
        revision,
        kind,
        inputs,
        outputs,
        facility_types,
        min_tier,
        max_batches,
        duration_ms_per_batch,
        digest: vector[],
    };
    // Hash the versioned struct with an empty digest field, including all terms.
    value.digest = hash::blake2b256(&std::bcs::to_bytes(&value));
    let recipe_id = object::id(&value);
    registry.enabled.add(recipe_id, true);
    event::emit(RecipePublished {
        registry_id: object::id(registry),
        recipe_id,
        logical_id,
        revision,
        kind,
        digest: value.digest,
    });
    transfer::freeze_object(value);
    recipe_id
}

/// Disable/enable admission; this does not modify any funded job.
public fun set_enabled(
    registry: &mut RecipeRegistry,
    acl: &AdminACL,
    recipe_id: ID,
    enabled: bool,
    ctx: &mut TxContext,
) {
    assert!(registry.version == VERSION, EWrongVersion);
    assert!(registry.admin_acl_id == object::id(acl), EWrongRegistry);
    assert!(core::admin_service::is_admin(acl, ctx.sender()), ENotAdmin);
    assert!(registry.enabled.contains(recipe_id), ERecipeDisabled);
    *&mut registry.enabled[recipe_id] = enabled;
    event::emit(RecipeEnablementChanged { registry_id: object::id(registry), recipe_id, enabled });
}

// === Private Functions ===

fun validate_lines(types: &ItemTypeRegistry, lines: &vector<RecipeLine>) {
    assert!(!lines.is_empty() && lines.length() <= MAX_LINES, EInvalidLines);
    let mut i = 0;
    while (i < lines.length()) {
        let value = &lines[i];
        assert!(value.quantity_per_batch > 0, EInvalidLines);
        if (i > 0) assert!(lines[i - 1].type_id < value.type_id, EInvalidLines);
        item_type::assert_production_enabled(types, value.type_id);
        i = i + 1;
    };
}

fun scale(lines: &vector<RecipeLine>, batches: u64): vector<ItemAmount> {
    lines.map_ref!(
        |line| item_v2::amount(line.type_id, checked_product(line.quantity_per_batch, batches)),
    )
}

fun checked_product(a: u64, b: u64): u64 {
    let result = (a as u128) * (b as u128);
    assert!(result <= MAX_U64, EOverflow);
    result as u64
}
