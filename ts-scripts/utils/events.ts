import { bcs } from "@mysten/sui/bcs";

// These layouts follow the Move event definitions in contracts/world/sources.
// The core gRPC API provides BCS event bytes, not JSON-RPC's parsedJson.
const TenantItemId = bcs.struct("TenantItemId", {
    item_id: bcs.u64(),
    tenant: bcs.string(),
});
const Status = bcs.enum("Status", { NULL: null, OFFLINE: null, ONLINE: null });
const assemblyFields = {
    assembly_id: bcs.Address,
    assembly_key: TenantItemId,
    owner_cap_id: bcs.Address,
    type_id: bcs.u64(),
};
const eventSchemas = {
    "::assembly::AssemblyCreatedEvent": bcs.struct("AssemblyCreatedEvent", assemblyFields),
    "::gate::GateCreatedEvent": bcs.struct("GateCreatedEvent", {
        ...assemblyFields,
        location_hash: bcs.vector(bcs.u8()),
        status: Status,
    }),
    "::network_node::NetworkNodeCreatedEvent": bcs.struct("NetworkNodeCreatedEvent", {
        network_node_id: bcs.Address,
        assembly_key: TenantItemId,
        owner_cap_id: bcs.Address,
        type_id: bcs.u64(),
        fuel_max_capacity: bcs.u64(),
        fuel_burn_rate_in_ms: bcs.u64(),
        max_energy_production: bcs.u64(),
    }),
    "::storage_unit::StorageUnitCreatedEvent": bcs.struct("StorageUnitCreatedEvent", {
        storage_unit_id: bcs.Address,
        assembly_key: TenantItemId,
        owner_cap_id: bcs.Address,
        type_id: bcs.u64(),
        max_capacity: bcs.u64(),
        location_hash: bcs.vector(bcs.u8()),
        status: Status,
    }),
    "::turret::TurretCreatedEvent": bcs.struct("TurretCreatedEvent", {
        turret_id: bcs.Address,
        turret_key: TenantItemId,
        owner_cap_id: bcs.Address,
        type_id: bcs.u64(),
    }),
    "::gate::JumpEvent": bcs.struct("JumpEvent", {
        source_gate_id: bcs.Address,
        source_gate_key: TenantItemId,
        destination_gate_id: bcs.Address,
        destination_gate_key: TenantItemId,
        character_id: bcs.Address,
        character_key: TenantItemId,
    }),
};

export function decodeWorldEvent(eventType: string, bytes: Uint8Array): unknown {
    const schema = Object.entries(eventSchemas).find(([suffix]) => eventType.endsWith(suffix))?.[1];
    if (!schema) throw new Error(`No BCS decoder for world event ${eventType}`);
    return schema.parse(bytes);
}
