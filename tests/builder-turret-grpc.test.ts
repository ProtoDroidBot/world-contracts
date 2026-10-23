import assert from "node:assert/strict";
import test from "node:test";
import { bcs } from "@mysten/sui/bcs";
import { Ed25519Keypair } from "@mysten/sui/keypairs/ed25519";
import { getOwnedJumpPermitId } from "../ts-scripts/builder_extension/jump-permit";
import {
    getTurretPriorityListFromWorld,
    ReturnTargetPriorityListBcs,
} from "../ts-scripts/turret/get-priority-list";

test("JumpPermit lookup uses native owned objects and follows empty filtered pages", async () => {
    const requests: any[] = [];
    const client = {
        async listOwnedObjects(request: unknown) {
            requests.push(request);
            return requests.length === 1
                ? { objects: [], hasNextPage: true, cursor: "next-page" }
                : { objects: [{ objectId: "0xpermit" }], hasNextPage: false, cursor: null };
        },
    };
    assert.equal(await getOwnedJumpPermitId(client as any, "0xowner", "0xworld"), "0xpermit");
    assert.equal(requests[0].type, "0xworld::gate::JumpPermit");
    assert.equal(requests[0].owner, "0xowner");
    assert.equal(requests[1].cursor, "next-page");
});

test("JumpPermit lookup distinguishes no permit from an RPC failure", async () => {
    assert.equal(
        await getOwnedJumpPermitId(
            {
                async listOwnedObjects() {
                    return { objects: [], hasNextPage: false, cursor: null };
                },
            } as any,
            "0xowner",
            "0xworld"
        ),
        null
    );
    await assert.rejects(
        getOwnedJumpPermitId(
            {
                async listOwnedObjects() {
                    throw new Error("RPC unavailable");
                },
            } as any,
            "0xowner",
            "0xworld"
        ),
        /RPC unavailable/
    );
});

test("JumpPermit lookup rejects missing or cyclic pagination cursors", async () => {
    for (const cursors of [[null], ["a", "a"], ["a", "b", "a"]]) {
        let calls = 0;
        await assert.rejects(
            getOwnedJumpPermitId(
                {
                    async listOwnedObjects() {
                        assert.ok(
                            calls < cursors.length,
                            "Pagination must stop on an invalid cursor"
                        );
                        return { objects: [], hasNextPage: true, cursor: cursors[calls++] };
                    },
                } as any,
                "0xowner",
                "0xworld"
            ),
            /invalid pagination/
        );
        assert.equal(calls, cursors.length);
    }
});

test("Turret priority simulation decodes the second command's native BCS result", async () => {
    const keypair = new Ed25519Keypair();
    const priorities = [{ target_item_id: 171n, priority_weight: 10n }];
    const inner = bcs.vector(ReturnTargetPriorityListBcs).serialize(priorities).toBytes();
    const bytes = bcs.vector(bcs.u8()).serialize(inner).toBytes();
    const ctx = {
        keypair,
        config: { packageId: "0x1" },
        client: {
            async simulateTransaction({ transaction, include }: any) {
                assert.equal(transaction.getData().sender, keypair.toSuiAddress());
                assert.deepEqual(include, { commandResults: true });
                return {
                    $kind: "Transaction",
                    Transaction: { status: { success: true } },
                    commandResults: [{ returnValues: [] }, { returnValues: [{ bcs: bytes }] }],
                };
            },
        },
    };
    assert.deepEqual(
        await getTurretPriorityListFromWorld("0x2", "0x3", [], ctx as any),
        priorities
    );
});

test("Turret priority simulation fails on FailedTransaction instead of returning an empty list", async () => {
    const ctx = {
        keypair: new Ed25519Keypair(),
        config: { packageId: "0x1" },
        client: {
            async simulateTransaction() {
                return {
                    $kind: "FailedTransaction",
                    FailedTransaction: {
                        status: { success: false, error: { message: "turret offline" } },
                    },
                    commandResults: [],
                };
            },
        },
    };
    await assert.rejects(
        getTurretPriorityListFromWorld("0x2", "0x3", [], ctx as any),
        /turret offline/
    );
});
