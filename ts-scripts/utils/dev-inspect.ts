import type { SuiGrpcClient } from "@mysten/sui/grpc";
import { Transaction } from "@mysten/sui/transactions";
import { requireEnv } from "./helper";

function resolveDevInspectSender(senderAddress?: string): string {
    return senderAddress || requireEnv("ADMIN_ADDRESS") || "0x";
}

export async function devInspectMoveCallFirstReturnValueBytes(
    client: Pick<SuiGrpcClient, "simulateTransaction">,
    params: {
        target: string;
        typeArguments?: string[];
        senderAddress?: string;
        arguments: (tx: Transaction) => any[];
    }
): Promise<Uint8Array | null> {
    const tx = new Transaction();
    tx.moveCall({
        target: params.target,
        typeArguments: params.typeArguments,
        arguments: params.arguments(tx),
    });

    tx.setSender(resolveDevInspectSender(params.senderAddress));
    const result = await client.simulateTransaction({
        transaction: tx,
        include: { commandResults: true },
    });

    if (result.$kind === "FailedTransaction") {
        return null;
    }

    const returnValues = result.commandResults?.[0]?.returnValues;
    if (!returnValues?.length) return null;

    return returnValues[0].bcs;
}
