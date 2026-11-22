import "dotenv/config";
import { Transaction } from "@mysten/sui/transactions";
import type { SuiGrpcClient } from "@mysten/sui/grpc";
import { Ed25519Keypair } from "@mysten/sui/keypairs/ed25519";
import { getConfig, MODULES } from "../utils/config";
import {
    hydrateWorldConfig,
    initializeGrpcContext,
    handleError,
    getEnvConfig,
    parseBigIntArray,
} from "../utils/helper";
import { delay } from "../utils/delay";
import { executeGrpcTransaction } from "../utils/grpc-transaction";
import {
    planAssemblyEnergyReconciliation,
    readAssemblyEnergyManifest,
} from "./assembly-energy-config";
import { readEnergyConfig } from "./read-energy-config";

async function setFuelEfficiency(
    fuelTypeId: bigint,
    fuelEfficiency: bigint,
    adminAcl: string,
    client: SuiGrpcClient,
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

    const result = await executeGrpcTransaction(client, tx, keypair);

    console.log("\n Fuel efficiency set successfully!");
    console.log("Transaction digest:", result.digest);
    return result;
}

async function setEnergyConfig(
    assemblyTypeId: bigint,
    energyRequired: bigint,
    adminAcl: string,
    client: SuiGrpcClient,
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

    const result = await executeGrpcTransaction(client, tx, keypair);

    console.log("\n Energy configuration set successfully!");
    console.log("Transaction digest:", result.digest);
    return result;
}

async function removeEnergyConfig(
    assemblyTypeId: bigint,
    adminAcl: string,
    client: SuiGrpcClient,
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
    const result = await executeGrpcTransaction(client, tx, keypair);
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
        const ctx = initializeGrpcContext(env.network, env.adminExportedKey);
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
