import assert from "node:assert/strict";
import { test } from "node:test";
import { bcs } from "@mysten/sui/bcs";
import { SuiGrpcClient } from "@mysten/sui/grpc";
import { Ed25519Keypair } from "@mysten/sui/keypairs/ed25519";
import { Transaction } from "@mysten/sui/transactions";
import { verifyTransactionSignature } from "@mysten/sui/verify";
import { createClient } from "../ts-scripts/utils/client";
import { devInspectMoveCallFirstReturnValueBytes } from "../ts-scripts/utils/dev-inspect";
import { decodeWorldEvent } from "../ts-scripts/utils/events";
import { extractEvent, initializeContext } from "../ts-scripts/utils/helper";
import { executeSponsoredTransaction } from "../ts-scripts/utils/transaction";

const player = Ed25519Keypair.fromSecretKey(new Uint8Array(32).fill(1));
const admin = Ed25519Keypair.fromSecretKey(new Uint8Array(32).fill(2));
const playerAddress = player.toSuiAddress();
const adminAddress = admin.toSuiAddress();
const objectId = (id: number) => `0x${id.toString(16).padStart(64, "0")}`;

function sponsoredFixture() {
    const tx = new Transaction();
    const bytes = Uint8Array.from([0, 1, 2, 3, 4, 255]);
    const coin = {
        objectId: objectId(10),
        version: "7",
        digest: "11111111111111111111111111111111",
    };
    const state = {
        builds: 0,
        coins: [coin],
        listRequests: [] as unknown[],
        submissions: [] as any[],
        result: {
            $kind: "Transaction",
            Transaction: { digest: "successful-digest", status: { success: true, error: null } },
        } as any,
    };
    const client = {
        async listCoins(input: unknown) {
            state.listRequests.push(input);
            assert.equal(tx.getData().sender, playerAddress);
            assert.equal(tx.getData().gasData.owner, adminAddress);
            return { objects: state.coins, hasNextPage: false, cursor: null };
        },
        async executeTransaction(input: unknown) {
            state.submissions.push(input);
            return state.result;
        },
    } as unknown as SuiGrpcClient;
    tx.build = async (options) => {
        state.builds++;
        assert.deepEqual(options, { client });
        const data = tx.getData();
        assert.equal(data.sender, playerAddress);
        assert.equal(data.gasData.owner, adminAddress);
        assert.deepEqual(data.gasData.payment, [coin]);
        return bytes;
    };
    const execute = (include?: { events: boolean }) =>
        executeSponsoredTransaction(
            tx,
            client,
            player,
            admin,
            playerAddress,
            adminAddress,
            include
        );
    return { state, tx, bytes, execute };
}

test("sponsorship resolves sender and sponsor before building and signs identical bytes twice", async () => {
    const f = sponsoredFixture();
    const result = await f.execute();
    assert.equal(result.digest, "successful-digest");
    assert.equal(f.state.builds, 1);
    assert.deepEqual(f.state.listRequests, [
        { owner: adminAddress, coinType: "0x2::sui::SUI", limit: 1 },
    ]);
    assert.equal(f.state.submissions.length, 1);
    const submitted = f.state.submissions[0];
    assert.strictEqual(submitted.transaction, f.bytes);
    assert.deepEqual(submitted.include, { events: true, effects: true });
    assert.equal(submitted.signatures.length, 2);
    await verifyTransactionSignature(f.bytes, submitted.signatures[0], { address: playerAddress });
    await verifyTransactionSignature(f.bytes, submitted.signatures[1], { address: adminAddress });
    await assert.rejects(
        verifyTransactionSignature(Uint8Array.from([9, 9]), submitted.signatures[0]),
        /Signature is not valid/
    );
});

test("sponsorship stops before building or submitting when the sponsor has no gas", async () => {
    const f = sponsoredFixture();
    f.state.coins = [];
    await assert.rejects(f.execute(), /Admin has no gas coins/);
    assert.equal(f.state.builds, 0);
    assert.equal(f.state.submissions.length, 0);
});

test("sponsorship rejects Move failures instead of returning a successful-looking digest", async () => {
    const f = sponsoredFixture();
    f.state.result = {
        $kind: "FailedTransaction",
        FailedTransaction: {
            digest: "aborted-digest",
            status: { success: false, error: { message: "MoveAbort: ENotAuthorized" } },
        },
    };
    await assert.rejects(f.execute(), /aborted-digest.*MoveAbort: ENotAuthorized/);
    assert.equal(f.state.submissions.length, 1);
});

test("sponsorship preserves explicit native includes while always requesting effects", async () => {
    const f = sponsoredFixture();
    await f.execute({ events: false });
    assert.deepEqual(f.state.submissions[0].include, { events: false, effects: true });
});

test("view calls simulate with the real sender and return native command BCS bytes", async () => {
    const bytes = bcs.u64().serialize("9007199254740993").toBytes();
    const client = {
        async simulateTransaction(input: any) {
            assert.ok(input.transaction instanceof Transaction);
            const data = input.transaction.getData();
            assert.equal(data.sender, playerAddress);
            assert.equal(data.gasData.payment, null);
            assert.equal(data.commands.length, 1);
            assert.equal(data.commands[0].MoveCall.function, "fuel_quantity");
            assert.deepEqual(input.include, { commandResults: true });
            return {
                $kind: "Transaction",
                Transaction: { status: { success: true, error: null } },
                commandResults: [{ returnValues: [{ bcs: bytes }], mutatedReferences: [] }],
            };
        },
    } as unknown as Pick<SuiGrpcClient, "simulateTransaction">;
    const result = await devInspectMoveCallFirstReturnValueBytes(client, {
        target: `${objectId(11)}::network_node::fuel_quantity`,
        senderAddress: playerAddress,
        arguments: (tx) => [tx.object(objectId(12))],
    });
    assert.strictEqual(result, bytes);
    assert.equal(bcs.u64().parse(result!), "9007199254740993");
});

test("view calls return null on simulation failure or missing command outputs", async () => {
    const results = [
        {
            $kind: "FailedTransaction",
            FailedTransaction: { status: { success: false } },
            commandResults: [{ returnValues: [{ bcs: Uint8Array.of(1) }] }],
        },
        { $kind: "Transaction", commandResults: undefined },
        { $kind: "Transaction", commandResults: [] },
        { $kind: "Transaction", commandResults: [{ returnValues: [] }] },
    ];
    for (const result of results) {
        const client = {
            async simulateTransaction() {
                return result;
            },
        } as unknown as Pick<SuiGrpcClient, "simulateTransaction">;
        assert.equal(
            await devInspectMoveCallFirstReturnValueBytes(client, {
                target: `${objectId(11)}::network_node::fuel_quantity`,
                senderAddress: playerAddress,
                arguments: () => [],
            }),
            null
        );
    }
});

test("view calls propagate transport failures", async () => {
    const client = {
        async simulateTransaction() {
            throw new Error("gRPC unavailable");
        },
    } as unknown as Pick<SuiGrpcClient, "simulateTransaction">;
    await assert.rejects(
        devInspectMoveCallFirstReturnValueBytes(client, {
            target: `${objectId(11)}::network_node::fuel_quantity`,
            senderAddress: playerAddress,
            arguments: () => [],
        }),
        /gRPC unavailable/
    );
});

// Assemble independent byte fixtures in the field order declared by the Move
// contracts, without importing the decoder's schemas or serializing through them.
function bytes(...parts: Array<Uint8Array | number[]>) {
    return Uint8Array.from(Buffer.concat(parts.map((part) => Buffer.from(part))));
}
function address(id: number) {
    return Buffer.from(objectId(id).slice(2), "hex");
}
function u64(value: bigint | number) {
    const encoded = Buffer.alloc(8);
    encoded.writeBigUInt64LE(BigInt(value));
    return encoded;
}
function key(id: number) {
    const tenant = Buffer.from("seed-tenant", "utf8");
    return bytes(u64(id), [tenant.length], tenant);
}
const expectedKey = (id: number) => ({ item_id: String(id), tenant: "seed-tenant" });
const createdPrefix = bytes(address(1), key(42), address(2), u64(9007199254740993n));
const createdFields = {
    assembly_id: objectId(1),
    assembly_key: expectedKey(42),
    owner_cap_id: objectId(2),
    type_id: "9007199254740993",
};
const eventCases = [
    {
        suffix: "::assembly::AssemblyCreatedEvent",
        encoded: createdPrefix,
        expected: createdFields,
    },
    {
        suffix: "::gate::GateCreatedEvent",
        encoded: bytes(createdPrefix, [3, 10, 20, 30], [1]),
        expected: {
            ...createdFields,
            location_hash: [10, 20, 30],
            status: { OFFLINE: true, $kind: "OFFLINE" },
        },
    },
    {
        suffix: "::network_node::NetworkNodeCreatedEvent",
        encoded: bytes(createdPrefix, u64(10000), u64(3600000), u64(100)),
        expected: {
            network_node_id: objectId(1),
            assembly_key: expectedKey(42),
            owner_cap_id: objectId(2),
            type_id: "9007199254740993",
            fuel_max_capacity: "10000",
            fuel_burn_rate_in_ms: "3600000",
            max_energy_production: "100",
        },
    },
    {
        suffix: "::storage_unit::StorageUnitCreatedEvent",
        encoded: bytes(createdPrefix, u64(1000000000000n), [2, 99, 42], [2]),
        expected: {
            storage_unit_id: objectId(1),
            assembly_key: expectedKey(42),
            owner_cap_id: objectId(2),
            type_id: "9007199254740993",
            max_capacity: "1000000000000",
            location_hash: [99, 42],
            status: { ONLINE: true, $kind: "ONLINE" },
        },
    },
    {
        suffix: "::turret::TurretCreatedEvent",
        encoded: createdPrefix,
        expected: {
            turret_id: objectId(1),
            turret_key: expectedKey(42),
            owner_cap_id: objectId(2),
            type_id: "9007199254740993",
        },
    },
    {
        suffix: "::gate::JumpEvent",
        encoded: bytes(address(1), key(10), address(2), key(20), address(3), key(30)),
        expected: {
            source_gate_id: objectId(1),
            source_gate_key: expectedKey(10),
            destination_gate_id: objectId(2),
            destination_gate_key: expectedKey(20),
            character_id: objectId(3),
            character_key: expectedKey(30),
        },
    },
];

for (const fixture of eventCases) {
    test(`BCS event decoding matches the Move layout for ${fixture.suffix}`, () => {
        const eventType = `${objectId(11)}${fixture.suffix}`;
        assert.deepEqual(decodeWorldEvent(eventType, fixture.encoded), fixture.expected);
        assert.deepEqual(
            extractEvent(
                {
                    events: [
                        { eventType: `${objectId(11)}::irrelevant::Event`, bcs: new Uint8Array() },
                        { eventType, bcs: fixture.encoded },
                    ],
                },
                fixture.suffix
            ),
            fixture.expected
        );
        assert.throws(() => decodeWorldEvent(eventType, fixture.encoded.slice(0, 4)));
    });
}

test("event extraction returns null for absent events and rejects unsupported matching events", () => {
    assert.equal(extractEvent({}, "::gate::JumpEvent"), null);
    assert.equal(
        extractEvent(
            { events: [{ eventType: "0x1::assembly::AssemblyCreatedEvent", bcs: createdPrefix }] },
            "::gate::JumpEvent"
        ),
        null
    );
    assert.throws(() => decodeWorldEvent("0x1::unknown::Event", createdPrefix), /No BCS decoder/);
    assert.throws(
        () =>
            extractEvent(
                { events: [{ eventType: "0x1::unknown::Event", bcs: createdPrefix }] },
                "::unknown::Event"
            ),
        /No BCS decoder/
    );
});

test("default script clients and contexts use native gRPC", () => {
    assert.ok(createClient() instanceof SuiGrpcClient);
    const context = initializeContext("localnet", player.getSecretKey());
    assert.ok(context.client instanceof SuiGrpcClient);
    assert.equal(context.address, playerAddress);
    assert.equal(context.keypair.toSuiAddress(), playerAddress);
});
