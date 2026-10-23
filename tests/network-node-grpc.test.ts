import assert from "node:assert/strict";
import { test } from "node:test";
import type { SuiGrpcClient } from "@mysten/sui/grpc";
import { getAssemblyTypes } from "../ts-scripts/network-node/helper";

test("connected assembly dispatch reads native gRPC object types", async () => {
    const types = {
        "0x1": "0xpackage::gate::Gate",
        "0x2": "0xpackage::turret::Turret",
        "0x3": "0xpackage::storage_unit::StorageUnit",
        "0x4": "0xpackage::assembly::Assembly",
    };
    const requests: unknown[] = [];
    const client = {
        async getObject(input: { objectId: keyof typeof types }) {
            requests.push(input);
            return { object: { type: types[input.objectId] } };
        },
    } as unknown as Pick<SuiGrpcClient, "getObject">;

    assert.deepEqual(await getAssemblyTypes(Object.keys(types), client), [
        { id: "0x1", kind: "gate" },
        { id: "0x2", kind: "turret" },
        { id: "0x3", kind: "storage_unit" },
        { id: "0x4", kind: "assembly" },
    ]);
    assert.deepEqual(
        requests,
        Object.keys(types).map((objectId) => ({ objectId }))
    );
});
