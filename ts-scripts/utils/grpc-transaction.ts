import type { SuiClientTypes } from "@mysten/sui/client";
import type { Signer } from "@mysten/sui/cryptography";
import type { SuiGrpcClient } from "@mysten/sui/grpc";
import type { Transaction } from "@mysten/sui/transactions";

/** Unwrap the SDK result and never report a failed on-chain transaction as success. */
export function requireSuccessfulTransaction<Include extends SuiClientTypes.TransactionInclude>(
    result: SuiClientTypes.TransactionResult<Include>
): SuiClientTypes.Transaction<Include> {
    const executed = result.$kind === "Transaction" ? result.Transaction : result.FailedTransaction;
    if (!executed.status.success) {
        throw new Error(`Transaction ${executed.digest} failed: ${executed.status.error.message}`);
    }
    return executed;
}

export async function executeGrpcTransaction<
    Include extends SuiClientTypes.TransactionInclude = {},
>(
    client: Pick<SuiGrpcClient, "signAndExecuteTransaction">,
    transaction: Transaction,
    signer: Signer,
    include?: Include
): Promise<SuiClientTypes.Transaction<Include & { effects: true }>> {
    const result = await client.signAndExecuteTransaction({
        transaction,
        signer,
        include: { ...include, effects: true } as Include & { effects: true },
    });
    return requireSuccessfulTransaction(result);
}
