import { Transaction } from "@mysten/sui/transactions";
import type { SuiGrpcClient } from "@mysten/sui/grpc";
import type { SuiClientTypes } from "@mysten/sui/client";
import { Ed25519Keypair } from "@mysten/sui/keypairs/ed25519";
import { requireSuccessfulTransaction } from "./grpc-transaction";

export async function executeSponsoredTransaction<
    Include extends SuiClientTypes.TransactionInclude = { events: true },
>(
    tx: Transaction,
    client: SuiGrpcClient,
    playerKeypair: Ed25519Keypair,
    adminKeypair: Ed25519Keypair,
    playerAddress: string,
    adminAddress: string,
    include?: Include
) {
    // Resolve the complete sponsored transaction with the real sender and gas
    // owner. gRPC's resolver simulates these identities when selecting gas.
    tx.setSender(playerAddress);
    tx.setGasOwner(adminAddress);
    const gasCoins = await client.listCoins({
        owner: adminAddress,
        coinType: "0x2::sui::SUI",
        limit: 1,
    });

    if (gasCoins.objects.length === 0) {
        throw new Error("Admin has no gas coins to sponsor the transaction");
    }

    const gasPayment = gasCoins.objects.map((coin) => ({
        objectId: coin.objectId,
        version: coin.version,
        digest: coin.digest,
    }));

    tx.setGasPayment(gasPayment);
    const transactionBytes = await tx.build({ client });

    const playerSignature = await playerKeypair.signTransaction(transactionBytes);
    const adminSignature = await adminKeypair.signTransaction(transactionBytes);

    // Execute with both signatures
    return requireSuccessfulTransaction(
        await client.executeTransaction({
            transaction: transactionBytes,
            signatures: [playerSignature.signature, adminSignature.signature],
            include: { ...(include ?? { events: true }), effects: true } as Include & {
                effects: true;
            },
        })
    );
}
