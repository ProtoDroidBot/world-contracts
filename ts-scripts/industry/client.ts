import { bcs } from "@mysten/sui/bcs";
import type { SuiJsonRpcClient } from "@mysten/sui/jsonRpc";
import { Transaction } from "@mysten/sui/transactions";
import { deriveObjectID, deriveDynamicFieldID, isValidSuiObjectId, normalizeSuiAddress } from "@mysten/sui/utils";
import { parseIndustrySnapshot, parseIndustryProduction, u64, type IndustrySnapshot, type IndustryProduction } from "./snapshot";

export type IndustryWorld = {
    packageId: string;
    objectRegistry: string;
    adminAcl: string;
    /** Shared root created when the Smart Industry package is first published. */
    industryRegistry: string;
    /** Latest package used for function calls after a manual upgrade. */
    industryPackageId?: string;
    /** Package that first introduced smart_industry's types. */
    industryTypeOrigin?: string;
};
export type IndustryState = {
    objectId: string;
    assemblyId: string;
    revision: string;
    observedAtMs: string;
    syncedAtMs: string;
    assemblyStatus: number;
    snapshot: IndustrySnapshot;
    production: IndustryProduction | null;
    productionMirrored: boolean;
};

export function objectId(value: string): string {
    if (!/^0x[0-9a-fA-F]{1,64}$/.test(value)) throw new Error("Invalid Sui object ID");
    const normalized = normalizeSuiAddress(value);
    if (!isValidSuiObjectId(normalized)) throw new Error("Invalid Sui object ID");
    return normalized;
}

export function deriveIndustryId(
    world: Pick<
        IndustryWorld,
        "packageId" | "industryRegistry" | "industryPackageId" | "industryTypeOrigin"
    >,
    assemblyId: string
): string {
    const key = bcs.struct("IndustryKey", { assembly_id: bcs.Address });
    return deriveObjectID(
        objectId(world.industryRegistry),
        `${objectId(world.industryTypeOrigin || world.industryPackageId || world.packageId)}::smart_industry::IndustryKey`,
        key.serialize({ assembly_id: objectId(assemblyId) }).toBytes()
    );
}

function fields(value: any): any {
    return value?.fields ?? value;
}

export function deriveProductionFieldId(industryId: string): string {
    return deriveDynamicFieldID(industryId, "u8", bcs.u8().serialize(0).toBytes());
}

async function readProduction(client: Pick<SuiJsonRpcClient, "getObject">, industryId: string, revision: string, allowStaleRevision = false) {
    const result = await client.getObject({ id: deriveProductionFieldId(industryId), options: { showContent: true, showOwner: true } });
    if (result.error?.code === "notExists") return { production: null, productionMirrored: false };
    const content = result.data?.content;
    const owner = result.data?.owner;
    if (result.error || content?.dataType !== "moveObject" || !owner || typeof owner !== "object" ||
        !("ObjectOwner" in owner) || objectId(owner.ObjectOwner) !== industryId ||
        !/^0x0*2::dynamic_field::Field<u8, 0x[0-9a-f]+::smart_industry::ProductionRecord>$/.test(content.type)) throw new Error("Invalid production field");
    const value = content.fields as any;
    const record = fields(value.value);
    if (Number(value.name) !== 0) throw new Error("Invalid production field name");
    const productionMirrored = u64(record?.revision, "production revision", true) === revision;
    if (!productionMirrored && !allowStaleRevision) throw new Error("Production revision changed; retry read");
    const raw = fields(record.production);
    if (Number(raw?.state) === 0) {
        if ([raw.job_id, raw.requested_runs, raw.completed_runs, raw.run_started_at_ms, raw.run_end_at_ms].some(value => u64(value, "idle production") !== "0") || raw.stop_reason !== "") throw new Error("Invalid idle production");
        return { production: null, productionMirrored };
    }
    return { production: parseIndustryProduction({ ...raw,
        state: ({ 1: "RUNNING", 2: "DISCONTINUING", 3: "STOPPED" } as Record<number, string>)[Number(raw?.state)],
        requested_runs: u64(raw?.requested_runs, "requested_runs") === "0" ? null : raw.requested_runs,
        stop_reason: raw?.stop_reason === "" ? null : raw?.stop_reason,
    }), productionMirrored };
}

export async function readIndustry(
    client: Pick<SuiJsonRpcClient, "getObject">,
    world: IndustryWorld,
    assemblyId: string,
    repairProduction = false
): Promise<IndustryState | null> {
    const id = deriveIndustryId(world, assemblyId);
    const result = await client.getObject({ id, options: { showContent: true, showOwner: true } });
    if (result.error?.code === "notExists") return null;
    if (result.error) throw new Error(`Cannot read Smart Industry: ${result.error.code}`);
    const content = result.data?.content;
    if (
        !content ||
        content.dataType !== "moveObject" ||
        content.type !==
            `${objectId(world.industryTypeOrigin || world.industryPackageId || world.packageId)}::smart_industry::SmartIndustry`
    ) {
        throw new Error("Unexpected Smart Industry object type");
    }
    if (
        !result.data?.owner ||
        typeof result.data.owner !== "object" ||
        !("Shared" in result.data.owner)
    ) {
        throw new Error("Smart Industry must be a shared object");
    }
    const value = content.fields as Record<string, any>;
    if (objectId(value.assembly_id) !== objectId(assemblyId))
        throw new Error("Smart Industry parent mismatch");
    const raw = fields(value.snapshot);
    const snapshot = parseIndustrySnapshot({
        ...raw,
        inputs: raw.inputs?.map(fields),
        outputs: raw.outputs?.map(fields),
        blueprint_inputs: raw.blueprint_inputs?.map(fields),
        blueprint_outputs: raw.blueprint_outputs?.map(fields),
    });
    const assemblyStatus = Number(value.assembly_status);
    if (![1, 2].includes(assemblyStatus)) throw new Error("Invalid Smart Industry assembly status");
    return {
        objectId: id,
        assemblyId: objectId(assemblyId),
        revision: u64(value.revision, "revision", true),
        observedAtMs: u64(value.observed_at_ms, "observed_at_ms"),
        syncedAtMs: u64(value.synced_at_ms, "synced_at_ms"),
        assemblyStatus,
        snapshot,
        ...await readProduction(client, id, u64(value.revision, "revision", true), repairProduction),
    };
}

/** Build one atomic full replacement; no signing or network access. */
export function buildIndustryTransaction(
    world: IndustryWorld,
    assemblyId: string,
    input: unknown,
    observedAtMs: string,
    previous: IndustryState | null,
    productionInput: unknown = null
): Transaction {
    const snapshot = parseIndustrySnapshot(input);
    const production = parseIndustryProduction(productionInput);
    if (production && snapshot.blueprint_id === "0") throw new Error("Production requires a selected blueprint");
    const observed = u64(observedAtMs, "observed_at_ms", true);
    const parent = objectId(assemblyId);
    if (
        previous &&
        (previous.objectId !== deriveIndustryId(world, parent) || previous.assemblyId !== parent)
    ) {
        throw new Error("Previous Smart Industry belongs to a different facility");
    }
    if (previous && BigInt(observed) <= BigInt(previous.observedAtMs))
        throw new Error("Observation must be newer than the current snapshot");
    const target = `${objectId(world.industryPackageId || world.packageId)}::smart_industry`;
    const typeOrigin = `${objectId(world.industryTypeOrigin || world.industryPackageId || world.packageId)}::smart_industry`;
    const tx = new Transaction();
    const items = (side: "inputs" | "outputs") =>
        tx.makeMoveVec({
            type: `${typeOrigin}::ItemStack`,
            elements: snapshot[side].map(
                (item) =>
                    tx.moveCall({
                        target: `${target}::new_item_stack`,
                        arguments: [tx.pure.u64(item.type_id), tx.pure.u64(item.quantity)],
                    })[0]
            ),
        });
    const recipes = (side: "blueprint_inputs" | "blueprint_outputs") =>
        tx.makeMoveVec({
            type: `${typeOrigin}::RecipeSlot`,
            elements: snapshot[side].map(
                (item) =>
                    tx.moveCall({
                        target: `${target}::new_recipe_slot`,
                        arguments: [
                            tx.pure.u64(item.type_id),
                            tx.pure.u64(item.quantity),
                            tx.pure.u64(item.max_quantity),
                        ],
                    })[0]
            ),
        });
    const [value] = tx.moveCall({
        target: `${target}::new_snapshot`,
        arguments: [
            tx.pure.u64(snapshot.owner_id),
            tx.pure.u64(snapshot.solar_system_id),
            tx.pure.u64(snapshot.blueprint_id),
            tx.pure.u64(snapshot.run_time),
            items("inputs"),
            items("outputs"),
            recipes("blueprint_inputs"),
            recipes("blueprint_outputs"),
        ],
    });
    const productionValue = production ? tx.moveCall({ target: `${target}::new_production`, arguments: [
        tx.pure.u64(production.job_id), tx.pure.u8({ RUNNING: 1, DISCONTINUING: 2, STOPPED: 3 }[production.state]),
        tx.pure.u64(production.requested_runs ?? "0"), tx.pure.u64(production.completed_runs),
        tx.pure.u64(production.run_started_at_ms), tx.pure.u64(production.run_end_at_ms), tx.pure.string(production.stop_reason ?? ""),
    ] }) : tx.moveCall({ target: `${target}::idle_production` });
    tx.moveCall({
        target: `${target}::${previous ? "sync_with_production" : "create_with_production"}`,
        arguments: [
            tx.object(previous?.objectId ?? objectId(world.industryRegistry)),
            tx.object(parent),
            tx.object(objectId(world.adminAcl)),
            ...(previous ? [tx.pure.u64(previous.revision)] : []),
            tx.pure.u64(observed),
            value,
            productionValue,
            tx.object("0x6"),
        ],
    });
    return tx;
}
