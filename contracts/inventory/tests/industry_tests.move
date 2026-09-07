/// Public industry handlers preserve job obligations across assembly policies.
#[test_only]
module inventory::industry_tests;

use core::{
    access_cap::{Self, AccessCap},
    action,
    admin_service::{Self, AdminACL},
    entity::{Self, Entity},
    location_service,
    object_registry::{Self, ObjectRegistry}
};
use inventory::{
    industry::{Self, FacilityConfig},
    industry_job,
    item_type::ItemTypeRegistry,
    item_v2::{Self, ItemV2},
    recipe::{Self, RecipeRegistry, RecipeRevision},
    recipe_tests
};
use std::string;
use sui::{clock::{Self, Clock}, coin::{Self, Coin}, event, sui::SUI, test_scenario as ts};

// === Constants ===

const SLOT: u64 = 7;
const ACTION: vector<u8> = b"industry";

// === Structs ===

public struct Fixture {
    assembly: Entity,
    types: ItemTypeRegistry,
    recipes: RecipeRegistry,
    acl: AdminACL,
    terms: RecipeRevision,
    cap: AccessCap,
}

// === Private Functions ===

fun config(lanes: u64, max_jobs: u64, input: u64, output: u64): FacilityConfig {
    industry::facility_config(100, 2, vector[0, 1], lanes, max_jobs, input, output)
}

fun new_entity(
    registry: &mut ObjectRegistry,
    acl: &AdminACL,
    game_id: u64,
    recipient: address,
    ctx: &mut TxContext,
): Entity {
    let (mut entity, mut req) = entity::new(registry, game_id, string::utf8(b"industry-test"));
    admin_service::verify_admin(&mut req, acl, ctx);
    entity.complete_request(req);
    let mut req = entity.mint_access(recipient, false, ctx);
    admin_service::verify_admin(&mut req, acl, ctx);
    entity.complete_request(req);
    entity
}

fun prepared(
    scenario: &mut ts::Scenario,
    config: FacilityConfig,
    kind: u8,
    action_max_batches: u64,
): Fixture {
    object_registry::init_for_testing(scenario.ctx());
    let (types, recipes, acl, terms) = recipe_tests::prepared(scenario, kind, 5);
    let mut objects = ts::take_shared<ObjectRegistry>(scenario);
    let mut assembly = new_entity(&mut objects, &acl, 1, @0xA, scenario.ctx());
    let mut req = industry::install(
        &mut assembly,
        &types,
        &recipes,
        &acl,
        config,
        SLOT,
        option::none(),
        scenario.ctx(),
    );
    admin_service::verify_admin(&mut req, &acl, scenario.ctx());
    assembly.complete_request(req);
    let assembly_id = assembly.id();
    let terms_id = object::id(&terms);
    let customer = new_entity(&mut objects, &acl, 2, @0xB, scenario.ctx());
    entity::share(customer);
    entity::share(assembly);
    ts::return_shared(objects);
    recipe_tests::return_all(types, recipes, acl, terms);

    ts::next_tx(scenario, @0xA);
    let mut f = take(scenario, assembly_id, terms_id);
    // Deliberately no Caller/Owner requirement: start_job itself must authenticate.
    let act = action::new(vector[industry::start_requirement(SLOT, action_max_batches)]);
    let mut req = f.assembly.enable_action(string::utf8(ACTION), act, scenario.ctx());
    access_cap::verify(&mut req, &f.cap);
    f.assembly.complete_request(req);
    f
}

fun standard(scenario: &mut ts::Scenario): Fixture {
    prepared(scenario, config(2, 10, 1000, 1000), recipe::refining(), 100)
}

fun take(scenario: &ts::Scenario, assembly_id: ID, terms_id: ID): Fixture {
    Fixture {
        assembly: ts::take_shared_by_id<Entity>(scenario, assembly_id),
        types: ts::take_shared<ItemTypeRegistry>(scenario),
        recipes: ts::take_shared<RecipeRegistry>(scenario),
        acl: ts::take_shared<AdminACL>(scenario),
        terms: ts::take_immutable_by_id<RecipeRevision>(scenario, terms_id),
        cap: ts::take_from_sender<AccessCap>(scenario),
    }
}

fun park(f: Fixture, scenario: &ts::Scenario): (ID, ID) {
    let Fixture { assembly, types, recipes, acl, terms, cap } = f;
    let assembly_id = assembly.id();
    let terms_id = object::id(&terms);
    ts::return_shared(assembly);
    recipe_tests::return_all(types, recipes, acl, terms);
    ts::return_to_sender(scenario, cap);
    (assembly_id, terms_id)
}

fun both_recipes(scenario: &mut ts::Scenario, config: FacilityConfig): (Fixture, RecipeRevision) {
    let mut f = prepared(scenario, config, recipe::refining(), 100);
    let second_id = publish_other(&mut f, scenario.ctx());
    let (assembly_id, first_id) = park(f, scenario);
    ts::next_tx(scenario, @0xA);
    (
        take(scenario, assembly_id, first_id),
        ts::take_immutable_by_id<RecipeRevision>(scenario, second_id),
    )
}

fun inputs(types: &ItemTypeRegistry, batches: u64, ctx: &mut TxContext): vector<ItemV2> {
    vector[
        item_v2::from_storage(types, 20, 3 * batches, ctx),
        item_v2::from_storage(types, 10, batches, ctx),
        item_v2::from_storage(types, 10, batches, ctx),
    ]
}

fun start(
    f: &mut Fixture,
    inputs: vector<ItemV2>,
    payment: &mut Coin<SUI>,
    batches: u64,
    max_fee: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): ID {
    let mut req = f.assembly.interact(string::utf8(ACTION), vector[], ctx);
    location_service::verify_proximity(&mut req, vector[]);
    let id = industry::start_job(
        &mut f.assembly,
        &mut req,
        &f.types,
        &f.recipes,
        &f.terms,
        &f.cap,
        payment,
        inputs,
        batches,
        max_fee,
        clock,
        ctx,
    );
    f.assembly.complete_request(req);
    id
}

fun start_funded(
    f: &mut Fixture,
    payment: &mut Coin<SUI>,
    batches: u64,
    max_fee: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): ID {
    let items = inputs(&f.types, batches, ctx);
    start(f, items, payment, batches, max_fee, clock, ctx)
}

fun start_other(
    f: &mut Fixture,
    terms: &RecipeRevision,
    payment: &mut Coin<SUI>,
    clock: &Clock,
    ctx: &mut TxContext,
): ID {
    let items = inputs(&f.types, 1, ctx);
    let mut req = f.assembly.interact(string::utf8(ACTION), vector[], ctx);
    location_service::verify_proximity(&mut req, vector[]);
    let id = industry::start_job(
        &mut f.assembly,
        &mut req,
        &f.types,
        &f.recipes,
        terms,
        &f.cap,
        payment,
        items,
        1,
        0,
        clock,
        ctx,
    );
    f.assembly.complete_request(req);
    id
}

fun assert_counters(f: &Fixture, running: u64, input: u64, reserved: u64, output: u64, jobs: u64) {
    let state = industry::industry(&f.assembly, SLOT);
    assert!(state.running() == running);
    assert!(state.input_used() == input);
    assert!(state.output_reserved() == reserved);
    assert!(state.output_used() == output);
    assert!(state.jobs().length() == jobs);
}

fun open_to_customers(f: &mut Fixture, fee: u64, ctx: &mut TxContext) {
    industry::set_policy(
        &mut f.assembly,
        &f.cap,
        SLOT,
        industry::policy(false, false, vector[0, 1], vector[], fee, @0xF),
        ctx,
    );
}

fun publish_other(f: &mut Fixture, ctx: &mut TxContext): ID {
    recipe_tests::publish_standard(
        &f.types,
        &mut f.recipes,
        &f.acl,
        recipe::manufacturing(),
        5,
        ctx,
    )
}

fun settle(f: &mut Fixture, job: ID, clock: &Clock, ctx: &mut TxContext) {
    industry::settle_job(&mut f.assembly, &f.types, SLOT, job, clock, ctx);
}

fun claim(f: &mut Fixture, job: ID, ctx: &mut TxContext): vector<ItemV2> {
    industry::claim_outputs(&mut f.assembly, &f.cap, SLOT, job, ctx)
}

fun cancel(f: &mut Fixture, job: ID, clock: &Clock, ctx: &mut TxContext) {
    industry::cancel_job(&mut f.assembly, &f.cap, SLOT, job, clock, ctx);
}

fun refund(f: &mut Fixture, job: ID, ctx: &mut TxContext): (vector<ItemV2>, Coin<SUI>) {
    industry::claim_refund(&mut f.assembly, &f.cap, SLOT, job, ctx)
}

fun limits(
    f: &mut Fixture,
    lanes: u64,
    max_jobs: u64,
    input: u64,
    output: u64,
    ctx: &mut TxContext,
) {
    industry::set_limits(
        &mut f.assembly,
        &f.types,
        &f.acl,
        SLOT,
        lanes,
        max_jobs,
        input,
        output,
        ctx,
    );
}

fun set_policy(f: &mut Fixture, policy: industry::Policy, ctx: &mut TxContext) {
    industry::set_policy(&mut f.assembly, &f.cap, SLOT, policy, ctx);
}

fun disable_recipe(f: &mut Fixture, ctx: &mut TxContext) {
    recipe::set_enabled(&mut f.recipes, &f.acl, object::id(&f.terms), false, ctx);
}

// === Test Functions ===

#[test]
fun both_kinds_share_lanes_capacity_and_the_complete_claim_lifecycle() {
    let mut scenario = ts::begin(@0xA);
    let (mut f, manufacturing) = both_recipes(&mut scenario, config(2, 10, 26, 242));
    let mut clock = clock::create_for_testing(scenario.ctx());
    let mut payment = coin::mint_for_testing<SUI>(0, scenario.ctx());
    let refined = start_funded(&mut f, &mut payment, 1, 0, &clock, scenario.ctx());
    let manufactured = start_other(&mut f, &manufacturing, &mut payment, &clock, scenario.ctx());
    assert_counters(&f, 2, 26, 242, 0, 2);
    assert!(industry_job::kind(industry::job(&f.assembly, SLOT, refined)) == recipe::refining());
    assert!(
        industry_job::kind(industry::job(&f.assembly, SLOT, manufactured)) == recipe::manufacturing(),
    );
    assert!(event::events_by_type<industry::IndustryJobStarted>().length() == 2);

    clock.set_for_testing(5);
    settle(&mut f, refined, &clock, scenario.ctx());
    assert_counters(&f, 1, 13, 121, 121, 2);
    let refined_items = claim(&mut f, refined, scenario.ctx());
    assert!(
        item_v2::aggregate(&f.types, &refined_items) == vector[item_v2::amount(30, 4), item_v2::amount(40, 5), item_v2::amount(50, 6)],
    );
    item_v2::transfer_all(refined_items, @0xA);
    assert_counters(&f, 1, 13, 121, 0, 1);
    settle(&mut f, manufactured, &clock, scenario.ctx());
    assert_counters(&f, 0, 0, 0, 121, 1);
    let manufactured_items = claim(&mut f, manufactured, scenario.ctx());
    assert!(
        item_v2::aggregate(&f.types, &manufactured_items) == vector[item_v2::amount(30, 4), item_v2::amount(40, 5), item_v2::amount(50, 6)],
    );
    item_v2::transfer_all(manufactured_items, @0xA);
    assert_counters(&f, 0, 0, 0, 0, 0);
    assert!(event::events_by_type<industry::IndustryJobCompleted>().length() == 2);
    assert!(event::events_by_type<industry::IndustryOutputsClaimed>().length() == 2);
    let mut req = industry::uninstall(&mut f.assembly, SLOT, scenario.ctx());
    admin_service::verify_admin(&mut req, &f.acl, scenario.ctx());
    f.assembly.complete_request(req);
    assert!(f.assembly.module_count() == 0);
    assert!(coin::burn_for_testing(payment) == 0);
    clock::destroy_for_testing(clock);
    ts::return_immutable(manufacturing);
    park(f, &scenario);
    scenario.end();
}

#[test]
fun customers_recover_after_owner_disables_actions_and_changes_fee_policy() {
    let mut scenario = ts::begin(@0xA);
    let mut f = standard(&mut scenario);
    open_to_customers(&mut f, 3, scenario.ctx());
    let (assembly_id, terms_id) = park(f, &scenario);
    ts::next_tx(&mut scenario, @0xB);
    let mut f = take(&scenario, assembly_id, terms_id);
    let clock = clock::create_for_testing(scenario.ctx());
    let mut payment = coin::mint_for_testing<SUI>(100, scenario.ctx());
    let completing = start_funded(&mut f, &mut payment, 1, 3, &clock, scenario.ctx());
    let cancelling = start_funded(&mut f, &mut payment, 1, 3, &clock, scenario.ctx());
    assert!(
        industry_job::beneficiary(industry::job(&f.assembly, SLOT, completing)) == f.cap.entity(),
    );
    assert!(f.cap.entity() != assembly_id);
    assert_counters(&f, 2, 26, 242, 0, 2);
    assert!(coin::burn_for_testing(payment) == 94);
    clock::destroy_for_testing(clock);
    park(f, &scenario);

    ts::next_tx(&mut scenario, @0xA);
    let mut f = take(&scenario, assembly_id, terms_id);
    let mut req = f.assembly.disable_action(string::utf8(ACTION), scenario.ctx());
    access_cap::verify(&mut req, &f.cap);
    f.assembly.complete_request(req);
    set_policy(
        &mut f,
        industry::policy(true, true, vector[0, 1], vector[], 99, @0xC),
        scenario.ctx(),
    );
    park(f, &scenario);

    ts::next_tx(&mut scenario, @0xB);
    let mut f = take(&scenario, assembly_id, terms_id);
    let mut clock = clock::create_for_testing(scenario.ctx());
    cancel(&mut f, cancelling, &clock, scenario.ctx());
    assert_counters(&f, 1, 26, 121, 0, 2);
    let (refunds, fee) = refund(&mut f, cancelling, scenario.ctx());
    assert!(
        item_v2::matches(
            &item_v2::aggregate(&f.types, &refunds),
            &vector[item_v2::amount(10, 2), item_v2::amount(20, 3)],
        ),
    );
    assert!(coin::burn_for_testing(fee) == 3);
    item_v2::transfer_all(refunds, @0xB);
    assert_counters(&f, 1, 13, 121, 0, 1);

    clock.set_for_testing(5);
    settle(&mut f, completing, &clock, scenario.ctx());
    assert_counters(&f, 0, 0, 0, 121, 1);
    let outputs = claim(&mut f, completing, scenario.ctx());
    assert!(outputs.length() == 3);
    item_v2::transfer_all(outputs, @0xB);
    assert_counters(&f, 0, 0, 0, 0, 0);
    clock::destroy_for_testing(clock);
    park(f, &scenario);

    // Fee recipient and amount were snapshotted when the job was accepted.
    ts::next_tx(&mut scenario, @0xF);
    let fee = ts::take_from_sender<Coin<SUI>>(&scenario);
    assert!(coin::burn_for_testing(fee) == 3);
    scenario.end();
}

#[test]
fun cancellation_releases_lane_and_reservation_until_full_refund_drains_input() {
    let mut scenario = ts::begin(@0xA);
    let mut f = prepared(&mut scenario, config(1, 2, 26, 121), recipe::refining(), 100);
    let clock = clock::create_for_testing(scenario.ctx());
    let mut payment = coin::mint_for_testing<SUI>(0, scenario.ctx());
    let first = start_funded(&mut f, &mut payment, 1, 0, &clock, scenario.ctx());
    cancel(&mut f, first, &clock, scenario.ctx());
    assert_counters(&f, 0, 13, 0, 0, 1);
    let second = start_funded(&mut f, &mut payment, 1, 0, &clock, scenario.ctx());
    assert_counters(&f, 1, 26, 121, 0, 2);
    let (refunds, fee) = refund(&mut f, first, scenario.ctx());
    item_v2::transfer_all(refunds, @0xA);
    coin::destroy_zero(fee);
    assert_counters(&f, 1, 13, 121, 0, 1);
    cancel(&mut f, second, &clock, scenario.ctx());
    let (refunds, fee) = refund(&mut f, second, scenario.ctx());
    item_v2::transfer_all(refunds, @0xA);
    coin::destroy_zero(fee);
    assert_counters(&f, 0, 0, 0, 0, 0);
    limits(&mut f, 1, 1, 1, 1, scenario.ctx());
    coin::destroy_zero(payment);
    clock::destroy_for_testing(clock);
    park(f, &scenario);
    scenario.end();
}

#[test, expected_failure(abort_code = industry::ENoLane)]
fun manufacturing_cannot_bypass_a_lane_occupied_by_refining() {
    let mut scenario = ts::begin(@0xA);
    let (mut f, manufacturing) = both_recipes(&mut scenario, config(1, 10, 1000, 1000));
    let clock = clock::create_for_testing(scenario.ctx());
    let mut payment = coin::mint_for_testing<SUI>(0, scenario.ctx());
    start_funded(&mut f, &mut payment, 1, 0, &clock, scenario.ctx());
    start_other(&mut f, &manufacturing, &mut payment, &clock, scenario.ctx());
    abort
}

#[test, expected_failure(abort_code = industry::EOverCapacity)]
fun reservations_must_fit_every_output_line() {
    let mut scenario = ts::begin(@0xA);
    let mut f = prepared(&mut scenario, config(2, 10, 1000, 120), recipe::refining(), 100);
    let clock = clock::create_for_testing(scenario.ctx());
    let mut payment = coin::mint_for_testing<SUI>(0, scenario.ctx());
    start_funded(&mut f, &mut payment, 1, 0, &clock, scenario.ctx());
    abort
}

#[test, expected_failure(abort_code = industry::EOverCapacity)]
fun completed_unclaimed_outputs_compete_with_new_reservations() {
    let mut scenario = ts::begin(@0xA);
    let mut f = prepared(&mut scenario, config(2, 10, 1000, 200), recipe::refining(), 100);
    let mut clock = clock::create_for_testing(scenario.ctx());
    let mut payment = coin::mint_for_testing<SUI>(0, scenario.ctx());
    let first = start_funded(&mut f, &mut payment, 1, 0, &clock, scenario.ctx());
    clock.set_for_testing(5);
    settle(&mut f, first, &clock, scenario.ctx());
    assert_counters(&f, 0, 0, 0, 121, 1);
    start_funded(&mut f, &mut payment, 1, 0, &clock, scenario.ctx());
    abort
}

#[test, expected_failure(abort_code = industry::EOverCapacity)]
fun all_running_inputs_count_toward_capacity() {
    let mut scenario = ts::begin(@0xA);
    let mut f = prepared(&mut scenario, config(2, 10, 20, 1000), recipe::refining(), 100);
    let clock = clock::create_for_testing(scenario.ctx());
    let mut payment = coin::mint_for_testing<SUI>(0, scenario.ctx());
    start_funded(&mut f, &mut payment, 1, 0, &clock, scenario.ctx());
    start_funded(&mut f, &mut payment, 1, 0, &clock, scenario.ctx());
    abort
}

#[test, expected_failure(abort_code = industry::EOverCapacity)]
fun unclaimed_refunds_continue_to_occupy_input_capacity() {
    let mut scenario = ts::begin(@0xA);
    let mut f = prepared(&mut scenario, config(1, 10, 20, 1000), recipe::refining(), 100);
    let clock = clock::create_for_testing(scenario.ctx());
    let mut payment = coin::mint_for_testing<SUI>(0, scenario.ctx());
    let first = start_funded(&mut f, &mut payment, 1, 0, &clock, scenario.ctx());
    cancel(&mut f, first, &clock, scenario.ctx());
    start_funded(&mut f, &mut payment, 1, 0, &clock, scenario.ctx());
    abort
}

#[test, expected_failure(abort_code = industry::EJobLimit)]
fun cancelled_unclaimed_jobs_still_count_toward_job_limit() {
    let mut scenario = ts::begin(@0xA);
    let mut f = prepared(&mut scenario, config(1, 1, 1000, 1000), recipe::refining(), 100);
    let clock = clock::create_for_testing(scenario.ctx());
    let mut payment = coin::mint_for_testing<SUI>(0, scenario.ctx());
    let first = start_funded(&mut f, &mut payment, 1, 0, &clock, scenario.ctx());
    cancel(&mut f, first, &clock, scenario.ctx());
    start_funded(&mut f, &mut payment, 1, 0, &clock, scenario.ctx());
    abort
}

#[test, expected_failure(abort_code = industry_job::EInputMismatch)]
fun start_rejects_missing_material_even_when_capacity_and_policy_allow_it() {
    let mut scenario = ts::begin(@0xA);
    let mut f = standard(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let mut payment = coin::mint_for_testing<SUI>(0, scenario.ctx());
    let items = vector[item_v2::from_storage(&f.types, 10, 2, scenario.ctx())];
    start(&mut f, items, &mut payment, 1, 0, &clock, scenario.ctx());
    abort
}

#[test, expected_failure(abort_code = industry::ENotAuthorized)]
fun nonowner_is_rejected_even_when_start_action_has_no_access_requirement() {
    let mut scenario = ts::begin(@0xA);
    let f = standard(&mut scenario);
    let (assembly_id, terms_id) = park(f, &scenario);
    ts::next_tx(&mut scenario, @0xB);
    let mut f = take(&scenario, assembly_id, terms_id);
    let clock = clock::create_for_testing(scenario.ctx());
    let mut payment = coin::mint_for_testing<SUI>(0, scenario.ctx());
    start_funded(&mut f, &mut payment, 1, 0, &clock, scenario.ctx());
    abort
}

#[test, expected_failure(abort_code = industry::ENotAuthorized)]
fun assembly_owner_cannot_claim_customer_outputs() {
    let mut scenario = ts::begin(@0xA);
    let mut f = standard(&mut scenario);
    open_to_customers(&mut f, 0, scenario.ctx());
    let (assembly_id, terms_id) = park(f, &scenario);
    ts::next_tx(&mut scenario, @0xB);
    let mut f = take(&scenario, assembly_id, terms_id);
    let clock = clock::create_for_testing(scenario.ctx());
    let mut payment = coin::mint_for_testing<SUI>(0, scenario.ctx());
    let job = start_funded(&mut f, &mut payment, 1, 0, &clock, scenario.ctx());
    coin::destroy_zero(payment);
    clock::destroy_for_testing(clock);
    park(f, &scenario);
    ts::next_tx(&mut scenario, @0xA);
    let mut f = take(&scenario, assembly_id, terms_id);
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock.set_for_testing(5);
    settle(&mut f, job, &clock, scenario.ctx());
    let _outputs = claim(&mut f, job, scenario.ctx());
    abort
}

#[test, expected_failure(abort_code = industry::EFeeTooHigh)]
fun caller_maximum_fee_prevents_a_more_expensive_start() {
    let mut scenario = ts::begin(@0xA);
    let mut f = standard(&mut scenario);
    open_to_customers(&mut f, 7, scenario.ctx());
    let clock = clock::create_for_testing(scenario.ctx());
    let mut payment = coin::mint_for_testing<SUI>(100, scenario.ctx());
    start_funded(&mut f, &mut payment, 2, 13, &clock, scenario.ctx());
    abort
}

#[test, expected_failure(abort_code = industry::EInvalidConfig)]
fun limits_cannot_reduce_input_below_funded_escrow() {
    let mut scenario = ts::begin(@0xA);
    let mut f = standard(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let mut payment = coin::mint_for_testing<SUI>(0, scenario.ctx());
    start_funded(&mut f, &mut payment, 1, 0, &clock, scenario.ctx());
    limits(&mut f, 2, 10, 12, 1000, scenario.ctx());
    abort
}

#[test, expected_failure(abort_code = industry::EInvalidConfig)]
fun limits_cannot_reduce_output_below_existing_reservations() {
    let mut scenario = ts::begin(@0xA);
    let mut f = standard(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let mut payment = coin::mint_for_testing<SUI>(0, scenario.ctx());
    start_funded(&mut f, &mut payment, 1, 0, &clock, scenario.ctx());
    limits(&mut f, 2, 10, 1000, 120, scenario.ctx());
    abort
}

#[test, expected_failure(abort_code = industry::EOutstandingJobs)]
fun uninstall_cannot_orphan_funded_jobs() {
    let mut scenario = ts::begin(@0xA);
    let mut f = standard(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let mut payment = coin::mint_for_testing<SUI>(0, scenario.ctx());
    start_funded(&mut f, &mut payment, 1, 0, &clock, scenario.ctx());
    let _req = industry::uninstall(&mut f.assembly, SLOT, scenario.ctx());
    abort
}

#[test, expected_failure(abort_code = industry::EKindNotAllowed)]
fun facility_kind_restriction_is_enforced_inside_start() {
    let mut scenario = ts::begin(@0xA);
    let restricted = industry::facility_config(100, 2, vector[0], 2, 10, 1000, 1000);
    let mut f = prepared(&mut scenario, restricted, recipe::manufacturing(), 100);
    let clock = clock::create_for_testing(scenario.ctx());
    let mut payment = coin::mint_for_testing<SUI>(0, scenario.ctx());
    start_funded(&mut f, &mut payment, 1, 0, &clock, scenario.ctx());
    abort
}

#[test, expected_failure(abort_code = industry::EKindNotAllowed)]
fun owner_policy_can_restrict_supported_process_kinds() {
    let mut scenario = ts::begin(@0xA);
    let mut f = prepared(&mut scenario, config(2, 10, 1000, 1000), recipe::manufacturing(), 100);
    set_policy(&mut f, industry::policy(false, true, vector[0], vector[], 0, @0xA), scenario.ctx());
    let clock = clock::create_for_testing(scenario.ctx());
    let mut payment = coin::mint_for_testing<SUI>(0, scenario.ctx());
    start_funded(&mut f, &mut payment, 1, 0, &clock, scenario.ctx());
    abort
}

#[test, expected_failure(abort_code = industry::ERecipeNotAllowed)]
fun allowed_recipe_policy_excludes_other_revisions() {
    let mut scenario = ts::begin(@0xA);
    let mut f = standard(&mut scenario);
    let excluded = object::id_from_address(@0x99);
    set_policy(
        &mut f,
        industry::policy(false, true, vector[0, 1], vector[excluded], 0, @0xA),
        scenario.ctx(),
    );
    let clock = clock::create_for_testing(scenario.ctx());
    let mut payment = coin::mint_for_testing<SUI>(0, scenario.ctx());
    start_funded(&mut f, &mut payment, 1, 0, &clock, scenario.ctx());
    abort
}

#[test, expected_failure(abort_code = recipe::ERecipeDisabled)]
fun disabled_governed_recipe_cannot_start_on_an_open_facility() {
    let mut scenario = ts::begin(@0xA);
    let mut f = standard(&mut scenario);
    disable_recipe(&mut f, scenario.ctx());
    let clock = clock::create_for_testing(scenario.ctx());
    let mut payment = coin::mint_for_testing<SUI>(0, scenario.ctx());
    start_funded(&mut f, &mut payment, 1, 0, &clock, scenario.ctx());
    abort
}

#[test, expected_failure(abort_code = industry::EBatchLimit)]
fun action_batch_limit_applies_before_recipe_limit() {
    let mut scenario = ts::begin(@0xA);
    let mut f = prepared(&mut scenario, config(2, 10, 1000, 1000), recipe::refining(), 2);
    let clock = clock::create_for_testing(scenario.ctx());
    let mut payment = coin::mint_for_testing<SUI>(0, scenario.ctx());
    start_funded(&mut f, &mut payment, 3, 0, &clock, scenario.ctx());
    abort
}

#[test, expected_failure(abort_code = industry::EPaused)]
fun paused_policy_rejects_new_jobs() {
    let mut scenario = ts::begin(@0xA);
    let mut f = standard(&mut scenario);
    set_policy(
        &mut f,
        industry::policy(true, true, vector[0, 1], vector[], 0, @0xA),
        scenario.ctx(),
    );
    let clock = clock::create_for_testing(scenario.ctx());
    let mut payment = coin::mint_for_testing<SUI>(0, scenario.ctx());
    start_funded(&mut f, &mut payment, 1, 0, &clock, scenario.ctx());
    abort
}
