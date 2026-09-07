/// Exact N-to-M settlement, durable snapshots, and refund accounting.
#[test_only]
module inventory::industry_job_tests;

use inventory::{
    industry_job::{Self, IndustryJob},
    item_type::{Self, ItemTypeRegistry},
    item_v2::{Self, ItemV2, ProductionMinted, ProductionBurned},
    recipe::{Self, RecipeRevision},
    recipe_tests
};
use std::string;
use sui::{balance, clock::{Self, Clock}, coin::{Self, Coin}, event, sui::SUI, test_scenario as ts};

// === Private Functions ===

fun mint(types: &ItemTypeRegistry, type_id: u64, quantity: u64, ctx: &mut TxContext): ItemV2 {
    item_v2::mint_production(types, type_id, quantity, object::id_from_address(@0xFA), ctx)
}

fun fragmented_inputs(types: &ItemTypeRegistry, ctx: &mut TxContext): vector<ItemV2> {
    // Intentionally unsorted and fragmented: exact totals are 10:4 and 20:6.
    vector[
        mint(types, 20, 2, ctx),
        mint(types, 10, 1, ctx),
        mint(types, 20, 4, ctx),
        mint(types, 10, 3, ctx),
    ]
}

fun new_job(
    types: &ItemTypeRegistry,
    terms: &RecipeRevision,
    inputs: vector<ItemV2>,
    clock: &Clock,
    ctx: &mut TxContext,
): IndustryJob {
    industry_job::new(
        types,
        terms,
        object::id_from_address(@0xAA),
        7,
        object::id_from_address(@0xBB),
        2,
        inputs,
        balance::create_for_testing<SUI>(37),
        @0xF,
        clock,
        ctx,
    )
}

fun prepared_job(
    types: &ItemTypeRegistry,
    terms: &RecipeRevision,
    clock: &Clock,
    ctx: &mut TxContext,
): IndustryJob {
    new_job(types, terms, fragmented_inputs(types, ctx), clock, ctx)
}

// === Test Functions ===

#[test]
fun fragmented_two_inputs_create_all_three_outputs_with_one_fee_payment() {
    let mut scenario = ts::begin(@0xA);
    let (types, mut registry, acl, terms) = recipe_tests::prepared(
        &mut scenario,
        recipe::manufacturing(),
        5,
    );
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock.set_for_testing(1000);
    let mut job = prepared_job(&types, &terms, &clock, scenario.ctx());
    let job_id = object::id(&job);
    assert!(job.is_running());
    assert!(job.input_volume() == 26);
    assert!(job.output_volume() == 242);
    assert!(job.escrow().length() == 4);
    assert!(job.products().is_empty());
    assert!(job.started_at_ms() == 1000 && job.ready_at_ms() == 1010);
    assert!(*job.committed_inputs() == vector[item_v2::amount(10, 4), item_v2::amount(20, 6)]);
    assert!(
        *job.committed_outputs() == vector[item_v2::amount(30, 8), item_v2::amount(40, 10), item_v2::amount(50, 12)],
    );
    assert!(*job.recipe_digest() == *terms.digest());
    assert!(job.beneficiary() == object::id_from_address(@0xBB));
    assert!(job.fee_amount() == 37 && balance::value(job.fee()) == 37);

    // Closing admission never changes the terms of an accepted job.
    recipe::set_enabled(&mut registry, &acl, object::id(&terms), false, scenario.ctx());
    let minted_before = event::events_by_type<ProductionMinted>().length();
    let burned_before = event::events_by_type<ProductionBurned>().length();
    clock.set_for_testing(1010);
    industry_job::settle(&mut job, &types, &clock, scenario.ctx());
    assert!(!job.is_running());
    assert!(job.escrow().is_empty());
    assert!(job.products().length() == 3);
    assert!(balance::value(job.fee()) == 0);
    let minted = event::events_by_type<ProductionMinted>();
    let burned = event::events_by_type<ProductionBurned>();
    assert!(minted.length() == minted_before + 3);
    assert!(burned.length() == burned_before + 4);
    let mut i = minted_before;
    while (i < minted.length()) {
        assert!(item_v2::minted_job_id(&minted[i]) == job_id);
        assert!(item_v2::minted_registry_id(&minted[i]) == object::id(&types));
        assert!(item_v2::minted_tenant(&minted[i]) == item_type::tenant(&types));
        i = i + 1;
    };
    i = burned_before;
    while (i < burned.length()) {
        assert!(item_v2::burned_job_id(&burned[i]) == job_id);
        assert!(item_v2::burned_registry_id(&burned[i]) == object::id(&types));
        i = i + 1;
    };
    let outputs = industry_job::take_outputs(job);
    let actual = item_v2::aggregate(&types, &outputs);
    assert!(
        item_v2::matches(
            &actual,
            &vector[item_v2::amount(30, 8), item_v2::amount(40, 10), item_v2::amount(50, 12)],
        ),
    );
    outputs.do_ref!(|item| item_v2::assert_canonical(&types, item));
    item_v2::transfer_all(outputs, @0xB);
    clock::destroy_for_testing(clock);
    recipe_tests::return_all(types, registry, acl, terms);

    ts::next_tx(&mut scenario, @0xF);
    let paid = ts::take_from_sender<Coin<SUI>>(&scenario);
    assert!(coin::value(&paid) == 37);
    assert!(coin::burn_for_testing(paid) == 37);
    scenario.end();
}

#[test]
fun cancellation_preserves_original_assets_and_refunds_full_fee_before_boundary() {
    let mut scenario = ts::begin(@0xA);
    let (types, registry, acl, terms) = recipe_tests::prepared(
        &mut scenario,
        recipe::refining(),
        5,
    );
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock.set_for_testing(2000);
    let inputs = fragmented_inputs(&types, scenario.ctx());
    let input_ids = inputs.map_ref!(|item| object::id(item));
    let minted_before = event::events_by_type<ProductionMinted>().length();
    let burned_before = event::events_by_type<ProductionBurned>().length();
    let mut job = new_job(&types, &terms, inputs, &clock, scenario.ctx());
    clock.set_for_testing(2009);
    industry_job::cancel(&mut job, &clock);
    assert!(!job.is_running());
    assert!(job.products().is_empty());
    assert!(balance::value(job.fee()) == 37);
    let (refunds, fee) = industry_job::take_refund(job, scenario.ctx());
    assert!(refunds.map_ref!(|item| object::id(item)) == input_ids);
    assert!(
        item_v2::matches(
            &item_v2::aggregate(&types, &refunds),
            &vector[item_v2::amount(10, 4), item_v2::amount(20, 6)],
        ),
    );
    refunds.do_ref!(|item| item_v2::assert_canonical(&types, item));
    assert!(event::events_by_type<ProductionMinted>().length() == minted_before);
    assert!(event::events_by_type<ProductionBurned>().length() == burned_before);
    assert!(coin::value(&fee) == 37);
    assert!(coin::burn_for_testing(fee) == 37);
    item_v2::transfer_all(refunds, @0xB);
    clock::destroy_for_testing(clock);
    recipe_tests::return_all(types, registry, acl, terms);
    scenario.end();
}

#[test]
fun zero_duration_recipe_settles_atomically_without_clock_advance() {
    let mut scenario = ts::begin(@0xA);
    let (types, registry, acl, terms) = recipe_tests::prepared(
        &mut scenario,
        recipe::refining(),
        0,
    );
    let clock = clock::create_for_testing(scenario.ctx());
    let mut job = industry_job::new(
        &types,
        &terms,
        object::id_from_address(@0xAA),
        7,
        object::id_from_address(@0xBB),
        2,
        fragmented_inputs(&types, scenario.ctx()),
        balance::zero<SUI>(),
        @0xF,
        &clock,
        scenario.ctx(),
    );
    assert!(job.ready_at_ms() == job.started_at_ms());
    industry_job::settle(&mut job, &types, &clock, scenario.ctx());
    let outputs = industry_job::take_outputs(job);
    assert!(outputs.length() == 3);
    item_v2::transfer_all(outputs, @0xB);
    clock::destroy_for_testing(clock);
    recipe_tests::return_all(types, registry, acl, terms);
    scenario.end();
}

#[test, expected_failure(abort_code = item_v2::ETooManyItems)]
fun empty_funding_rejected() {
    let mut scenario = ts::begin(@0xA);
    let (types, _registry, _acl, terms) = recipe_tests::prepared(
        &mut scenario,
        recipe::refining(),
        5,
    );
    let clock = clock::create_for_testing(scenario.ctx());
    let _job = new_job(&types, &terms, vector[], &clock, scenario.ctx());
    abort
}

#[test, expected_failure(abort_code = industry_job::EInputMismatch)]
fun missing_required_type_rejected() {
    let mut scenario = ts::begin(@0xA);
    let (types, _registry, _acl, terms) = recipe_tests::prepared(
        &mut scenario,
        recipe::refining(),
        5,
    );
    let clock = clock::create_for_testing(scenario.ctx());
    let inputs = vector[mint(&types, 10, 4, scenario.ctx())];
    let _job = new_job(&types, &terms, inputs, &clock, scenario.ctx());
    abort
}

#[test, expected_failure(abort_code = industry_job::EInputMismatch)]
fun extra_input_type_rejected() {
    let mut scenario = ts::begin(@0xA);
    let (types, _registry, _acl, terms) = recipe_tests::prepared(
        &mut scenario,
        recipe::refining(),
        5,
    );
    let clock = clock::create_for_testing(scenario.ctx());
    let mut inputs = fragmented_inputs(&types, scenario.ctx());
    inputs.push_back(mint(&types, 99, 1, scenario.ctx()));
    let _job = new_job(&types, &terms, inputs, &clock, scenario.ctx());
    abort
}

#[test, expected_failure(abort_code = industry_job::EInputMismatch)]
fun overfunded_existing_type_rejected() {
    let mut scenario = ts::begin(@0xA);
    let (types, _registry, _acl, terms) = recipe_tests::prepared(
        &mut scenario,
        recipe::refining(),
        5,
    );
    let clock = clock::create_for_testing(scenario.ctx());
    let mut inputs = fragmented_inputs(&types, scenario.ctx());
    inputs.push_back(mint(&types, 10, 1, scenario.ctx()));
    let _job = new_job(&types, &terms, inputs, &clock, scenario.ctx());
    abort
}

#[test, expected_failure(abort_code = industry_job::EInputMismatch)]
fun underfunded_existing_type_rejected() {
    let mut scenario = ts::begin(@0xA);
    let (types, _registry, _acl, terms) = recipe_tests::prepared(
        &mut scenario,
        recipe::refining(),
        5,
    );
    let clock = clock::create_for_testing(scenario.ctx());
    let inputs = vector[mint(&types, 10, 4, scenario.ctx()), mint(&types, 20, 5, scenario.ctx())];
    let _job = new_job(&types, &terms, inputs, &clock, scenario.ctx());
    abort
}

#[test, expected_failure(abort_code = item_v2::EWrongRegistry)]
fun exact_quantities_from_another_catalog_rejected() {
    let mut scenario = ts::begin(@0xA);
    let (types, registry, acl, terms) = recipe_tests::prepared(
        &mut scenario,
        recipe::refining(),
        5,
    );
    let types_id = object::id(&types);
    let other_id = item_type::create(&acl, string::utf8(b"industry-test"), scenario.ctx());
    recipe_tests::return_all(types, registry, acl, terms);
    ts::next_tx(&mut scenario, @0xA);
    let types = ts::take_shared_by_id<ItemTypeRegistry>(&scenario, types_id);
    let mut other = ts::take_shared_by_id<ItemTypeRegistry>(&scenario, other_id);
    let acl = ts::take_shared<core::admin_service::AdminACL>(&scenario);
    item_type::register(&mut other, &acl, 10, 2, true, scenario.ctx());
    item_type::register(&mut other, &acl, 20, 3, true, scenario.ctx());
    let terms = ts::take_immutable<RecipeRevision>(&scenario);
    let inputs = fragmented_inputs(&other, scenario.ctx());
    let clock = clock::create_for_testing(scenario.ctx());
    let _job = new_job(&types, &terms, inputs, &clock, scenario.ctx());
    abort
}

#[test, expected_failure(abort_code = industry_job::ENotReady)]
fun settlement_one_millisecond_early_rejected() {
    let mut scenario = ts::begin(@0xA);
    let (types, _registry, _acl, terms) = recipe_tests::prepared(
        &mut scenario,
        recipe::refining(),
        5,
    );
    let mut clock = clock::create_for_testing(scenario.ctx());
    let mut job = prepared_job(&types, &terms, &clock, scenario.ctx());
    clock.set_for_testing(9);
    industry_job::settle(&mut job, &types, &clock, scenario.ctx());
    abort
}

#[test, expected_failure(abort_code = industry_job::ECancelTooLate)]
fun cancellation_at_exact_maturity_rejected() {
    let mut scenario = ts::begin(@0xA);
    let (types, _registry, _acl, terms) = recipe_tests::prepared(
        &mut scenario,
        recipe::refining(),
        5,
    );
    let mut clock = clock::create_for_testing(scenario.ctx());
    let mut job = prepared_job(&types, &terms, &clock, scenario.ctx());
    clock.set_for_testing(10);
    industry_job::cancel(&mut job, &clock);
    abort
}

#[test, expected_failure(abort_code = industry_job::ECancelTooLate)]
fun zero_duration_job_cannot_be_cancelled() {
    let mut scenario = ts::begin(@0xA);
    let (types, _registry, _acl, terms) = recipe_tests::prepared(
        &mut scenario,
        recipe::refining(),
        0,
    );
    let clock = clock::create_for_testing(scenario.ctx());
    let mut job = prepared_job(&types, &terms, &clock, scenario.ctx());
    industry_job::cancel(&mut job, &clock);
    abort
}

#[test, expected_failure(abort_code = industry_job::EWrongState)]
fun completed_job_cannot_settle_twice() {
    let mut scenario = ts::begin(@0xA);
    let (types, _registry, _acl, terms) = recipe_tests::prepared(
        &mut scenario,
        recipe::refining(),
        5,
    );
    let mut clock = clock::create_for_testing(scenario.ctx());
    let mut job = prepared_job(&types, &terms, &clock, scenario.ctx());
    clock.set_for_testing(10);
    industry_job::settle(&mut job, &types, &clock, scenario.ctx());
    industry_job::settle(&mut job, &types, &clock, scenario.ctx());
    abort
}

#[test, expected_failure(abort_code = industry_job::EWrongState)]
fun cancelled_job_cannot_later_produce_outputs() {
    let mut scenario = ts::begin(@0xA);
    let (types, _registry, _acl, terms) = recipe_tests::prepared(
        &mut scenario,
        recipe::refining(),
        5,
    );
    let mut clock = clock::create_for_testing(scenario.ctx());
    let mut job = prepared_job(&types, &terms, &clock, scenario.ctx());
    industry_job::cancel(&mut job, &clock);
    clock.set_for_testing(10);
    industry_job::settle(&mut job, &types, &clock, scenario.ctx());
    abort
}

#[test, expected_failure(abort_code = industry_job::EWrongState)]
fun completed_job_cannot_be_refunded() {
    let mut scenario = ts::begin(@0xA);
    let (types, _registry, _acl, terms) = recipe_tests::prepared(
        &mut scenario,
        recipe::refining(),
        5,
    );
    let mut clock = clock::create_for_testing(scenario.ctx());
    let mut job = prepared_job(&types, &terms, &clock, scenario.ctx());
    clock.set_for_testing(10);
    industry_job::settle(&mut job, &types, &clock, scenario.ctx());
    let (_inputs, _fee) = industry_job::take_refund(job, scenario.ctx());
    abort
}

#[test, expected_failure(abort_code = industry_job::EWrongState)]
fun running_job_cannot_claim_outputs() {
    let mut scenario = ts::begin(@0xA);
    let (types, _registry, _acl, terms) = recipe_tests::prepared(
        &mut scenario,
        recipe::refining(),
        5,
    );
    let clock = clock::create_for_testing(scenario.ctx());
    let job = prepared_job(&types, &terms, &clock, scenario.ctx());
    let _outputs = industry_job::take_outputs(job);
    abort
}

#[test, expected_failure(abort_code = industry_job::EWrongState)]
fun running_job_cannot_claim_refund() {
    let mut scenario = ts::begin(@0xA);
    let (types, _registry, _acl, terms) = recipe_tests::prepared(
        &mut scenario,
        recipe::refining(),
        5,
    );
    let clock = clock::create_for_testing(scenario.ctx());
    let job = prepared_job(&types, &terms, &clock, scenario.ctx());
    let (_inputs, _fee) = industry_job::take_refund(job, scenario.ctx());
    abort
}

#[test, expected_failure(abort_code = industry_job::EOverflow)]
fun completion_timestamp_overflow_rejected() {
    let mut scenario = ts::begin(@0xA);
    let (types, _registry, _acl, terms) = recipe_tests::prepared(
        &mut scenario,
        recipe::refining(),
        5,
    );
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock.set_for_testing(18446744073709551610);
    let _job = prepared_job(&types, &terms, &clock, scenario.ctx());
    abort
}
