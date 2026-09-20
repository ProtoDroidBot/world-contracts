import "dotenv/config";
import { Transaction } from "@mysten/sui/transactions";
import { SuiJsonRpcClient } from "@mysten/sui/jsonRpc";
import { Ed25519Keypair } from "@mysten/sui/keypairs/ed25519";
import { getConfig, MODULES } from "../utils/config";
import {
    hydrateWorldConfig,
    initializeContext,
    handleError,
    getEnvConfig,
    parseBigIntArray,
} from "../utils/helper";
import { delay } from "../utils/delay";
import {
    planAssemblyEnergyReconciliation,
    readAssemblyEnergyManifest,
} from "./assembly-energy-config";

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

async function readEnergyConfig(
    energyConfig: string,
    client: SuiJsonRpcClient
): Promise<Array<{ typeID: number; energyRequired: number }>> {
    const response = await client.getObject({
        id: energyConfig,
        options: { showContent: true },
    });
    if (response.error || response.data?.content?.dataType !== "moveObject") {
        throw new Error("Cannot read EnergyConfig");
    }
    const config = response.data.content.fields as any;
    const table = fields(config.assembly_energy);
    const tableId = objectId(table?.id);
    if (!tableId) throw new Error("EnergyConfig assembly energy table ID is missing");

    const requirements = new Map<number, number>();
    const cursors = new Set<string>();
    let cursor: string | null = null;
    do {
        const page: any = await client.getDynamicFields({ parentId: tableId, cursor, limit: 50 });
        for (const entry of page.data) {
            if (entry.name.type !== "u64") {
                throw new Error("EnergyConfig contains a non-u64 assembly type");
            }
            const typeID = Number(entry.name.value);
            if (!Number.isSafeInteger(typeID) || typeID <= 0 || requirements.has(typeID)) {
                throw new Error("EnergyConfig contains an invalid or duplicate assembly type");
            }
            const result = await client.getDynamicFieldObject({
                parentId: tableId,
                name: entry.name,
            });
            const value =
                result.data?.content?.dataType === "moveObject"
                    ? (result.data.content.fields as any)
                    : null;
            const energyRequired = value && Number(value.value);
            if (
                result.error ||
                !value ||
                String(value.name) !== String(entry.name.value) ||
                !Number.isSafeInteger(energyRequired) ||
                energyRequired <= 0
            ) {
                throw new Error(`Cannot read energy requirement for assembly type ${typeID}`);
            }
            requirements.set(typeID, energyRequired);
        }
        cursor = page.hasNextPage ? page.nextCursor : null;
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

async function setFuelEfficiency(
    fuelTypeId: bigint,
    fuelEfficiency: bigint,
    adminAcl: string,
    client: SuiJsonRpcClient,
    keypair: Ed25519Keypair,
    config: ReturnType<typeof getConfig>
) {
    console.log(`\n==== Setting Fuel Efficiency ====`);
    console.log(
        `Fuel Type ID: ${fuelTypeId.toString()}, Efficiency: ${fuelEfficiency.toString()}%`
    );

    const tx = new Transaction();

    tx.moveCall({
        target: `${config.packageId}::${MODULES.FUEL}::set_fuel_efficiency`,
        arguments: [
            tx.object(config.fuelConfig),
            tx.object(adminAcl),
            tx.pure.u64(fuelTypeId),
            tx.pure.u64(fuelEfficiency),
        ],
    });

    const result = await client.signAndExecuteTransaction({
        transaction: tx,
        signer: keypair,
        options: { showObjectChanges: true, showEffects: true },
    });

    console.log("\n Fuel efficiency set successfully!");
    console.log("Transaction digest:", result.digest);
    return result;
}

async function setEnergyConfig(
    assemblyTypeId: bigint,
    energyRequired: bigint,
    adminAcl: string,
    client: SuiJsonRpcClient,
    keypair: Ed25519Keypair,
    config: ReturnType<typeof getConfig>
) {
    console.log(`\n==== Setting Energy Configuration ====`);
    console.log(
        `Assembly Type ID: ${assemblyTypeId.toString()}, Energy Required: ${energyRequired.toString()}`
    );

    const tx = new Transaction();
    tx.moveCall({
        target: `${config.packageId}::${MODULES.ENERGY}::set_energy_config`,
        arguments: [
            tx.object(config.energyConfig),
            tx.object(adminAcl),
            tx.pure.u64(assemblyTypeId),
            tx.pure.u64(energyRequired),
        ],
    });

    const result = await client.signAndExecuteTransaction({
        transaction: tx,
        signer: keypair,
        options: { showObjectChanges: true, showEffects: true },
    });

    console.log("\n Energy configuration set successfully!");
    console.log("Transaction digest:", result.digest);
    return result;
}

async function removeEnergyConfig(
    assemblyTypeId: bigint,
    adminAcl: string,
    client: SuiJsonRpcClient,
    keypair: Ed25519Keypair,
    config: ReturnType<typeof getConfig>
) {
    console.log(`\n==== Removing Energy Configuration ====`);
    console.log(`Assembly Type ID: ${assemblyTypeId.toString()}`);
    const tx = new Transaction();
    tx.moveCall({
        target: `${config.packageId}::${MODULES.ENERGY}::remove_energy_config`,
        arguments: [
            tx.object(config.energyConfig),
            tx.object(adminAcl),
            tx.pure.u64(assemblyTypeId),
        ],
    });
    const result = await client.signAndExecuteTransaction({
        transaction: tx,
        signer: keypair,
        options: { showObjectChanges: true, showEffects: true },
    });
    console.log("\n Energy configuration removed successfully!");
    console.log("Transaction digest:", result.digest);
    return result;
}

async function main() {
    console.log("============= Configure Fuel and Energy example ==============\n");

    try {
        const FUEL_TYPE_IDS = parseBigIntArray(process.env.FUEL_TYPE_IDS);
        const FUEL_EFFICIENCIES = parseBigIntArray(process.env.FUEL_EFFICIENCIES);
        const energyManifest = readAssemblyEnergyManifest();

        const env = getEnvConfig();
        const ctx = initializeContext(env.network, env.adminExportedKey);
        await hydrateWorldConfig(ctx);
        const { client, keypair, config } = ctx;
        const adminAcl = config.adminAcl;

        // Configure fuel efficiencies
        if (FUEL_TYPE_IDS.length > 0 && FUEL_EFFICIENCIES.length > 0) {
            if (FUEL_TYPE_IDS.length !== FUEL_EFFICIENCIES.length) {
                throw new Error(
                    `FUEL_TYPE_IDS and FUEL_EFFICIENCIES arrays must have the same length. Got ${FUEL_TYPE_IDS.length} and ${FUEL_EFFICIENCIES.length}`
                );
            }

            for (let i = 0; i < FUEL_TYPE_IDS.length; i++) {
                await setFuelEfficiency(
                    FUEL_TYPE_IDS[i],
                    FUEL_EFFICIENCIES[i],
                    adminAcl,
                    client,
                    keypair,
                    config
                );
                await delay(1000);
            }
        } else {
            console.log("\nNo fuel configurations provided. Skipping fuel efficiency setup.");
        }

        // Reconcile the complete build-scoped manifest. Zero means the type is
        // intentionally free and therefore must not have an on-chain table row.
        const currentEnergy = await readEnergyConfig(config.energyConfig, client);
        const plan = planAssemblyEnergyReconciliation(currentEnergy, energyManifest);
        console.log(`\nEnergy manifest: ${energyManifest.path}`);
        for (const typeID of plan.remove) {
            await removeEnergyConfig(BigInt(typeID), adminAcl, client, keypair, config);
            await delay(1000);
        }
        for (const entry of plan.set) {
            await setEnergyConfig(
                BigInt(entry.typeID),
                BigInt(entry.energyRequired),
                adminAcl,
                client,
                keypair,
                config
            );
            await delay(1000);
        }
        if (plan.remove.length === 0 && plan.set.length === 0) {
            console.log("\nEnergy configuration already matches the build manifest.");
        } else {
            const verified = planAssemblyEnergyReconciliation(
                await readEnergyConfig(config.energyConfig, client),
                energyManifest
            );
            if (verified.remove.length > 0 || verified.set.length > 0) {
                throw new Error(
                    `Energy configuration reconciliation did not converge ` +
                        `(remove: ${verified.remove.join(",") || "none"}; ` +
                        `set: ${verified.set.map((entry) => entry.typeID).join(",") || "none"})`
                );
            }
            console.log("\nEnergy configuration verified against the build manifest.");
        }
    } catch (error) {
        handleError(error);
    }
}

main();
