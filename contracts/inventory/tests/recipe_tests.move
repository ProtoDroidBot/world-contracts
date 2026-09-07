/// Governed recipe admission and immutable economic terms.
#[test_only]
module inventory::recipe_tests;

use core::admin_service::{Self, AdminACL};
use inventory::{
    item_type::{Self, ItemTypeRegistry},
    item_v2,
    recipe::{Self, RecipeRegistry, RecipeRevision, RecipeLine}
};
use std::string;
use sui::test_scenario as ts;

// === Test Functions ===

/// Catalog fixtures are shared with the package-private job engine tests.
public fun setup(scenario: &mut ts::Scenario): (ItemTypeRegistry, RecipeRegistry, AdminACL) {
    admin_service::init_for_testing(scenario.ctx());
    ts::next_tx(scenario, @0xA);
    let acl = ts::take_shared<AdminACL>(scenario);
    item_type::create(&acl, string::utf8(b"industry-test"), scenario.ctx());
    ts::return_shared(acl);
    ts::next_tx(scenario, @0xA);
    let acl = ts::take_shared<AdminACL>(scenario);
    let mut types = ts::take_shared<ItemTypeRegistry>(scenario);
    item_type::register(&mut types, &acl, 10, 2, true, scenario.ctx());
    item_type::register(&mut types, &acl, 20, 3, true, scenario.ctx());
    item_type::register(&mut types, &acl, 30, 5, true, scenario.ctx());
    item_type::register(&mut types, &acl, 40, 7, true, scenario.ctx());
    item_type::register(&mut types, &acl, 50, 11, true, scenario.ctx());
    item_type::register(&mut types, &acl, 60, 1, false, scenario.ctx());
    item_type::register(&mut types, &acl, 99, 1, true, scenario.ctx());
    recipe::create(&types, &acl, scenario.ctx());
    ts::return_shared(types);
    ts::return_shared(acl);
    ts::next_tx(scenario, @0xA);
    (
        ts::take_shared<ItemTypeRegistry>(scenario),
        ts::take_shared<RecipeRegistry>(scenario),
        ts::take_shared<AdminACL>(scenario),
    )
}

public fun publish_standard(
    types: &ItemTypeRegistry,
    registry: &mut RecipeRegistry,
    acl: &AdminACL,
    kind: u8,
    duration: u64,
    ctx: &mut TxContext,
): ID {
    recipe::publish(
        registry,
        types,
        acl,
        42,
        kind,
        vector[recipe::line(10, 2), recipe::line(20, 3)],
        vector[recipe::line(30, 4), recipe::line(40, 5), recipe::line(50, 6)],
        vector[100, 200],
        2,
        100,
        duration,
        ctx,
    )
}

public fun prepared(
    scenario: &mut ts::Scenario,
    kind: u8,
    duration: u64,
): (ItemTypeRegistry, RecipeRegistry, AdminACL, RecipeRevision) {
    let (types, mut registry, acl) = setup(scenario);
    let recipe_id = publish_standard(&types, &mut registry, &acl, kind, duration, scenario.ctx());
    ts::return_shared(types);
    ts::return_shared(registry);
    ts::return_shared(acl);
    ts::next_tx(scenario, @0xA);
    (
        ts::take_shared<ItemTypeRegistry>(scenario),
        ts::take_shared<RecipeRegistry>(scenario),
        ts::take_shared<AdminACL>(scenario),
        ts::take_immutable_by_id<RecipeRevision>(scenario, recipe_id),
    )
}

public fun return_all(
    types: ItemTypeRegistry,
    registry: RecipeRegistry,
    acl: AdminACL,
    terms: RecipeRevision,
) {
    ts::return_shared(types);
    ts::return_shared(registry);
    ts::return_shared(acl);
    ts::return_immutable(terms);
}

fun publish_lines(
    types: &ItemTypeRegistry,
    registry: &mut RecipeRegistry,
    acl: &AdminACL,
    inputs: vector<RecipeLine>,
    outputs: vector<RecipeLine>,
    ctx: &mut TxContext,
) {
    recipe::publish(
        registry,
        types,
        acl,
        1,
        recipe::refining(),
        inputs,
        outputs,
        vector[100],
        1,
        10,
        1,
        ctx,
    );
}

#[test]
fun immutable_revisions_keep_independent_enablement_and_terms() {
    let mut scenario = ts::begin(@0xA);
    let (types, mut registry, acl, first) = prepared(&mut scenario, recipe::refining(), 5);
    let first_id = object::id(&first);
    let first_digest = *first.digest();
    let second_id = recipe::publish(
        &mut registry,
        &types,
        &acl,
        42,
        recipe::manufacturing(),
        vector[recipe::line(10, 2), recipe::line(20, 3)],
        vector[recipe::line(30, 8)],
        vector[100],
        3,
        50,
        9,
        scenario.ctx(),
    );
    recipe::set_enabled(&mut registry, &acl, first_id, false, scenario.ctx());
    assert!(!registry.enabled()[first_id]);
    assert!(registry.enabled()[second_id]);
    // A funded job can still read old commitments after admission is disabled.
    let (_, old_outputs) = recipe::amounts(&first, 2);
    assert!(
        old_outputs == vector[item_v2::amount(30, 8), item_v2::amount(40, 10), item_v2::amount(50, 12)],
    );
    assert!(*first.digest() == first_digest);
    assert!(first.revision() == 1);
    return_all(types, registry, acl, first);

    ts::next_tx(&mut scenario, @0xA);
    let first = ts::take_immutable_by_id<RecipeRevision>(&scenario, first_id);
    let second = ts::take_immutable_by_id<RecipeRevision>(&scenario, second_id);
    let mut registry = ts::take_shared<RecipeRegistry>(&scenario);
    let acl = ts::take_shared<AdminACL>(&scenario);
    assert!(second.revision() == 2);
    assert!(first.kind() == recipe::refining());
    assert!(second.kind() == recipe::manufacturing());
    assert!(*second.digest() != first_digest);
    assert!(*first.digest() == first_digest);
    recipe::set_enabled(&mut registry, &acl, first_id, true, scenario.ctx());
    recipe::assert_enabled(&registry, &first, 100);
    recipe::assert_enabled(&registry, &second, 50);
    recipe::assert_facility(&second, 100, 3);
    ts::return_immutable(first);
    ts::return_immutable(second);
    ts::return_shared(registry);
    ts::return_shared(acl);
    scenario.end();
}

#[test]
fun scales_both_arrays_and_duration_for_the_entire_batch() {
    let mut scenario = ts::begin(@0xA);
    let (types, registry, acl, terms) = prepared(&mut scenario, recipe::manufacturing(), 5);
    let (inputs, outputs) = recipe::amounts(&terms, 2);
    assert!(inputs == vector[item_v2::amount(10, 4), item_v2::amount(20, 6)]);
    assert!(
        outputs == vector[item_v2::amount(30, 8), item_v2::amount(40, 10), item_v2::amount(50, 12)],
    );
    assert!(recipe::duration(&terms, 2) == 10);
    recipe::assert_facility(&terms, 200, 2);
    return_all(types, registry, acl, terms);
    scenario.end();
}

#[test, expected_failure(abort_code = item_type::ENotAdmin)]
fun unapproved_sender_cannot_publish() {
    let mut scenario = ts::begin(@0xA);
    let (types, registry, acl) = setup(&mut scenario);
    ts::return_shared(types);
    ts::return_shared(registry);
    ts::return_shared(acl);
    ts::next_tx(&mut scenario, @0xB);
    let types = ts::take_shared<ItemTypeRegistry>(&scenario);
    let mut registry = ts::take_shared<RecipeRegistry>(&scenario);
    let acl = ts::take_shared<AdminACL>(&scenario);
    publish_standard(&types, &mut registry, &acl, recipe::refining(), 5, scenario.ctx());
    abort
}

#[test, expected_failure(abort_code = recipe::ENotAdmin)]
fun unapproved_sender_cannot_change_enablement() {
    let mut scenario = ts::begin(@0xA);
    let (types, registry, acl, terms) = prepared(&mut scenario, recipe::refining(), 5);
    let recipe_id = object::id(&terms);
    return_all(types, registry, acl, terms);
    ts::next_tx(&mut scenario, @0xB);
    let mut registry = ts::take_shared<RecipeRegistry>(&scenario);
    let acl = ts::take_shared<AdminACL>(&scenario);
    recipe::set_enabled(&mut registry, &acl, recipe_id, false, scenario.ctx());
    abort
}

#[test, expected_failure(abort_code = recipe::ERecipeDisabled)]
fun disabled_revision_rejects_new_admission() {
    let mut scenario = ts::begin(@0xA);
    let (_types, mut registry, acl, terms) = prepared(&mut scenario, recipe::refining(), 5);
    recipe::set_enabled(&mut registry, &acl, object::id(&terms), false, scenario.ctx());
    recipe::assert_enabled(&registry, &terms, 1);
    abort
}

#[test, expected_failure(abort_code = recipe::EWrongRegistry)]
fun recipe_cannot_use_a_second_catalog_with_identical_tenant() {
    let mut scenario = ts::begin(@0xA);
    let (types, registry, acl) = setup(&mut scenario);
    let other_id = item_type::create(&acl, string::utf8(b"industry-test"), scenario.ctx());
    ts::return_shared(types);
    ts::return_shared(registry);
    ts::return_shared(acl);
    ts::next_tx(&mut scenario, @0xA);
    let other = ts::take_shared_by_id<ItemTypeRegistry>(&scenario, other_id);
    let mut registry = ts::take_shared<RecipeRegistry>(&scenario);
    let acl = ts::take_shared<AdminACL>(&scenario);
    publish_standard(&other, &mut registry, &acl, recipe::refining(), 5, scenario.ctx());
    abort
}

#[test, expected_failure(abort_code = recipe::EInvalidKind)]
fun unknown_process_kind_rejected() {
    let mut scenario = ts::begin(@0xA);
    let (types, mut registry, acl) = setup(&mut scenario);
    publish_standard(&types, &mut registry, &acl, 2, 5, scenario.ctx());
    abort
}

#[test, expected_failure(abort_code = recipe::EInvalidLines)]
fun zero_quantity_rejected() {
    let _line = recipe::line(10, 0);
    abort
}

#[test, expected_failure(abort_code = recipe::EInvalidLines)]
fun empty_input_array_rejected() {
    let mut scenario = ts::begin(@0xA);
    let (types, mut registry, acl) = setup(&mut scenario);
    publish_lines(
        &types,
        &mut registry,
        &acl,
        vector[],
        vector[recipe::line(30, 1)],
        scenario.ctx(),
    );
    abort
}

#[test, expected_failure(abort_code = recipe::EInvalidLines)]
fun empty_output_array_rejected() {
    let mut scenario = ts::begin(@0xA);
    let (types, mut registry, acl) = setup(&mut scenario);
    publish_lines(
        &types,
        &mut registry,
        &acl,
        vector[recipe::line(10, 1)],
        vector[],
        scenario.ctx(),
    );
    abort
}

#[test, expected_failure(abort_code = recipe::EInvalidLines)]
fun unsorted_inputs_rejected() {
    let mut scenario = ts::begin(@0xA);
    let (types, mut registry, acl) = setup(&mut scenario);
    publish_lines(
        &types,
        &mut registry,
        &acl,
        vector[recipe::line(20, 1), recipe::line(10, 1)],
        vector[recipe::line(30, 1)],
        scenario.ctx(),
    );
    abort
}

#[test, expected_failure(abort_code = recipe::EInvalidLines)]
fun duplicate_output_type_rejected() {
    let mut scenario = ts::begin(@0xA);
    let (types, mut registry, acl) = setup(&mut scenario);
    publish_lines(
        &types,
        &mut registry,
        &acl,
        vector[recipe::line(10, 1)],
        vector[recipe::line(30, 1), recipe::line(30, 2)],
        scenario.ctx(),
    );
    abort
}

#[test, expected_failure(abort_code = item_type::EUnknownType)]
fun unregistered_type_rejected() {
    let mut scenario = ts::begin(@0xA);
    let (types, mut registry, acl) = setup(&mut scenario);
    publish_lines(
        &types,
        &mut registry,
        &acl,
        vector[recipe::line(10, 1)],
        vector[recipe::line(999, 1)],
        scenario.ctx(),
    );
    abort
}

#[test, expected_failure(abort_code = item_type::EProductionDisabled)]
fun nonfungible_or_ineligible_type_rejected() {
    let mut scenario = ts::begin(@0xA);
    let (types, mut registry, acl) = setup(&mut scenario);
    publish_lines(
        &types,
        &mut registry,
        &acl,
        vector[recipe::line(10, 1)],
        vector[recipe::line(60, 1)],
        scenario.ctx(),
    );
    abort
}

#[test, expected_failure(abort_code = recipe::EInvalidFacilities)]
fun duplicate_facility_types_rejected() {
    let mut scenario = ts::begin(@0xA);
    let (types, mut registry, acl) = setup(&mut scenario);
    recipe::publish(
        &mut registry,
        &types,
        &acl,
        1,
        recipe::refining(),
        vector[recipe::line(10, 1)],
        vector[recipe::line(30, 1)],
        vector[100, 100],
        1,
        10,
        1,
        scenario.ctx(),
    );
    abort
}

#[test, expected_failure(abort_code = recipe::EInvalidBatches)]
fun zero_batches_rejected() {
    let mut scenario = ts::begin(@0xA);
    let (_types, registry, _acl, terms) = prepared(&mut scenario, recipe::refining(), 5);
    recipe::assert_enabled(&registry, &terms, 0);
    abort
}

#[test, expected_failure(abort_code = recipe::EInvalidBatches)]
fun batches_above_recipe_limit_rejected() {
    let mut scenario = ts::begin(@0xA);
    let (_types, registry, _acl, terms) = prepared(&mut scenario, recipe::refining(), 5);
    recipe::assert_enabled(&registry, &terms, 101);
    abort
}

#[test, expected_failure(abort_code = recipe::EWrongFacility)]
fun facility_tier_below_recipe_minimum_rejected() {
    let mut scenario = ts::begin(@0xA);
    let (_types, _registry, _acl, terms) = prepared(&mut scenario, recipe::refining(), 5);
    recipe::assert_facility(&terms, 100, 1);
    abort
}

#[test, expected_failure(abort_code = recipe::EWrongFacility)]
fun unrelated_facility_type_rejected() {
    let mut scenario = ts::begin(@0xA);
    let (_types, _registry, _acl, terms) = prepared(&mut scenario, recipe::refining(), 5);
    recipe::assert_facility(&terms, 300, 10);
    abort
}

#[test, expected_failure(abort_code = recipe::EOverflow)]
fun publish_rejects_quantity_overflow_at_advertised_maximum() {
    let mut scenario = ts::begin(@0xA);
    let (types, mut registry, acl) = setup(&mut scenario);
    publish_lines(
        &types,
        &mut registry,
        &acl,
        vector[recipe::line(10, 1)],
        vector[recipe::line(30, 18446744073709551615)],
        scenario.ctx(),
    );
    abort
}

#[test, expected_failure(abort_code = recipe::EOverflow)]
fun publish_rejects_duration_overflow_at_advertised_maximum() {
    let mut scenario = ts::begin(@0xA);
    let (types, mut registry, acl) = setup(&mut scenario);
    publish_standard(
        &types,
        &mut registry,
        &acl,
        recipe::refining(),
        18446744073709551615,
        scenario.ctx(),
    );
    abort
}
