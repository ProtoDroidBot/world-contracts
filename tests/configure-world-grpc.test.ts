import assert from "node:assert/strict";
import { createServer } from "node:http";
import { test } from "node:test";
import { Ed25519Keypair } from "@mysten/sui/keypairs/ed25519";
import { SuiGrpcClient } from "@mysten/sui/grpc";
import { Transaction } from "@mysten/sui/transactions";
import { createGrpcClient } from "../ts-scripts/utils/client";
import { initializeGrpcContext } from "../ts-scripts/utils/helper";
import { executeGrpcTransaction } from "../ts-scripts/utils/grpc-transaction";

test("configuration resolves Move calls through gRPC at the configured fullnode URL", async (t) => {
    const requests: string[] = [];
    const server = createServer((request, response) => {
        requests.push(request.url!);
        // Reproduce a node without a JSON-RPC route; stop before any transaction executes.
        response.writeHead(404);
        response.end();
    });
    await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
    t.after(
        () =>
            new Promise<void>((resolve, reject) => {
                server.close((error) => (error ? reject(error) : resolve()));
                server.closeAllConnections();
            })
    );
    const address = server.address();
    assert.ok(address && typeof address === "object");
    const previousUrl = process.env.SUI_RPC_URL;
    process.env.SUI_RPC_URL = `http://127.0.0.1:${address.port}`;
    t.after(() => {
        if (previousUrl === undefined) delete process.env.SUI_RPC_URL;
        else process.env.SUI_RPC_URL = previousUrl;
    });

    const keypair = new Ed25519Keypair();
    const context = initializeGrpcContext("localnet", keypair.getSecretKey());
    assert.ok(context.client instanceof SuiGrpcClient);
    assert.equal(context.client.network, "localnet");
    assert.equal(context.config.url, process.env.SUI_RPC_URL);
    const transaction = new Transaction();
    transaction.moveCall({
        target: "0x1::access::register_server_address",
        arguments: [
            transaction.object("0x2"),
            transaction.object("0x3"),
            transaction.pure.address("0x4"),
        ],
    });
    await assert.rejects(executeGrpcTransaction(context.client, transaction, context.keypair));
    assert.deepEqual(requests, ["/sui.rpc.v2.TransactionExecutionService/SimulateTransaction"]);
});

test("gRPC configuration clients preserve the requested network", () => {
    for (const network of ["localnet", "testnet", "devnet", "mainnet"] as const) {
        assert.equal(createGrpcClient(network).network, network);
    }
});

test("configuration unwraps successful execution and requests effects", async () => {
    const transaction = new Transaction();
    const signer = new Ed25519Keypair();
    const executed = { digest: "configured", status: { success: true, error: null } };
    const client = {
        async signAndExecuteTransaction(options: any) {
            assert.equal(options.transaction, transaction);
            assert.equal(options.signer, signer);
            assert.deepEqual(options.include, { effects: true });
            assert.equal(options.options, undefined);
            return { $kind: "Transaction", Transaction: executed };
        },
    } as unknown as Pick<SuiGrpcClient, "signAndExecuteTransaction">;
    assert.equal(await executeGrpcTransaction(client, transaction, signer), executed);
});

test("configuration fails on a Move abort even when the transport succeeds", async () => {
    const client = {
        async signAndExecuteTransaction() {
            return {
                $kind: "FailedTransaction",
                FailedTransaction: {
                    digest: "failed-digest",
                    status: { success: false, error: { message: "MoveAbort: ENotAuthorized" } },
                },
            };
        },
    } as unknown as Pick<SuiGrpcClient, "signAndExecuteTransaction">;
    await assert.rejects(
        executeGrpcTransaction(client, new Transaction(), new Ed25519Keypair()),
        /Transaction failed-digest failed: MoveAbort: ENotAuthorized/
    );
});
