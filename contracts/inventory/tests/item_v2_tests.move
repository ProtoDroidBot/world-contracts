#[test_only]
module inventory::item_v2_tests;

use core::admin_service::{Self, AdminACL};
use inventory::{item, item_type::{Self, ItemTypeRegistry}, item_v2};
use std::string;
use sui::{event, test_scenario as ts};

const ADMIN: address = @0xA;
const PLAYER: address = @0xB;

fun setup(scenario: &mut ts::Scenario): (ItemTypeRegistry, AdminACL) {
    admin_service::init_for_testing(scenario.ctx());
    ts::next_tx(scenario, ADMIN);
    let acl = ts::take_shared<AdminACL>(scenario);
    item_type::create(&acl, string::utf8(b"test"), scenario.ctx());
    ts::return_shared(acl);
    ts::next_tx(scenario, ADMIN);
    let acl = ts::take_shared<AdminACL>(scenario);
    let mut registry = ts::take_shared<ItemTypeRegistry>(scenario);
    item_type::register(&mut registry, &acl, 1, 2, true, scenario.ctx());
    item_type::register(&mut registry, &acl, 2, 3, true, scenario.ctx());
    item_type::register(&mut registry, &acl, 3, 1, false, scenario.ctx());
    (registry, acl)
}

#[test]
fun split_merge_aggregation_and_supply_events() {
    let mut scenario = ts::begin(ADMIN);
    let (registry, acl) = setup(&mut scenario);
    let job_id = object::id_from_address(@0x77);
    let mut first = item_v2::mint_production(&registry, 1, 10, job_id, scenario.ctx());
    let split = item_v2::split(&mut first, 4, scenario.ctx());
    item_v2::merge(&mut first, split);
    let second = item_v2::mint_production(&registry, 2, 5, job_id, scenario.ctx());
    let third = item_v2::split(&mut first, 3, scenario.ctx());
    let items = vector[second, third, first];
    let amounts = item_v2::aggregate(&registry, &items);
    assert!(item_v2::matches(&amounts, &vector[item_v2::amount(1, 10), item_v2::amount(2, 5)]));
    assert!(item_v2::total_volume(&registry, &amounts) == 35);
    assert!(event::events_by_type<item_v2::ProductionMinted>().length() == 2);
    items.do!(|item| item_v2::burn_production(item, job_id));
    assert!(event::events_by_type<item_v2::ProductionBurned>().length() == 3);
    assert!(event::events_by_type<item::ItemMinted>().is_empty());
    assert!(event::events_by_type<item::ItemBurned>().is_empty());
    ts::return_shared(registry);
    ts::return_shared(acl);
    scenario.end();
}

#[test, expected_failure(abort_code = item_type::ETypeExists)]
fun canonical_volume_cannot_change() {
    let mut scenario = ts::begin(ADMIN);
    let (mut registry, acl) = setup(&mut scenario);
    item_type::register(&mut registry, &acl, 1, 100, true, scenario.ctx());
    abort
}

#[test, expected_failure(abort_code = item_type::ENotAdmin)]
fun unprivileged_type_registration_aborts() {
    let mut scenario = ts::begin(ADMIN);
    let (registry, acl) = setup(&mut scenario);
    ts::return_shared(registry);
    ts::return_shared(acl);
    ts::next_tx(&mut scenario, PLAYER);
    let mut registry = ts::take_shared<ItemTypeRegistry>(&scenario);
    let acl = ts::take_shared<AdminACL>(&scenario);
    item_type::register(&mut registry, &acl, 4, 2, true, scenario.ctx());
    abort
}

#[test, expected_failure(abort_code = item_type::EProductionDisabled)]
fun ineligible_output_cannot_be_produced() {
    let mut scenario = ts::begin(ADMIN);
    let (registry, _acl) = setup(&mut scenario);
    let _item = item_v2::mint_production(
        &registry,
        3,
        1,
        object::id_from_address(@0x77),
        scenario.ctx(),
    );
    abort
}

#[test, expected_failure(abort_code = item_v2::EDuplicateType)]
fun duplicate_commitments_are_rejected() {
    item_v2::validate_amounts(&vector[item_v2::amount(1, 2), item_v2::amount(1, 3)]);
    abort
}

#[test, expected_failure(abort_code = item_v2::EInvalidAmount)]
fun zero_amount_is_rejected() {
    item_v2::amount(1, 0);
    abort
}

#[test, expected_failure(abort_code = item_v2::EOverflow)]
fun canonical_volume_overflow_is_rejected() {
    let mut scenario = ts::begin(ADMIN);
    let (registry, _acl) = setup(&mut scenario);
    item_v2::total_volume(&registry, &vector[item_v2::amount(1, 18446744073709551615)]);
    abort
}

#[test, expected_failure(abort_code = item_v2::EOverflow)]
fun aggregate_quantity_overflow_is_rejected() {
    let mut scenario = ts::begin(ADMIN);
    let (registry, _acl) = setup(&mut scenario);
    let items = vector[
        item_v2::from_storage(&registry, 1, 18446744073709551615, scenario.ctx()),
        item_v2::from_storage(&registry, 1, 1, scenario.ctx()),
    ];
    item_v2::aggregate(&registry, &items);
    abort
}

#[test, expected_failure(abort_code = item_v2::ETooManyItems)]
fun actual_stack_bound_precedes_aggregation() {
    let mut scenario = ts::begin(ADMIN);
    let (registry, _acl) = setup(&mut scenario);
    let items = vector::tabulate!(65, |_| item_v2::from_storage(&registry, 1, 1, scenario.ctx()));
    item_v2::aggregate(&registry, &items);
    abort
}

#[test, expected_failure(abort_code = item_v2::EWrongRegistry)]
fun same_tenant_and_type_in_another_catalog_is_not_trusted() {
    let mut scenario = ts::begin(ADMIN);
    let (registry, acl) = setup(&mut scenario);
    let original_id = object::id(&registry);
    let item = item_v2::from_storage(&registry, 1, 2, scenario.ctx());
    transfer::public_transfer(item, ADMIN);
    let other_id = item_type::create(&acl, string::utf8(b"test"), scenario.ctx());
    ts::return_shared(acl);
    ts::return_shared(registry);
    ts::next_tx(&mut scenario, ADMIN);
    let acl = ts::take_shared<AdminACL>(&scenario);
    let mut other = ts::take_shared_by_id<ItemTypeRegistry>(&scenario, other_id);
    item_type::register(&mut other, &acl, 1, 2, true, scenario.ctx());
    assert!(object::id(&other) != original_id);
    let item = ts::take_from_sender<item_v2::ItemV2>(&scenario);
    item_v2::aggregate(&other, &vector[item]);
    abort
}
