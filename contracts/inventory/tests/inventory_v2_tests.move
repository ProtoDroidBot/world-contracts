#[test_only]
module inventory::inventory_v2_tests;

use core::{
    access_cap::{Self, AccessCap},
    action,
    admin_service::{Self, AdminACL},
    entity::{Self, Entity},
    location_service,
    test_helpers::{claim, setup, take_acl, take_registry}
};
use inventory::{inventory_v2, item_type::{Self, ItemTypeRegistry}, item_v2};
use std::string;
use sui::{event, test_scenario as ts};

const ADMIN: address = @0xA;
const OWNER: address = @0xB;
const SLOT: u64 = 71;

fun setup_storage(
    scenario: &mut ts::Scenario,
    capacity: u64,
): (Entity, ItemTypeRegistry, AdminACL) {
    setup(scenario);
    ts::next_tx(scenario, ADMIN);
    let acl = take_acl(scenario);
    item_type::create(&acl, string::utf8(b"test"), scenario.ctx());
    ts::return_shared(acl);
    ts::next_tx(scenario, ADMIN);
    let acl = take_acl(scenario);
    let mut catalog = ts::take_shared<ItemTypeRegistry>(scenario);
    item_type::register(&mut catalog, &acl, 1, 2, true, scenario.ctx());
    item_type::register(&mut catalog, &acl, 2, 3, true, scenario.ctx());
    let mut registry = take_registry(scenario);
    let mut entity = claim(&mut registry, &acl, 1, scenario.ctx());
    let mut req = inventory_v2::install(
        &mut entity,
        &catalog,
        &acl,
        SLOT,
        1,
        option::none(),
        capacity,
        capacity,
        scenario.ctx(),
    );
    admin_service::verify_admin(&mut req, &acl, scenario.ctx());
    entity.complete_request(req);
    let mut req = entity.mint_access(OWNER, true, scenario.ctx());
    admin_service::verify_admin(&mut req, &acl, scenario.ctx());
    entity.complete_request(req);
    ts::return_shared(registry);
    (entity, catalog, acl)
}

fun import(
    scenario: &mut ts::Scenario,
    entity: &mut Entity,
    catalog: &mut ItemTypeRegistry,
    acl: &AdminACL,
    transfer_id: vector<u8>,
    amounts: vector<item_v2::ItemAmount>,
) {
    let beneficiary = entity.id();
    inventory_v2::import_items(
        entity,
        catalog,
        acl,
        SLOT,
        beneficiary,
        transfer_id,
        amounts,
        scenario.ctx(),
    );
}

#[test]
fun protected_withdrawal_and_export_need_no_owner_actions() {
    let mut scenario = ts::begin(ADMIN);
    let (mut entity, mut catalog, acl) = setup_storage(&mut scenario, 1000);
    let entity_id = entity.id();
    import(
        &mut scenario,
        &mut entity,
        &mut catalog,
        &acl,
        b"transfer-1",
        vector[item_v2::amount(1, 10), item_v2::amount(2, 5)],
    );
    assert!(item_type::was_imported(&catalog, b"transfer-1"));
    entity.share();
    ts::return_shared(catalog);
    ts::return_shared(acl);
    ts::next_tx(&mut scenario, OWNER);
    let mut entity = ts::take_shared<Entity>(&scenario);
    let catalog = ts::take_shared<ItemTypeRegistry>(&scenario);
    let cap = ts::take_from_sender<AccessCap>(&scenario);
    let items = inventory_v2::withdraw_owned(
        &mut entity,
        &catalog,
        &cap,
        SLOT,
        vector[item_v2::amount(1, 4), item_v2::amount(2, 2)],
        scenario.ctx(),
    );
    assert!(
        item_v2::matches(
            &item_v2::aggregate(&catalog, &items),
            &vector[item_v2::amount(1, 4), item_v2::amount(2, 2)],
        ),
    );
    item_v2::transfer_all(items, OWNER);
    let first = inventory_v2::export_items(
        &mut entity,
        &catalog,
        &cap,
        SLOT,
        vector[item_v2::amount(1, 2)],
        scenario.ctx(),
    );
    let second = inventory_v2::export_items(
        &mut entity,
        &catalog,
        &cap,
        SLOT,
        vector[item_v2::amount(1, 1)],
        scenario.ctx(),
    );
    assert!(first != second);
    assert!(inventory_v2::balance_of(&entity, SLOT, entity_id, 1) == 3);
    assert!(inventory_v2::balance_of(&entity, SLOT, entity_id, 2) == 3);
    assert!(
        inventory_v2::used(inventory_v2::inventory(inventory_v2::storage(&entity, SLOT), entity_id)) == 15,
    );
    assert!(event::events_by_type<inventory_v2::GameItemsExported>().length() == 2);
    ts::return_to_sender(&scenario, cap);
    ts::return_shared(entity);
    ts::return_shared(catalog);
    scenario.end();
}

#[test]
fun bulk_action_deposit_and_withdraw_match_the_complete_arrays() {
    let mut scenario = ts::begin(ADMIN);
    let (mut entity, mut catalog, acl) = setup_storage(&mut scenario, 1000);
    let entity_id = entity.id();
    let amounts = vector[item_v2::amount(1, 10), item_v2::amount(2, 5)];
    import(&mut scenario, &mut entity, &mut catalog, &acl, b"transfer-1", amounts);
    entity.share();
    ts::return_shared(catalog);
    ts::return_shared(acl);
    ts::next_tx(&mut scenario, OWNER);
    let mut entity = ts::take_shared<Entity>(&scenario);
    let catalog = ts::take_shared<ItemTypeRegistry>(&scenario);
    let cap = ts::take_from_sender<AccessCap>(&scenario);
    let mut req = entity.enable_action(
        string::utf8(b"roundtrip"),
        action::new(vector[
            inventory_v2::batch_withdrawal_requirement(SLOT, false, amounts),
            inventory_v2::batch_deposit_requirement(SLOT, false, amounts),
        ]),
        scenario.ctx(),
    );
    access_cap::verify(&mut req, &cap);
    entity.complete_request(req);
    let mut req = entity.interact(string::utf8(b"roundtrip"), vector[], scenario.ctx());
    location_service::verify_proximity(&mut req, vector[]);
    let items = inventory_v2::withdraw_many(
        &mut entity,
        &catalog,
        &mut req,
        amounts,
        scenario.ctx(),
    );
    inventory_v2::deposit_many(&mut entity, &catalog, &mut req, items, amounts, scenario.ctx());
    entity.complete_request(req);
    assert!(inventory_v2::balance_of(&entity, SLOT, entity_id, 1) == 10);
    assert!(inventory_v2::balance_of(&entity, SLOT, entity_id, 2) == 5);
    ts::return_to_sender(&scenario, cap);
    ts::return_shared(entity);
    ts::return_shared(catalog);
    scenario.end();
}

#[test, expected_failure(abort_code = item_type::ETransferReplayed)]
fun an_import_transfer_cannot_be_replayed() {
    let mut scenario = ts::begin(ADMIN);
    let (mut entity, mut catalog, acl) = setup_storage(&mut scenario, 1000);
    import(
        &mut scenario,
        &mut entity,
        &mut catalog,
        &acl,
        b"transfer-1",
        vector[item_v2::amount(1, 10)],
    );
    import(
        &mut scenario,
        &mut entity,
        &mut catalog,
        &acl,
        b"transfer-1",
        vector[item_v2::amount(2, 5)],
    );
    abort
}

#[test, expected_failure(abort_code = inventory_v2::EOverCapacity)]
fun full_array_volume_must_fit() {
    let mut scenario = ts::begin(ADMIN);
    let (mut entity, mut catalog, acl) = setup_storage(&mut scenario, 25);
    import(
        &mut scenario,
        &mut entity,
        &mut catalog,
        &acl,
        b"transfer-1",
        vector[item_v2::amount(1, 10), item_v2::amount(2, 2)],
    );
    abort
}

#[test, expected_failure(abort_code = inventory_v2::ENonEmptyStorage)]
fun uninstall_preserves_custodied_assets() {
    let mut scenario = ts::begin(ADMIN);
    let (mut entity, mut catalog, acl) = setup_storage(&mut scenario, 1000);
    import(
        &mut scenario,
        &mut entity,
        &mut catalog,
        &acl,
        b"transfer-1",
        vector[item_v2::amount(1, 10)],
    );
    let _req = inventory_v2::uninstall(&mut entity, &catalog, &acl, SLOT, scenario.ctx());
    abort
}

#[test, expected_failure(abort_code = item_type::ENotAdmin)]
fun unauthenticated_import_cannot_mint() {
    let mut scenario = ts::begin(ADMIN);
    let (entity, catalog, acl) = setup_storage(&mut scenario, 1000);
    let entity_id = entity.id();
    entity.share();
    ts::return_shared(catalog);
    ts::return_shared(acl);
    ts::next_tx(&mut scenario, OWNER);
    let mut entity = ts::take_shared<Entity>(&scenario);
    let mut catalog = ts::take_shared<ItemTypeRegistry>(&scenario);
    let acl = take_acl(&scenario);
    inventory_v2::import_items(
        &mut entity,
        &mut catalog,
        &acl,
        SLOT,
        entity_id,
        b"fake",
        vector[item_v2::amount(1, 1)],
        scenario.ctx(),
    );
    abort
}

#[test, expected_failure(abort_code = inventory_v2::EAmountAboveLimit)]
fun bulk_withdrawal_enforces_each_type_limit() {
    let mut scenario = ts::begin(ADMIN);
    let (mut entity, mut catalog, acl) = setup_storage(&mut scenario, 1000);
    import(
        &mut scenario,
        &mut entity,
        &mut catalog,
        &acl,
        b"transfer-1",
        vector[item_v2::amount(1, 10), item_v2::amount(2, 5)],
    );
    entity.share();
    ts::return_shared(catalog);
    ts::return_shared(acl);
    ts::next_tx(&mut scenario, OWNER);
    let mut entity = ts::take_shared<Entity>(&scenario);
    let catalog = ts::take_shared<ItemTypeRegistry>(&scenario);
    let cap = ts::take_from_sender<AccessCap>(&scenario);
    let mut req = entity.enable_action(
        string::utf8(b"bounded"),
        action::new(vector[
            inventory_v2::batch_withdrawal_requirement(
                SLOT,
                false,
                vector[item_v2::amount(1, 10), item_v2::amount(2, 2)],
            ),
        ]),
        scenario.ctx(),
    );
    access_cap::verify(&mut req, &cap);
    entity.complete_request(req);
    let mut req = entity.interact(string::utf8(b"bounded"), vector[], scenario.ctx());
    location_service::verify_proximity(&mut req, vector[]);
    let _items = inventory_v2::withdraw_many(
        &mut entity,
        &catalog,
        &mut req,
        vector[item_v2::amount(1, 1), item_v2::amount(2, 3)],
        scenario.ctx(),
    );
    abort
}

#[test, expected_failure(abort_code = inventory_v2::EInsufficientBalance)]
fun another_principal_cannot_export_main_assets() {
    let mut scenario = ts::begin(ADMIN);
    let (mut entity, mut catalog, acl) = setup_storage(&mut scenario, 1000);
    let entity_id = entity.id();
    import(
        &mut scenario,
        &mut entity,
        &mut catalog,
        &acl,
        b"transfer-1",
        vector[item_v2::amount(1, 10)],
    );
    entity.share();
    ts::return_shared(catalog);
    ts::return_shared(acl);
    ts::next_tx(&mut scenario, ADMIN);
    let acl = take_acl(&scenario);
    let mut registry = take_registry(&scenario);
    let mut character = claim(&mut registry, &acl, 2, scenario.ctx());
    let mut req = character.mint_access(@0xC, false, scenario.ctx());
    admin_service::verify_admin(&mut req, &acl, scenario.ctx());
    character.complete_request(req);
    character.share();
    ts::return_shared(acl);
    ts::return_shared(registry);
    ts::next_tx(&mut scenario, @0xC);
    let mut entity = ts::take_shared_by_id<Entity>(&scenario, entity_id);
    let catalog = ts::take_shared<ItemTypeRegistry>(&scenario);
    let cap = ts::take_from_sender<AccessCap>(&scenario);
    inventory_v2::export_items(
        &mut entity,
        &catalog,
        &cap,
        SLOT,
        vector[item_v2::amount(1, 1)],
        scenario.ctx(),
    );
    abort
}

#[test, expected_failure(abort_code = item_type::ETransferReplayed)]
fun import_replay_protection_survives_storage_reinstallation() {
    let mut scenario = ts::begin(ADMIN);
    let (mut entity, mut catalog, acl) = setup_storage(&mut scenario, 1000);
    let amounts = vector[item_v2::amount(1, 10)];
    import(&mut scenario, &mut entity, &mut catalog, &acl, b"transfer-1", amounts);
    entity.share();
    ts::return_shared(catalog);
    ts::return_shared(acl);
    ts::next_tx(&mut scenario, OWNER);
    let mut entity = ts::take_shared<Entity>(&scenario);
    let catalog = ts::take_shared<ItemTypeRegistry>(&scenario);
    let cap = ts::take_from_sender<AccessCap>(&scenario);
    inventory_v2::export_items(&mut entity, &catalog, &cap, SLOT, amounts, scenario.ctx());
    ts::return_shared(entity);
    ts::return_shared(catalog);
    ts::return_to_sender(&scenario, cap);
    ts::next_tx(&mut scenario, ADMIN);
    let mut entity = ts::take_shared<Entity>(&scenario);
    let mut catalog = ts::take_shared<ItemTypeRegistry>(&scenario);
    let acl = take_acl(&scenario);
    let mut req = inventory_v2::uninstall(&mut entity, &catalog, &acl, SLOT, scenario.ctx());
    admin_service::verify_admin(&mut req, &acl, scenario.ctx());
    entity.complete_request(req);
    let mut req = inventory_v2::install(
        &mut entity,
        &catalog,
        &acl,
        SLOT,
        1,
        option::none(),
        1000,
        1000,
        scenario.ctx(),
    );
    admin_service::verify_admin(&mut req, &acl, scenario.ctx());
    entity.complete_request(req);
    import(&mut scenario, &mut entity, &mut catalog, &acl, b"transfer-1", amounts);
    abort
}
