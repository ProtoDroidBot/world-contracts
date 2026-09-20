import assert from "node:assert/strict";
import { existsSync, readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { test } from "node:test";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const workspace = path.resolve(root, "../..");
const metersPerLightYear = 9_460_730_472_580_800n;
const expectedRanges = new Map([[88086, 65n], [84955, 365n], [95627, 65n], [95677, 365n]]);

function gateDistances(file) {
  const content = readFileSync(file, "utf8");
  const values = name => {
    const line = content.match(new RegExp(`^${name}=([^\\r\\n]*)$`, "m"));
    assert.ok(line, `${name} must be configured`);
    return line[1].split(",").map(value => value.trim());
  };
  const types = values("GATE_TYPE_IDS");
  const distances = values("MAX_DISTANCES");
  assert.equal(types.length, distances.length);
  assert.equal(new Set(types).size, types.length);
  return new Map(types.map((type, index) => {
    assert.match(type, /^\d+$/);
    assert.match(distances[index], /^\d+$/);
    const meters = BigInt(distances[index]);
    assert.ok(meters > 0n && meters <= (1n << 64n) - 1n);
    return [Number(type), meters];
  }));
}

test("deployment defaults configure Smart Gates and Smart Catapults with exact u64 meter values", () => {
  const actual = gateDistances(path.join(root, "env.example"));
  assert.deepEqual([...actual.keys()], [...expectedRanges.keys()]);
  for (const [typeId, lightYears] of expectedRanges) {
    assert.equal(actual.get(typeId), lightYears * metersPerLightYear);
  }
});

const componentsFile = path.join(workspace, "EveJS-Frontier/_local/frontier-sde/3502403/spaceComponentsByType.jsonl");
test("deployment defaults match the extracted build 3502403 client gate components", {
  skip: !existsSync(componentsFile) && "Extracted Frontier client build 3502403 is not available",
}, () => {
  const components = new Map(readFileSync(componentsFile, "utf8").trim().split(/\r?\n/)
    .map(line => JSON.parse(line)).map(row => [row._key, row]));
  for (const [typeId, meters] of gateDistances(path.join(root, "env.example"))) {
    const range = components.get(typeId)?.smartGate?.range;
    assert.ok(Number.isSafeInteger(range) && range > 0, `Gate ${typeId} needs an authored light-year range`);
    assert.equal(meters, BigInt(range) * metersPerLightYear, `Gate ${typeId} must match the client`);
  }
});

const copiedDefaults = path.join(workspace, "smart-assembly-control/world-contracts/env.example");
test("the standalone control reference checkout retains matching deployment defaults", {
  skip: !existsSync(copiedDefaults) && "The optional standalone control checkout is not available",
}, () => {
  assert.deepEqual(gateDistances(copiedDefaults), gateDistances(path.join(root, "env.example")));
});
