import "dotenv/config";
import { executeGrpcTransaction } from "../utils/grpc-transaction";
import { Transaction } from "@mysten/sui/transactions";
import { bcs } from "@mysten/sui/bcs";
import type { SuiGrpcClient } from "@mysten/sui/grpc";
import { Ed25519Keypair } from "@mysten/sui/keypairs/ed25519";
import { getConfig, MODULES } from "../utils/config";
import { extractEvent, hexToBytes } from "../utils/helper";
import { hydrateWorldConfig, initializeContext, handleError, getEnvConfig } from "../utils/helper";
import {
    LOCATION_HASH,
    GAME_CHARACTER_ID,
    NWN_ITEM_ID,
    STORAGE_A_TYPE_ID,
    STORAGE_A_ITEM_ID,
} from "../utils/constants";
import { deriveObjectId } from "../utils/derive-object-id";

const MAX_CAPACITY = 1000000000000n;

async function createStorageUnit(
    characterObjectId: string,
    networkNodeObjectId: string,
    typeId: bigint,
    itemId: bigint,
    adminAcl: string,
    client: SuiGrpcClient,
    keypair: Ed25519Keypair,
    config: ReturnType<typeof getConfig>
) {
    const tx = new Transaction();

    const [storageUnit] = tx.moveCall({
        target: `${config.packageId}::${MODULES.STORAGE_UNIT}::anchor`,
        arguments: [
            tx.object(config.objectRegistry),
            tx.object(networkNodeObjectId),
            tx.object(characterObjectId),
            tx.object(adminAcl),
            tx.pure.u64(itemId),
            tx.pure.u64(typeId),
            tx.pure.u64(MAX_CAPACITY),
            tx.pure(bcs.vector(bcs.u8()).serialize(hexToBytes(LOCATION_HASH))),
        ],
    });

    tx.moveCall({
        target: `${config.packageId}::${MODULES.STORAGE_UNIT}::share_storage_unit`,
        arguments: [storageUnit, tx.object(adminAcl)],
    });

    const result = await executeGrpcTransaction(client, tx, keypair, { events: true });

    console.log("Transaction digest:", result.digest);

    const storageUnitEvent = extractEvent<{ storage_unit_id: string; owner_cap_id: string }>(
        result,
        "::storage_unit::StorageUnitCreatedEvent"
    );

    if (!storageUnitEvent) {
        throw new Error("StorageUnitCreatedEvent not found in transaction result");
    }

    const storageUnitId = storageUnitEvent.storage_unit_id;
    console.log("Storage Unit Object Id: ", storageUnitId);

    const ownerCapObjectId = storageUnitEvent.owner_cap_id;
    console.log("OwnerCap Object Id: ", ownerCapObjectId);
}

async function main() {
    try {
        const env = getEnvConfig();
        const ctx = initializeContext(env.network, env.adminExportedKey);
        await hydrateWorldConfig(ctx);
        const { client, keypair, config } = ctx;
        const adminAcl = config.adminAcl;

        const characterObject = deriveObjectId(
            config.objectRegistry,
            GAME_CHARACTER_ID,
            config.packageId
        );
        const networkNodeObject = deriveObjectId(
            config.objectRegistry,
            NWN_ITEM_ID,
            config.packageId
        );

        await createStorageUnit(
            characterObject,
            networkNodeObject,
            STORAGE_A_TYPE_ID,
            STORAGE_A_ITEM_ID,
            adminAcl,
            client,
            keypair,
            config
        );
    } catch (error) {
        handleError(error);
    }
}

main();
