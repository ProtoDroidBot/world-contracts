/// Module-authored recovery and complete module indexing protect stored assets.
#[test_only]
module core::entity_module_lifecycle_tests;

use core::{
    access_cap::{Self, AccessCap},
    action,
    admin_service::{Self, AdminACL},
    entity::{Self, Entity},
    object_registry::ObjectRegistry,
    request,
    requirement,
    test_helpers::{setup, take_registry, take_acl, claim}
};
use std::{string, type_name};
use sui::{balance::{Self, Balance}, sui::SUI, test_scenario as ts};

// === Structs ===

public struct Counter has store { value: u64 }
public struct Other has store { value: u64 }
public struct Funded has store { escrow: Balance<SUI> }
public struct Recover() has drop;

// === Private Functions ===

fun prepared(scenario: &mut ts::Scenario): (Entity, ObjectRegistry, AdminACL) {
    setup(scenario);
    ts::next_tx(scenario, @0xA);
    let mut registry = take_registry(scenario);
    let acl = take_acl(scenario);
    let mut e = claim(&mut registry, &acl, 1, scenario.ctx());
    install_counter(&mut e, &acl, 7, scenario.ctx());
    (e, registry, acl)
}

fun install_counter(e: &mut Entity, acl: &AdminACL, slot: u64, ctx: &mut TxContext) {
    let mut req = e.install(
        slot,
        option::none(),
        Counter { value: 10 },
        1,
        internal::permit<Counter>(),
        ctx,
    );
    admin_service::verify_admin(&mut req, acl, ctx);
    e.complete_request(req);
}

fun recover(e: &mut Entity, slot: u64) {
    let mut req = e.begin_module_request(
        slot,
        requirement::from_config(option::some(slot), Recover()),
        internal::permit<Counter>(),
    );
    e.module_mut(&req, internal::permit<Counter>()).inner_mut().value = 0;
    let (_, frame) = req.take_next(internal::permit<Recover>());
    frame.destroy_empty_frame();
    e.complete_request(req);
}

// === Test Functions ===

#[test]
fun registry_tracks_every_slot_and_type() {
    let mut scenario = ts::begin(@0xA);
    let (mut e, registry, acl) = prepared(&mut scenario);
    assert!(e.module_count() == 1);
    install_counter(&mut e, &acl, 8, scenario.ctx());
    assert!(e.module_count() == 2);
    assert!(*e.installed_modules().get(&7) == type_name::with_original_ids<Counter>());
    assert!(*e.installed_modules().get(&8) == type_name::with_original_ids<Counter>());

    let (installed, mut req) = e.uninstall(7, internal::permit<Counter>(), scenario.ctx());
    admin_service::verify_admin(&mut req, &acl, scenario.ctx());
    e.complete_request(req);
    let Counter { value: _ } = installed.unwrap(internal::permit<Counter>());
    assert!(e.module_count() == 1);
    assert!(!e.installed_modules().contains(&7));
    assert!(e.installed_modules().contains(&8));

    entity::share(e);
    ts::return_shared(registry);
    ts::return_shared(acl);
    scenario.end();
}

#[test]
fun recovery_remains_available_after_owner_disables_action() {
    let mut scenario = ts::begin(@0xA);
    let (mut e, registry, acl) = prepared(&mut scenario);
    let mut req = e.mint_access(@0xB, false, scenario.ctx());
    admin_service::verify_admin(&mut req, &acl, scenario.ctx());
    e.complete_request(req);
    entity::share(e);
    ts::return_shared(registry);
    ts::return_shared(acl);

    ts::next_tx(&mut scenario, @0xB);
    let mut e = ts::take_shared<Entity>(&scenario);
    let cap = ts::take_from_sender<AccessCap>(&scenario);
    let mut req = e.enable_action(string::utf8(b"ordinary"), action::new(vector[]), scenario.ctx());
    access_cap::verify(&mut req, &cap);
    e.complete_request(req);
    let mut req = e.disable_action(string::utf8(b"ordinary"), scenario.ctx());
    access_cap::verify(&mut req, &cap);
    e.complete_request(req);
    ts::return_to_sender(&scenario, cap);
    ts::return_shared(e);

    ts::next_tx(&mut scenario, @0xC);
    let mut e = ts::take_shared<Entity>(&scenario);
    recover(&mut e, 7);
    assert!(e.module_ref(7, internal::permit<Counter>()).inner().value == 0);
    ts::return_shared(e);
    scenario.end();
}

#[test, expected_failure(abort_code = entity::EWrongModule)]
fun module_request_rejects_another_installed_slot() {
    let mut scenario = ts::begin(@0xA);
    let (mut e, _registry, acl) = prepared(&mut scenario);
    install_counter(&mut e, &acl, 8, scenario.ctx());
    let _req = e.begin_module_request(
        7,
        requirement::from_config(option::some(8), Recover()),
        internal::permit<Counter>(),
    );
    abort
}

#[test, expected_failure(abort_code = entity::EWrongModule)]
fun module_request_rejects_unscoped_requirement() {
    let mut scenario = ts::begin(@0xA);
    let (mut e, _registry, _acl) = prepared(&mut scenario);
    let _req = e.begin_module_request(
        7,
        requirement::from_config(option::none(), Recover()),
        internal::permit<Counter>(),
    );
    abort
}

#[test, expected_failure(abort_code = entity::EModuleMissing)]
fun module_request_rejects_wrong_state_type() {
    let mut scenario = ts::begin(@0xA);
    let (mut e, _registry, _acl) = prepared(&mut scenario);
    let _req = e.begin_module_request(
        7,
        requirement::from_config(option::some(7), Recover()),
        internal::permit<Other>(),
    );
    abort
}

#[test, expected_failure(abort_code = entity::EModuleMissing)]
fun module_request_rejects_uninstalled_slot() {
    let mut scenario = ts::begin(@0xA);
    let (mut e, _registry, _acl) = prepared(&mut scenario);
    recover(&mut e, 8);
    abort
}

#[test, expected_failure(abort_code = entity::ELocked)]
fun module_request_rejects_nested_request() {
    let mut scenario = ts::begin(@0xA);
    let (mut e, _registry, _acl) = prepared(&mut scenario);
    let _req = e.begin_module_request(
        7,
        requirement::from_config(option::some(7), Recover()),
        internal::permit<Counter>(),
    );
    recover(&mut e, 7);
    abort
}

#[test, expected_failure(abort_code = request::ERequestNotComplete)]
fun module_request_cannot_skip_its_handler() {
    let mut scenario = ts::begin(@0xA);
    let (mut e, _registry, _acl) = prepared(&mut scenario);
    let req = e.begin_module_request(
        7,
        requirement::from_config(option::some(7), Recover()),
        internal::permit<Counter>(),
    );
    e.complete_request(req);
    abort
}

#[test, expected_failure(abort_code = entity::EModulesInstalled)]
fun deletion_rejects_nonempty_installed_module() {
    let mut scenario = ts::begin(@0xA);
    let (mut e, _registry, _acl) = prepared(&mut scenario);
    let (_req, _ticket) = e.request_delete();
    abort
}

#[test, expected_failure(abort_code = entity::EModulesInstalled)]
fun deletion_rejects_funded_module() {
    let mut scenario = ts::begin(@0xA);
    setup(&mut scenario);
    ts::next_tx(&mut scenario, @0xA);
    let mut registry = take_registry(&scenario);
    let acl = take_acl(&scenario);
    let mut e = claim(&mut registry, &acl, 1, scenario.ctx());
    let funded = Funded { escrow: balance::create_for_testing<SUI>(100) };
    let mut req = e.install(
        9,
        option::none(),
        funded,
        1,
        internal::permit<Funded>(),
        scenario.ctx(),
    );
    admin_service::verify_admin(&mut req, &acl, scenario.ctx());
    e.complete_request(req);
    let (_req, _ticket) = e.request_delete();
    abort
}

#[test, expected_failure(abort_code = entity::EWrongVersion)]
fun legacy_entity_cannot_start_module_request() {
    let mut scenario = ts::begin(@0xA);
    let (mut e, _registry, _acl) = prepared(&mut scenario);
    e.set_version_for_testing(1);
    recover(&mut e, 7);
    abort
}

#[test, expected_failure(abort_code = entity::EWrongVersion)]
fun legacy_entity_cannot_request_deletion() {
    let mut scenario = ts::begin(@0xA);
    let (mut e, _registry, _acl) = prepared(&mut scenario);
    e.set_version_for_testing(1);
    let (_req, _ticket) = e.request_delete();
    abort
}

#[test, expected_failure(abort_code = entity::EWrongVersion)]
fun legacy_entity_cannot_install_new_module() {
    let mut scenario = ts::begin(@0xA);
    let (mut e, _registry, acl) = prepared(&mut scenario);
    e.set_version_for_testing(1);
    install_counter(&mut e, &acl, 8, scenario.ctx());
    abort
}

#[test, expected_failure(abort_code = entity::EWrongVersion)]
fun legacy_entity_cannot_uninstall_module() {
    let mut scenario = ts::begin(@0xA);
    let (mut e, _registry, _acl) = prepared(&mut scenario);
    e.set_version_for_testing(1);
    let (_module, _req) = e.uninstall(7, internal::permit<Counter>(), scenario.ctx());
    abort
}
