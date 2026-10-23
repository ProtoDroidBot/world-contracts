import { bcs } from "@mysten/sui/bcs";
import type { SuiGrpcClient } from "@mysten/sui/grpc";

function fields(value: unknown): any {
    let current = value as any;
    while (current && typeof current === "object" && current.fields) {
        current = current.fields;
    }
    return current;
}

function objectId(value: unknown): string {
    const current = fields(value);
    if (typeof current === "string") return current;
    if (current && typeof current === "object") {
        return objectId(current.id ?? current.objectId ?? current.object_id);
    }
    return "";
}

export async function readEnergyConfig(
    energyConfig: string,
    client: Pick<SuiGrpcClient, "getObject" | "listDynamicFields">
): Promise<Array<{ typeID: number; energyRequired: number }>> {
    const { object } = await client.getObject({
        objectId: energyConfig,
        include: { json: true },
    });
    if (!object.json) throw new Error("Cannot read EnergyConfig");
    const config = fields(object.json);
    const table = fields(config.assembly_energy);
    const tableId = objectId(table?.id);
    if (!tableId) throw new Error("EnergyConfig assembly energy table ID is missing");

    const requirements = new Map<number, number>();
    const cursors = new Set<string>();
    let cursor: string | null = null;
    do {
        const page = await client.listDynamicFields({ parentId: tableId, cursor, limit: 50 });
        for (const entry of page.dynamicFields) {
            if (entry.name.type !== "u64") {
                throw new Error("EnergyConfig contains a non-u64 assembly type");
            }
            if (entry.name.bcs.length !== 8) {
                throw new Error("EnergyConfig contains an invalid u64 assembly type");
            }
            const name = bcs.u64().parse(entry.name.bcs);
            const typeID = Number(name);
            if (!Number.isSafeInteger(typeID) || typeID <= 0 || requirements.has(typeID)) {
                throw new Error("EnergyConfig contains an invalid or duplicate assembly type");
            }
            // gRPC supplies each dynamic field's object ID and BCS name. Read
            // its JSON content directly instead of using JSON-RPC field lookup.
            const result = await client.getObject({
                objectId: entry.fieldId,
                include: { json: true },
            });
            const value = fields(result.object.json);
            const energyRequired = value && Number(value.value);
            if (
                !value ||
                String(value.name) !== name ||
                !Number.isSafeInteger(energyRequired) ||
                energyRequired <= 0
            ) {
                throw new Error(`Cannot read energy requirement for assembly type ${typeID}`);
            }
            requirements.set(typeID, energyRequired);
        }
        cursor = page.hasNextPage ? page.cursor : null;
        if (page.hasNextPage && (!cursor || cursors.has(cursor))) {
            throw new Error("EnergyConfig pagination did not advance");
        }
        if (cursor) cursors.add(cursor);
    } while (cursor);
    if (table.size !== undefined && BigInt(table.size) !== BigInt(requirements.size)) {
        throw new Error("EnergyConfig changed during reading; retry configuration");
    }
    return [...requirements]
        .map(([typeID, energyRequired]) => ({ typeID, energyRequired }))
        .sort((a, b) => a.typeID - b.typeID);
}
