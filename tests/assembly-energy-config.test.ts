import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { test } from "node:test";
import {
    parseAssemblyEnergyManifest,
    planAssemblyEnergyReconciliation,
} from "../ts-scripts/network-node/assembly-energy-config.ts";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const workspace = path.resolve(root, "../..");
const manifest = parseAssemblyEnergyManifest(
    JSON.parse(fs.readFileSync(path.join(root, "config/assembly-energy.json"), "utf8")),
    3502403
);

test("build 3502403 has one sorted energy entry for every on-chain Smart Assembly", () => {
    assert.equal(manifest.clientBuild, 3502403);
    assert.equal(manifest.assemblies.length, 25);
    assert.deepEqual(
        manifest.assemblies.map((entry) => entry.typeID),
        [...manifest.assemblies.map((entry) => entry.typeID)].sort((a, b) => a - b)
    );
    assert.equal(manifest.assemblies.some((entry) => entry.typeID === 84556), false);
    assert.deepEqual(
        manifest.assemblies.find((entry) => entry.typeID === 88092),
        { typeID: 88092, name: "Network Node", energyRequired: 0 }
    );
});

const componentsFile = path.join(
    workspace,
    "EveJS-Frontier/_local/frontier-sde/3502403/spaceComponentsByType.jsonl"
);
test("the manifest exactly covers the extracted server Smart Assembly catalog", {
    skip: !fs.existsSync(componentsFile) && "Extracted Frontier build 3502403 is not available",
}, () => {
    const onChainTypes = fs.readFileSync(componentsFile, "utf8").trim().split(/\r?\n/)
        .map((line) => JSON.parse(line))
        .filter((row) => Number(row.smartDeployable?.createOnChain) === 1)
        .map((row) => Number(row.typeID ?? row._key))
        .sort((a, b) => a - b);
    assert.deepEqual(manifest.assemblies.map((entry) => entry.typeID), onChainTypes);
});

test("reconciliation removes stale and zero-cost rows and updates changed costs", () => {
    assert.deepEqual(planAssemblyEnergyReconciliation([
        { typeID: 84556, energyRequired: 10 },
        { typeID: 77917, energyRequired: 400 },
        { typeID: 88086, energyRequired: 25 },
        { typeID: 90184, energyRequired: 1 },
    ], manifest), {
        remove: [84556, 88086],
        set: manifest.assemblies
            .filter((entry) => entry.energyRequired > 0 && entry.typeID !== 90184)
            .map(({ typeID, energyRequired }) => ({ typeID, energyRequired })),
    });
});

test("manifest parsing rejects duplicates, unsafe costs, and build drift", () => {
    const value = structuredClone(manifest);
    value.assemblies[1].typeID = value.assemblies[0].typeID;
    assert.throws(() => parseAssemblyEnergyManifest(value, 3502403), /duplicate|sorted/);
    assert.throws(() => parseAssemblyEnergyManifest({ ...manifest, clientBuild: 1 }, 3502403), /does not match/);
    assert.throws(() => parseAssemblyEnergyManifest({
        ...manifest,
        assemblies: [{ ...manifest.assemblies[0], energyRequired: -1 }],
    }, 3502403), /energyRequired/);
});
