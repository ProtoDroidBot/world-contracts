import assert from "node:assert/strict";
import { test } from "node:test";
import {
    buildIndustryTransaction,
    deriveIndustryId,
    deriveProductionFieldId,
    objectId,
    readIndustry,
    type IndustryState,
} from "../ts-scripts/industry/client";
import { parseIndustrySnapshot, parseIndustryProduction, u64 } from "../ts-scripts/industry/snapshot";

const world = {
    packageId: "0x123",
    objectRegistry: "0x456",
    adminAcl: "0x789",
    industryRegistry: "0x654",
};
const assemblyId = objectId("0xabc");
const empty = {
    owner_id: "7",
    solar_system_id: "30000001",
    blueprint_id: "0",
    run_time: "0",
    inputs: [],
    outputs: [],
    blueprint_inputs: [],
    blueprint_outputs: [],
};
const previous: IndustryState = {
    objectId: deriveIndustryId(world, assemblyId),
    assemblyId,
    revision: "3",
    observedAtMs: "1000",
    syncedAtMs: "1001",
    assemblyStatus: 1,
    snapshot: empty,
    production: null,
    productionMirrored: false,
};

test("snapshot keeps exact u64 values, canonical ordering and empty replacement", () => {
    const parsed = parseIndustrySnapshot({
        ...empty,
        inputs: [
            { type_id: 20, quantity: "18446744073709551615" },
            { type_id: "0010", quantity: 2 },
        ],
    });
    assert.deepEqual(parsed.inputs, [
        { type_id: "10", quantity: "2" },
        { type_id: "20", quantity: "18446744073709551615" },
    ]);
    assert.deepEqual(parseIndustrySnapshot(empty), empty);
    assert.throws(() => u64(Number.MAX_SAFE_INTEGER + 1, "id"), /exact/);
    assert.throws(() => u64("18446744073709551616", "id"), /range/);
});

test("rejects ambiguous, partial or unsupported facility observations", () => {
    for (const value of [
        { ...empty, inputs: undefined },
        { ...empty, owner_id: 0 },
        { ...empty, inputs: [{ type_id: 1, quantity: 0 }] },
        {
            ...empty,
            inputs: [
                { type_id: 1, quantity: 1 },
                { type_id: "01", quantity: 2 },
            ],
        },
        { ...empty, blueprint_id: 2 },
        { ...empty, run_time: 1 },
        { ...empty, production: { active: true } },
        {
            ...empty,
            blueprint_id: 2,
            run_time: 10,
            blueprint_inputs: [{ type_id: 1, quantity: 3, max_quantity: 2 }],
        },
        {
            ...empty,
            inputs: Array.from({ length: 257 }, (_, i) => ({ type_id: i + 1, quantity: 1 })),
        },
    ])
        assert.throws(() => parseIndustrySnapshot(value));
});

test("sidecar derivation isolates registry and parent identity", () => {
    assert.equal(deriveIndustryId(world, "0xabc"), previous.objectId);
    assert.notEqual(deriveIndustryId(world, "0xabd"), previous.objectId);
    assert.notEqual(
        deriveIndustryId({ ...world, industryRegistry: "0x655" }, assemblyId),
        previous.objectId
    );
    assert.throws(() => objectId("0xinvalid"));
});

test("PTBs call constructors then atomic create or revision-checked sync", () => {
    const create = buildIndustryTransaction(world, assemblyId, empty, "1002", null).getData();
    const update = buildIndustryTransaction(world, assemblyId, empty, "1002", previous).getData();
    const calls = (data: typeof create) =>
        data.commands.filter((c) => c.$kind === "MoveCall").map((c) => c.MoveCall!.function);
    assert.deepEqual(calls(create), ["new_snapshot", "idle_production", "create_with_production"]);
    assert.deepEqual(calls(update), ["new_snapshot", "idle_production", "sync_with_production"]);
    assert.throws(
        () => buildIndustryTransaction(world, assemblyId, empty, "1000", previous),
        /newer/
    );
    assert.throws(
        () => buildIndustryTransaction(world, "0xabd", empty, "1002", previous),
        /different facility/
    );
    const sync = update.commands.at(-1)!.MoveCall!;
    const revisionArg = sync.arguments[3];
    assert.equal(revisionArg.$kind, "Input");
    if (revisionArg.$kind === "Input")
        assert.deepEqual(update.inputs[revisionArg.Input].Pure, { bytes: "AwAAAAAAAAA=" });
});

test("read reports absence but propagates transport/type/parent failures", async () => {
    const client = (value: any) => ({ getObject: async ({ id }: any) => id === deriveProductionFieldId(previous.objectId)
        ? { error: { code: "notExists" } } : value });
    assert.equal(
        await readIndustry(client({ error: { code: "notExists" } }), world, assemblyId),
        null
    );
    await assert.rejects(
        readIndustry(client({ error: { code: "deleted" } }), world, assemblyId),
        /deleted/
    );
    const value = {
        data: {
            owner: { Shared: { initial_shared_version: "1" } },
            content: {
                dataType: "moveObject",
                type: `${objectId(world.packageId)}::smart_industry::SmartIndustry`,
                fields: {
                    assembly_id: assemblyId,
                    revision: "3",
                    observed_at_ms: "1000",
                    synced_at_ms: "1001",
                    assembly_status: 1,
                    snapshot: { fields: empty },
                },
            },
        },
    };
    assert.deepEqual(await readIndustry(client(value), world, assemblyId), previous);
    value.data.content.fields.assembly_id = objectId("0x999");
    await assert.rejects(readIndustry(client(value), world, assemblyId), /parent mismatch/);
});

test("upgrades preserve type-origin IDs while using the latest function target", () => {
    const upgraded = { ...world, industryPackageId: "0x222", industryTypeOrigin: "0x111" };
    const firstVersion = { ...world, industryPackageId: "0x111" };
    assert.equal(
        deriveIndustryId(upgraded, assemblyId),
        deriveIndustryId(firstVersion, assemblyId)
    );
    assert.notEqual(deriveIndustryId(upgraded, assemblyId), deriveIndustryId(world, assemblyId));
    const data = buildIndustryTransaction(
        upgraded,
        assemblyId,
        {
            ...empty,
            blueprint_id: "1007",
            run_time: "12",
            inputs: [{ type_id: "95345", quantity: "10" }],
            blueprint_inputs: [{ type_id: "95345", quantity: "1", max_quantity: "400" }],
            blueprint_outputs: [{ type_id: "83463", quantity: "1", max_quantity: "500" }],
        },
        "1002",
        null
    ).getData();
    const calls = data.commands.filter((c) => c.$kind === "MoveCall").map((c) => c.MoveCall!);
    assert.deepEqual(
        calls.map((c) => c.function),
        ["new_item_stack", "new_recipe_slot", "new_recipe_slot", "new_snapshot", "idle_production", "create_with_production"]
    );
    assert.ok(calls.every((c) => c.package === objectId("0x222")));
    const vectors = data.commands
        .filter((c) => c.$kind === "MakeMoveVec")
        .map((c) => c.MakeMoveVec!);
    assert.ok(vectors.every((v) => v.type?.startsWith(`${objectId("0x111")}::smart_industry::`)));
});

test("production builds finite and continuous runs while rejecting inconsistent stopped jobs", () => {
    const production = { job_id: "7", state: "RUNNING", requested_runs: "3", completed_runs: "1",
        run_started_at_ms: "1000", run_end_at_ms: "13000", stop_reason: null };
    assert.deepEqual(parseIndustryProduction(production), production);
    assert.equal(parseIndustryProduction({ ...production, requested_runs: null })?.requested_runs, null);
    for (const change of [{ requested_runs: "0" }, { completed_runs: "3" }, { job_id: 0 },
        { run_end_at_ms: "1000" }, { state: "STOPPED" }, { state: "STOPPED", stop_reason: "COMPLETED" }]) {
        assert.throws(() => parseIndustryProduction({ ...production, ...change }));
    }
    const snapshot = { ...empty, blueprint_id: "1007", run_time: "12" };
    const data = buildIndustryTransaction(world, assemblyId, snapshot, "1002", previous, production).getData();
    const calls = data.commands.filter(c => c.$kind === "MoveCall").map(c => c.MoveCall!.function);
    assert.deepEqual(calls, ["new_snapshot", "new_production", "sync_with_production"]);
    assert.throws(() => buildIndustryTransaction(world, assemblyId, empty, "1002", previous, production), /blueprint/);
});

test("production reads require the sidecar owner and matching inventory revision", async () => {
    const production = { job_id: "7", state: 2, requested_runs: "3", completed_runs: "1",
        run_started_at_ms: "1000", run_end_at_ms: "13000", stop_reason: "" };
    const record = { revision: "3", production: { fields: production } };
    const owner = { ObjectOwner: previous.objectId };
    const client = { getObject: async ({ id }: any) => id === deriveProductionFieldId(previous.objectId) ? {
        data: { owner, content: { dataType: "moveObject", type: `0x2::dynamic_field::Field<u8, ${objectId("0x555")}::smart_industry::ProductionRecord>`,
            fields: { name: 0, value: { fields: record } } } },
    } : { data: { owner: { Shared: { initial_shared_version: "1" } }, content: {
        dataType: "moveObject", type: `${objectId(world.packageId)}::smart_industry::SmartIndustry`, fields: {
            assembly_id: assemblyId, revision: "3", observed_at_ms: "1000", synced_at_ms: "1001", assembly_status: 2,
            snapshot: { fields: { ...empty, blueprint_id: "1007", run_time: "12" } },
        },
    } } } };
    const result = await readIndustry(client as any, world, assemblyId);
    assert.equal(result?.productionMirrored, true);
    assert.equal(result?.production?.state, "DISCONTINUING");
    record.revision = "4";
    await assert.rejects(readIndustry(client as any, world, assemblyId), /revision changed/);
    assert.equal((await readIndustry(client as any, world, assemblyId, true))?.productionMirrored, false);
    record.revision = "3";
    owner.ObjectOwner = objectId("0xdead");
    await assert.rejects(readIndustry(client as any, world, assemblyId), /production field/);
});
