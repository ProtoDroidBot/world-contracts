#[test_only]
module inventory::item_tests;

use inventory::item;
use std::string;
use sui::{event, test_scenario as ts};
use variant::variant::{Self, VariantKey};

const FUEL: u64 = 100;
const BLUE_PRINT: u64 = 200;
const VOL: u64 = 10;
const BLUE_PRINT_VOL: u64 = 500;

fun tenant(): string::String { string::utf8(b"test") }

fun fuel_key(): VariantKey { variant::new_key(tenant(), FUEL, 0) }

fun source(): ID { object::id_from_address(@0x5) }

fun blueprint_key(): entity_key::EntityKey { entity_key::new(BLUE_PRINT, tenant()) }

fun withdraw_item(
    bag: &mut item::ItemBag,
    key: VariantKey,
    quantity: u64,
    used: &mut u64,
    ctx: &mut TxContext,
): item::Item {
    item::mint(bag, key, quantity, VOL, 0, source(), COMPONENT, used);
    item::withdraw(bag, key, quantity, source(), COMPONENT, used, ctx)
}

#[test]
fun bag_mint_adds_balance() {
    let mut scenario = ts::begin(@0xA);
    let mut bag = item::new_bag(scenario.ctx());
    let key = fuel_key();
    let mut used = 0;

    item::mint(&mut bag, key, 25, VOL, 0, source(), COMPONENT, &mut used);
    assert!(item::balance(&bag, key) == 25);

    item::destroy_bag(bag);
    scenario.end();
}

/// Mint `count` types (ids 1..=count, quantity = id) into a fresh bag, then
/// drain it at `batch_size`. Returns the batches emitted.
fun drain_types(count: u64, batch_size: u64): vector<item::ItemsDestroyed> {
    let mut scenario = ts::begin(@0xA);
    let mut bag = item::new_bag(scenario.ctx());
    let mut used = 0;
    count.do!(|i| {
        let key = variant::new_key(tenant(), i + 1, 0);
        item::mint(&mut bag, key, i + 1, VOL, 0, source(), COMPONENT, &mut used);
    });
    assert!(bag.balance_count() == count);
    item::drain_and_destroy(bag, source(), COMPONENT, batch_size);
    let batches = event::events_by_type<item::ItemsDestroyed>();
    scenario.end();
    batches
}

/// Batch `batch_index` holds `len` balances, continuing the 1..=count sequence.
fun assert_batch(batch: &item::ItemsDestroyed, batch_index: u64, len: u64, batch_size: u64) {
    let (entity_id, component_id, index, balances) = item::items_destroyed_fields(batch);
    assert!(entity_id == source() && component_id == COMPONENT);
    assert!(index == batch_index && balances.length() == len);
    len.do!(|i| {
        let expected = batch_index * batch_size + i + 1;
        let (key, quantity, volume) = item::destroyed_balance_fields(&balances[i]);
        assert!(key.type_id() == expected && quantity == expected && volume == expected * VOL);
    });
}

#[test]
fun drain_lists_balances_in_batches() {
    let batches = drain_types(5, 2);
    assert!(batches.length() == 3);
    assert_batch(&batches[0], 0, 2, 2);
    assert_batch(&batches[1], 1, 2, 2);
    assert_batch(&batches[2], 2, 1, 2);
    assert!(event::events_by_type<item::ItemBurned>().is_empty());
}

#[test]
fun drain_fills_batches_exactly() {
    let batches = drain_types(4, 2);
    assert!(batches.length() == 2);
    assert_batch(&batches[0], 0, 2, 2);
    assert_batch(&batches[1], 1, 2, 2);
}

#[test]
fun drain_under_one_batch() {
    let batches = drain_types(3, 1000);
    assert!(batches.length() == 1);
    assert_batch(&batches[0], 0, 3, 1000);
}

#[test]
fun drain_empty_bag_emits_nothing() {
    assert!(drain_types(0, 2).is_empty());
}

#[test]
fun full_batch_fits_the_event_size_limit() {
    // Sui's `max_event_emit_size`.
    assert!(item::full_batch_bcs_size(inventory::inventory::event_batch_size()) < 256_000);
}

#[test]
fun bag_deposit_merges_by_type() {
    let mut scenario = ts::begin(@0xA);
    let mut bag = item::new_bag(scenario.ctx());
    let key = fuel_key();
    let mut used = 0;

    let item_a = withdraw_item(&mut bag, key, 30, &mut used, scenario.ctx());
    item::deposit(&mut bag, item_a, source(), COMPONENT, &mut used);
    let item_b = withdraw_item(&mut bag, key, 20, &mut used, scenario.ctx());
    item::deposit(&mut bag, item_b, source(), COMPONENT, &mut used);
    assert!(item::balance(&bag, key) == 50);

    let out = item::withdraw(&mut bag, key, 15, source(), COMPONENT, &mut used, scenario.ctx());
    assert!(out.quantity() == 15);
    assert!(out.unit_volume() == VOL && out.volume() == 15 * VOL);
    assert!(item::balance(&bag, key) == 35);
    assert!(used == 35 * VOL);

    item::destroy(out);
    item::destroy_bag(bag);
    scenario.end();
}

#[test]
fun withdraw_records_fields() {
    let mut scenario = ts::begin(@0xA);
    let mut bag = item::new_bag(scenario.ctx());
    let key = fuel_key();
    let mut used = 0;
    let fuel = withdraw_item(&mut bag, key, 50, &mut used, scenario.ctx());
    assert!(fuel.key() == key);
    assert!(fuel.quantity() == 50);
    assert!(fuel.unit_volume() == VOL && fuel.decimals() == 0);
    assert!(fuel.source() == source());
    item::destroy(fuel);
    item::destroy_bag(bag);
    scenario.end();
}

#[test, expected_failure(abort_code = item::EInsufficientQuantity)]
fun withdraw_over_balance_aborts() {
    let mut scenario = ts::begin(@0xA);
    let mut bag = item::new_bag(scenario.ctx());
    let key = fuel_key();
    let mut used = 0;
    item::mint(&mut bag, key, 10, VOL, 0, source(), COMPONENT, &mut used);
    // Must hit the balance check, not underflow `used`.
    let _out = item::withdraw(&mut bag, key, 11, source(), COMPONENT, &mut used, scenario.ctx());

    abort
}

/// Two variants of one type keep their own stacks, and a deposited `Item`
/// joins only its own variant's stack.
#[test]
fun variants_of_one_type_stay_separate() {
    let mut scenario = ts::begin(@0xA);
    let mut bag = item::new_bag(scenario.ctx());
    let plain = fuel_key();
    let tuned = variant::new_key(tenant(), FUEL, 1);
    let mut used = 0;
    item::mint(&mut bag, plain, 10, VOL, 0, source(), COMPONENT, &mut used);
    item::mint(&mut bag, tuned, 5, VOL + 1, 0, source(), COMPONENT, &mut used);
    assert!(bag.balance_count() == 2);
    assert!(item::balance(&bag, plain) == 10 && item::balance(&bag, tuned) == 5);
    assert!(used == 10 * VOL + 5 * (VOL + 1));

    let mut other = item::new_bag(scenario.ctx());
    let mut other_used = 0;
    item::mint(&mut other, tuned, 2, VOL + 1, 0, source(), COMPONENT, &mut other_used);
    let item = item::withdraw(
        &mut other,
        tuned,
        2,
        source(),
        COMPONENT,
        &mut other_used,
        scenario.ctx(),
    );
    item::deposit(&mut bag, item, source(), COMPONENT, &mut used);
    assert!(bag.balance_count() == 2);
    assert!(item::balance(&bag, plain) == 10 && item::balance(&bag, tuned) == 7);
    assert!(item::volume_of(&bag, plain) == 10 * VOL);
    assert!(item::volume_of(&bag, tuned) == 7 * (VOL + 1));
    assert!(used == 10 * VOL + 7 * (VOL + 1));

    item::destroy_bag(other);
    item::destroy_bag(bag);
    scenario.end();
}

/// A mass stack rounds its volume up once, not once per mint: two 0.0001 kg
/// mints at 3 nano-m³/kg take ceil(3 × 0.0002) = 1, not 2.
#[test]
fun mass_stack_volume_rounds_up_once() {
    let mut scenario = ts::begin(@0xA);
    let mut bag = item::new_bag(scenario.ctx());
    let key = fuel_key();
    let mut used = 0;
    item::mint(&mut bag, key, STEP, 3, MASS, source(), COMPONENT, &mut used);
    assert!(used == 1);
    item::mint(&mut bag, key, STEP, 3, MASS, source(), COMPONENT, &mut used);
    assert!(item::balance(&bag, key) == 2 * STEP);
    assert!(item::volume_of(&bag, key) == 1 && used == 1);

    item::destroy_bag(bag);
    scenario.end();
}

#[test, expected_failure(abort_code = item::EQuantityNotWholeStep)]
fun mint_mass_not_whole_step_aborts() {
    let mut scenario = ts::begin(@0xA);
    let mut bag = item::new_bag(scenario.ctx());
    let mut used = 0;
    item::mint(&mut bag, fuel_key(), STEP + 1, 3, MASS, source(), COMPONENT, &mut used);

    abort
}

#[test, expected_failure(abort_code = item::EQuantityNotWholeStep)]
fun split_mass_not_whole_step_aborts() {
    let mut scenario = ts::begin(@0xA);
    let mut bag = item::new_bag(scenario.ctx());
    let key = fuel_key();
    let mut used = 0;
    item::mint(&mut bag, key, 2 * STEP, 3, MASS, source(), COMPONENT, &mut used);
    let mut a = item::withdraw(
        &mut bag,
        key,
        2 * STEP,
        source(),
        COMPONENT,
        &mut used,
        scenario.ctx(),
    );
    let _b = item::split(&mut a, STEP / 2, scenario.ctx());

    abort
}

#[test]
fun split_and_merge() {
    let mut scenario = ts::begin(@0xA);
    let mut bag = item::new_bag(scenario.ctx());
    let key = fuel_key();
    let mut used = 0;
    let mut a = withdraw_item(&mut bag, key, 100, &mut used, scenario.ctx());
    let b = item::split(&mut a, 40, scenario.ctx());
    assert!(a.quantity() == 60);
    assert!(b.quantity() == 40);
    assert!(b.key() == key && b.unit_volume() == VOL);

    item::merge(&mut a, b);
    assert!(a.quantity() == 100);

    item::destroy(a);
    item::destroy_bag(bag);
    scenario.end();
}

#[test, expected_failure(abort_code = item::EWrongVariant)]
fun merge_wrong_type_aborts() {
    let mut scenario = ts::begin(@0xA);
    let mut bag = item::new_bag(scenario.ctx());
    let key_a = fuel_key();
    let key_b = variant::new_key(tenant(), FUEL + 1, 0);
    let mut used = 0;
    let mut a = withdraw_item(&mut bag, key_a, 10, &mut used, scenario.ctx());
    let b = withdraw_item(&mut bag, key_b, 10, &mut used, scenario.ctx());
    item::merge(&mut a, b);

    abort
}

#[test]
fun mint_singleton_stores_instance() {
    let mut scenario = ts::begin(@0xA);
    let mut bag = item::new_bag(scenario.ctx());
    item::mint_singleton(&mut bag, 1, blueprint_key(), BLUE_PRINT_VOL, scenario.ctx());
    assert!(item::has_singleton(&bag, 1));
    assert!(item::singleton_volume(&bag, 1) == BLUE_PRINT_VOL);
    assert!(!item::has_singleton(&bag, 2));

    item::burn_all_and_destroy(bag, tenant());
    scenario.end();
}

#[test, expected_failure(abort_code = item::EItemIdExists)]
fun mint_singleton_duplicate_aborts() {
    let mut scenario = ts::begin(@0xA);
    let mut bag = item::new_bag(scenario.ctx());
    item::mint_singleton(&mut bag, 1, blueprint_key(), BLUE_PRINT_VOL, scenario.ctx());
    item::mint_singleton(&mut bag, 1, blueprint_key(), BLUE_PRINT_VOL, scenario.ctx());

    abort
}

#[test]
fun singleton_distinct_from_same_type_non_singleton() {
    let mut scenario = ts::begin(@0xA);
    let mut bag = item::new_bag(scenario.ctx());
    // A non-singleton balance and a singleton of the same `type_id` (BLUE_PRINT) coexist
    // independently — minting one never touches the other.
    item::mint(&mut bag, blueprint_key(), 5, VOL);
    item::mint_singleton(&mut bag, 1, blueprint_key(), BLUE_PRINT_VOL, scenario.ctx());

    assert!(item::balance(&bag, BLUE_PRINT) == 5);
    assert!(item::has_singleton(&bag, 1));

    item::burn(&mut bag, blueprint_key(), 5);
    assert!(item::balance(&bag, BLUE_PRINT) == 0);
    assert!(item::has_singleton(&bag, 1));

    item::burn_all_and_destroy(bag, tenant());
    scenario.end();
}

#[test]
fun withdraw_singleton_then_deposit_round_trip() {
    let mut scenario = ts::begin(@0xA);
    let mut bag = item::new_bag(scenario.ctx());
    item::mint_singleton(&mut bag, 1, blueprint_key(), BLUE_PRINT_VOL, scenario.ctx());

    let ship = item::withdraw_singleton(&mut bag, 1, blueprint_key());
    assert!(!item::has_singleton(&bag, 1));
    assert!(ship.item_id() == option::some(1));
    assert!(ship.quantity() == 1);
    assert!(ship.type_id() == BLUE_PRINT);
    assert!(ship.volume() == BLUE_PRINT_VOL);

    item::deposit(&mut bag, ship, tenant());
    assert!(item::has_singleton(&bag, 1));
    assert!(item::singleton_volume(&bag, 1) == BLUE_PRINT_VOL);

    item::burn_all_and_destroy(bag, tenant());
    scenario.end();
}

#[test, expected_failure(abort_code = item::EItemIdExists)]
fun deposit_singleton_duplicate_id_aborts() {
    let mut scenario = ts::begin(@0xA);
    let mut bag = item::new_bag(scenario.ctx());
    item::mint_singleton(&mut bag, 1, blueprint_key(), BLUE_PRINT_VOL, scenario.ctx());
    let ship = item::withdraw_singleton(&mut bag, 1, blueprint_key());
    // Re-mint the same id while the withdrawn copy is still in hand, then try
    // to deposit it back — the bag already has id 1.
    item::mint_singleton(&mut bag, 1, blueprint_key(), BLUE_PRINT_VOL, scenario.ctx());
    item::deposit(&mut bag, ship, tenant());

    abort
}

#[test, expected_failure(abort_code = item::EItemIdNotFound)]
fun burn_singleton_absent_aborts() {
    let mut scenario = ts::begin(@0xA);
    let mut bag = item::new_bag(scenario.ctx());
    item::burn_singleton(&mut bag, 1, blueprint_key());

    abort
}

#[test, expected_failure(abort_code = item::EWrongType)]
fun withdraw_singleton_wrong_type_aborts() {
    let mut scenario = ts::begin(@0xA);
    let mut bag = item::new_bag(scenario.ctx());
    item::mint_singleton(&mut bag, 1, blueprint_key(), BLUE_PRINT_VOL, scenario.ctx());
    let _ship = item::withdraw_singleton(&mut bag, 1, fuel_key());

    abort
}

#[test, expected_failure(abort_code = item::EIsSingleton)]
fun split_singleton_aborts() {
    let mut scenario = ts::begin(@0xA);
    let mut bag = item::new_bag(scenario.ctx());
    item::mint_singleton(&mut bag, 1, blueprint_key(), BLUE_PRINT_VOL, scenario.ctx());
    let mut ship = item::withdraw_singleton(&mut bag, 1, blueprint_key());
    let _piece = item::split(&mut ship, 1, scenario.ctx());

    abort
}

#[test, expected_failure(abort_code = item::EIsSingleton)]
fun merge_singleton_aborts() {
    let mut scenario = ts::begin(@0xA);
    let mut bag = item::new_bag(scenario.ctx());
    item::mint_singleton(&mut bag, 1, blueprint_key(), BLUE_PRINT_VOL, scenario.ctx());
    item::mint_singleton(&mut bag, 2, blueprint_key(), BLUE_PRINT_VOL, scenario.ctx());
    let mut ship_a = item::withdraw_singleton(&mut bag, 1, blueprint_key());
    let ship_b = item::withdraw_singleton(&mut bag, 2, blueprint_key());
    item::merge(&mut ship_a, ship_b);

    abort
}

#[test]
fun burn_all_and_destroy_clears_singletons() {
    let mut scenario = ts::begin(@0xA);
    let mut bag = item::new_bag(scenario.ctx());
    item::mint_singleton(&mut bag, 1, blueprint_key(), BLUE_PRINT_VOL, scenario.ctx());
    item::mint(&mut bag, fuel_key(), 10, VOL);

    item::burn_all_and_destroy(bag, tenant());
    assert!(event::events_by_type<item::ItemBurned>().length() == 2);
    scenario.end();
}
