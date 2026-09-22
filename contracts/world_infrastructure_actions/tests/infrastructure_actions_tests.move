#[test_only]
module world_infrastructure_actions::infrastructure_actions_tests;

use std::unit_test::assert_eq;
use sui::{clock, test_scenario as ts};
use world::{
    access::{ServerAddressRegistry},
    test_helpers::{Self, governor, server_admin},
};
use world_action_queue::action_queue::{Self, Action, ActionQueueRegistry, AssemblyActionQueue};
use world_infrastructure_actions::infrastructure_actions::{
    Self,
    InfrastructureActionRegistry,
};

const ACTION_ID: vector<u8> = x"55555555555545559555555555555555";
const REQUIREMENTS: vector<u8> =
    x"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";

#[test]
fun authorized_keeper_queues_reactivation_for_npc_infrastructure() {
    let mut scenario = ts::begin(governor());
    action_queue::init_for_testing(scenario.ctx());
    infrastructure_actions::init_for_testing(scenario.ctx());
    test_helpers::setup_world(&mut scenario);
    test_helpers::register_server_address(&mut scenario);
    let gate_id = object::id_from_address(@0x401);
    let materials_id = object::id_from_address(@0x402);

    ts::next_tx(&mut scenario, server_admin());
    let mut action_registry = ts::take_shared<ActionQueueRegistry>(&scenario);
    let server_registry = ts::take_shared<ServerAddressRegistry>(&scenario);
    action_queue::create_server_queue(
        &mut action_registry,
        &server_registry,
        gate_id,
        scenario.ctx(),
    );
    let queue_id = action_queue::queue_object_id(&action_registry, gate_id);
    ts::return_shared(action_registry);
    ts::return_shared(server_registry);

    ts::next_tx(&mut scenario, server_admin());
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock.set_for_testing(10_000);
    let mut queue = ts::take_shared_by_id<AssemblyActionQueue>(&scenario, queue_id);
    let server_registry = ts::take_shared<ServerAddressRegistry>(&scenario);
    let infrastructure_registry = ts::take_shared<InfrastructureActionRegistry>(&scenario);
    let command = infrastructure_actions::reactivate_command(
        gate_id,
        materials_id,
        7,
        12,
        81115,
        100,
        REQUIREMENTS,
    );
    infrastructure_actions::queue_server_command(
        &mut queue,
        &infrastructure_registry,
        &server_registry,
        ACTION_ID,
        command,
        action_queue::high_priority(),
        4,
        20_000,
        &clock,
        scenario.ctx(),
    );
    let action_id = action_queue::action_object_id(&queue, ACTION_ID);
    ts::return_shared(queue);
    ts::return_shared(server_registry);
    ts::return_shared(infrastructure_registry);
    clock.destroy_for_testing();

    ts::next_tx(&mut scenario, server_admin());
    let action = ts::take_shared_by_id<Action>(&scenario, action_id);
    assert_eq!(action_queue::source(&action), gate_id);
    assert_eq!(action_queue::target(&action), materials_id);
    assert_eq!(*action_queue::action_type(&action), b"infrastructure.reactivate");
    assert!(action_queue::is_server_authored(&action), 0);
    ts::return_shared(action);
    scenario.end();
}
