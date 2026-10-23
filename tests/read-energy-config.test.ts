import assert from "node:assert/strict";
import { test } from "node:test";
import { bcs } from "@mysten/sui/bcs";
import type { SuiGrpcClient } from "@mysten/sui/grpc";
import { readEnergyConfig } from "../ts-scripts/network-node/read-energy-config";

const configId = "0xconfig";
const tableId = "0xtable";

function field(typeID: number | string, fieldId = `0xfield${typeID}`) {
    return {
        fieldId,
        name: { type: "u64", bcs: bcs.u64().serialize(typeID).toBytes() },
        valueType: "u64",
        type: "0x2::dynamic_field::Field<u64,u64>",
    };
}

function fixture() {
    const objects: Record<string, any> = {
        [configId]: { assembly_energy: { id: tableId, size: "2" } },
        "0xfield90184": { name: "90184", value: "1" },
        "0xfield77917": { name: "77917", value: "400" },
    };
    const pages = [
        { dynamicFields: [field(90184)], hasNextPage: true, cursor: "page-2" },
        { dynamicFields: [field(77917)], hasNextPage: false, cursor: null },
    ];
    const objectRequests: unknown[] = [];
    const pageRequests: unknown[] = [];
    const client = {
        async getObject(input: { objectId: string }) {
            objectRequests.push(input);
            if (!(input.objectId in objects)) throw new Error("Object not found");
            return { object: { json: objects[input.objectId] } };
        },
        async listDynamicFields(input: unknown) {
            pageRequests.push(input);
            const page = pages[pageRequests.length - 1];
            assert.ok(page, "must stop when pagination finishes or fails to advance");
            return page;
        },
    } as unknown as Pick<SuiGrpcClient, "getObject" | "listDynamicFields">;
    return { objects, pages, client, objectRequests, pageRequests };
}

test("energy reader reads paginated gRPC BCS names and plain JSON field objects", async () => {
    const f = fixture();
    assert.deepEqual(await readEnergyConfig(configId, f.client), [
        { typeID: 77917, energyRequired: 400 },
        { typeID: 90184, energyRequired: 1 },
    ]);
    assert.deepEqual(f.objectRequests, [
        { objectId: configId, include: { json: true } },
        { objectId: "0xfield90184", include: { json: true } },
        { objectId: "0xfield77917", include: { json: true } },
    ]);
    assert.deepEqual(f.pageRequests, [
        { parentId: tableId, cursor: null, limit: 50 },
        { parentId: tableId, cursor: "page-2", limit: 50 },
    ]);
});

test("energy reader handles an empty energy table", async () => {
    const f = fixture();
    f.objects[configId].assembly_energy.size = "0";
    f.pages[0] = { dynamicFields: [], hasNextPage: false, cursor: null };
    assert.deepEqual(await readEnergyConfig(configId, f.client), []);
});

test("energy reader rejects missing config JSON and table identifiers", async () => {
    for (const json of [null, {}, { assembly_energy: { size: "0" } }]) {
        const f = fixture();
        f.objects[configId] = json;
        await assert.rejects(
            readEnergyConfig(configId, f.client),
            /Cannot read EnergyConfig|table ID is missing/
        );
        assert.equal(f.pageRequests.length, 0);
    }
});

test("energy reader propagates missing dynamic field objects", async () => {
    const f = fixture();
    delete f.objects["0xfield90184"];
    await assert.rejects(readEnergyConfig(configId, f.client), /Object not found/);
});

test("energy reader rejects non-u64, malformed, zero and unsafe assembly names", async () => {
    const invalidNames = [
        { type: "u8", bcs: bcs.u8().serialize(1).toBytes() },
        { type: "u64", bcs: new Uint8Array(7) },
        field(0).name,
        field("9007199254740993").name,
    ];
    for (const name of invalidNames) {
        const f = fixture();
        f.pages[0].dynamicFields[0].name = name;
        await assert.rejects(readEnergyConfig(configId, f.client), /invalid|non-u64/);
        assert.equal(f.objectRequests.length, 1);
    }
});

test("energy reader rejects duplicate assembly names across pages", async () => {
    const f = fixture();
    f.pages[1].dynamicFields = [field(90184)];
    await assert.rejects(readEnergyConfig(configId, f.client), /duplicate/);
});

test("energy reader rejects mismatched field names and invalid energy values", async () => {
    for (const value of [
        null,
        { name: "77917", value: "1" },
        { name: "90184", value: "0" },
        { name: "90184", value: "-1" },
        { name: "90184", value: "1.5" },
        { name: "90184", value: "9007199254740993" },
    ]) {
        const f = fixture();
        f.objects["0xfield90184"] = value;
        await assert.rejects(
            readEnergyConfig(configId, f.client),
            /Cannot read energy requirement/
        );
    }
});

test("energy reader rejects absent and repeated continuation cursors", async () => {
    const missing = fixture();
    missing.pages[0].cursor = null;
    await assert.rejects(readEnergyConfig(configId, missing.client), /pagination did not advance/);

    const repeated = fixture();
    repeated.pages[1].hasNextPage = true;
    repeated.pages[1].cursor = "page-2";
    await assert.rejects(readEnergyConfig(configId, repeated.client), /pagination did not advance/);
});

test("energy reader detects table size changes during pagination", async () => {
    const f = fixture();
    f.objects[configId].assembly_energy.size = "3";
    await assert.rejects(readEnergyConfig(configId, f.client), /changed during reading/);
});
