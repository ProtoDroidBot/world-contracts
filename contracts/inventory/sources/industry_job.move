/// Durable escrow and exactly-once transitions for every industry recipe kind.
/// Only the inventory package can create or mutate jobs; industry owns access.
module inventory::industry_job;

use inventory::{
    item_type::{Self, ItemTypeRegistry},
    item_v2::{Self, ItemV2, ItemAmount},
    recipe::{Self, RecipeRevision}
};
use std::string::String;
use sui::{balance::{Self, Balance}, clock::Clock, coin::{Self, Coin}, sui::SUI};

// === Errors ===

#[error(code = 0)]
const EWrongVersion: vector<u8> = b"Unsupported industry job schema";
#[error(code = 1)]
const EWrongState: vector<u8> = b"Industry job is not in the required state";
#[error(code = 2)]
const ENotReady: vector<u8> = b"Industry job has not reached its completion time";
#[error(code = 3)]
const ECancelTooLate: vector<u8> = b"A mature industry job cannot be cancelled";
#[error(code = 4)]
const EInputMismatch: vector<u8> = b"Actual input assets do not exactly fund the recipe";
#[error(code = 5)]
const EWrongRegistry: vector<u8> = b"Job item catalog does not match";
#[error(code = 6)]
const EOverflow: vector<u8> = b"Job timestamp exceeds u64";

// === Constants ===

const VERSION: u64 = 1;
const RUNNING: u8 = 0;
const COMPLETED: u8 = 1;
const CANCELLED: u8 = 2;
const MAX_U64: u128 = 18446744073709551615;

// === Structs ===

/// A job remains inside its Industry module until its assets are fully delivered.
public struct IndustryJob has key, store {
    id: UID,
    version: u64,
    entity_id: ID,
    module_id: u64,
    item_registry_id: ID,
    tenant: String,
    recipe_id: ID,
    recipe_digest: vector<u8>,
    kind: u8,
    beneficiary: ID,
    batches: u64,
    committed_inputs: vector<ItemAmount>,
    committed_outputs: vector<ItemAmount>,
    input_volume: u64,
    output_volume: u64,
    started_at_ms: u64,
    ready_at_ms: u64,
    state: u8,
    escrow: vector<ItemV2>,
    products: vector<ItemV2>,
    fee: Balance<SUI>,
    fee_amount: u64,
    fee_recipient: address,
}

// === View Functions ===

/// Read version.
public fun version(job: &IndustryJob): u64 { job.version }

/// Read entity id.
public fun entity_id(job: &IndustryJob): ID { job.entity_id }

/// Read module id.
public fun module_id(job: &IndustryJob): u64 { job.module_id }

/// Read item registry id.
public fun item_registry_id(job: &IndustryJob): ID { job.item_registry_id }

/// Read tenant.
public fun tenant(job: &IndustryJob): String { job.tenant }

/// Read recipe id.
public fun recipe_id(job: &IndustryJob): ID { job.recipe_id }

/// Read recipe digest.
public fun recipe_digest(job: &IndustryJob): &vector<u8> { &job.recipe_digest }

/// Read kind.
public fun kind(job: &IndustryJob): u8 { job.kind }

/// Read beneficiary.
public fun beneficiary(job: &IndustryJob): ID { job.beneficiary }

/// Read batches.
public fun batches(job: &IndustryJob): u64 { job.batches }

/// Read committed inputs.
public fun committed_inputs(job: &IndustryJob): &vector<ItemAmount> { &job.committed_inputs }

/// Read committed outputs.
public fun committed_outputs(job: &IndustryJob): &vector<ItemAmount> { &job.committed_outputs }

/// Read input volume.
public fun input_volume(job: &IndustryJob): u64 { job.input_volume }

/// Read output volume.
public fun output_volume(job: &IndustryJob): u64 { job.output_volume }

/// Read started at ms.
public fun started_at_ms(job: &IndustryJob): u64 { job.started_at_ms }

/// Read ready at ms.
public fun ready_at_ms(job: &IndustryJob): u64 { job.ready_at_ms }

/// Read state.
public fun state(job: &IndustryJob): u8 { job.state }

/// Read escrow.
public fun escrow(job: &IndustryJob): &vector<ItemV2> { &job.escrow }

/// Read products.
public fun products(job: &IndustryJob): &vector<ItemV2> { &job.products }

/// Read fee.
public fun fee(job: &IndustryJob): &Balance<SUI> { &job.fee }

/// Read fee amount.
public fun fee_amount(job: &IndustryJob): u64 { job.fee_amount }

/// Read fee recipient.
public fun fee_recipient(job: &IndustryJob): address { job.fee_recipient }

/// Read is running.
public fun is_running(job: &IndustryJob): bool { job.state == RUNNING }

// === Package Functions ===

/// Validate actual assets, snapshot the complete recipe, and lock inputs and fee.
public(package) fun new(
    types: &ItemTypeRegistry,
    recipe: &RecipeRevision,
    entity_id: ID,
    module_id: u64,
    beneficiary: ID,
    batches: u64,
    inputs: vector<ItemV2>,
    fee: Balance<SUI>,
    fee_recipient: address,
    clock: &Clock,
    ctx: &mut TxContext,
): IndustryJob {
    assert!(object::id(types) == recipe::item_registry_id(recipe), EWrongRegistry);
    let (committed_inputs, committed_outputs) = recipe::amounts(recipe, batches);
    let actual = item_v2::aggregate(types, &inputs);
    assert!(item_v2::matches(&actual, &committed_inputs), EInputMismatch);
    let input_volume = item_v2::total_volume(types, &committed_inputs);
    let output_volume = item_v2::total_volume(types, &committed_outputs);
    let started_at_ms = clock.timestamp_ms();
    let ready = (started_at_ms as u128) + (recipe::duration(recipe, batches) as u128);
    assert!(ready <= MAX_U64, EOverflow);
    let fee_amount = balance::value(&fee);
    IndustryJob {
        id: object::new(ctx),
        version: VERSION,
        entity_id,
        module_id,
        item_registry_id: object::id(types),
        tenant: item_type::tenant(types),
        recipe_id: object::id(recipe),
        recipe_digest: *recipe::digest(recipe),
        kind: recipe::kind(recipe),
        beneficiary,
        batches,
        committed_inputs,
        committed_outputs,
        input_volume,
        output_volume,
        started_at_ms,
        ready_at_ms: ready as u64,
        state: RUNNING,
        escrow: inputs,
        products: vector[],
        fee,
        fee_amount,
        fee_recipient,
    }
}

/// Consume all inputs and create every promised product in one transition.
public(package) fun settle(
    job: &mut IndustryJob,
    types: &ItemTypeRegistry,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(job.version == VERSION, EWrongVersion);
    assert!(job.state == RUNNING, EWrongState);
    assert!(clock.timestamp_ms() >= job.ready_at_ms, ENotReady);
    assert!(object::id(types) == job.item_registry_id, EWrongRegistry);
    let job_id = object::id(job);
    while (!job.escrow.is_empty()) item_v2::burn_production(job.escrow.pop_back(), job_id);
    job.committed_outputs.do_ref!(|amount| {
        job
            .products
            .push_back(
                item_v2::mint_production(
                    types,
                    item_v2::amount_type_id(amount),
                    item_v2::amount_quantity(amount),
                    job_id,
                    ctx,
                ),
            );
    });
    job.state = COMPLETED;
    if (job.fee_amount > 0) {
        let payment = coin::from_balance(balance::withdraw_all(&mut job.fee), ctx);
        transfer::public_transfer(payment, job.fee_recipient);
    };
}

/// Keep original escrow refundable and prohibit product creation after cancellation.
public(package) fun cancel(job: &mut IndustryJob, clock: &Clock) {
    assert!(job.version == VERSION, EWrongVersion);
    assert!(job.state == RUNNING, EWrongState);
    assert!(clock.timestamp_ms() < job.ready_at_ms, ECancelTooLate);
    job.state = CANCELLED;
}

/// Remove a completed job and return all products to the authenticated beneficiary.
public(package) fun take_outputs(job: IndustryJob): vector<ItemV2> {
    assert!(job.version == VERSION, EWrongVersion);
    assert!(job.state == COMPLETED, EWrongState);
    let IndustryJob { id, escrow, products, fee, .. } = job;
    escrow.destroy_empty();
    balance::destroy_zero(fee);
    id.delete();
    products
}

/// Remove a cancelled job and refund its input assets and the full committed fee.
public(package) fun take_refund(
    job: IndustryJob,
    ctx: &mut TxContext,
): (vector<ItemV2>, Coin<SUI>) {
    assert!(job.version == VERSION, EWrongVersion);
    assert!(job.state == CANCELLED, EWrongState);
    let IndustryJob { id, escrow, products, fee, .. } = job;
    products.destroy_empty();
    id.delete();
    (escrow, coin::from_balance(fee, ctx))
}
