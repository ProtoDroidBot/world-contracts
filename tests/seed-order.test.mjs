import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";
import { fileURLToPath } from "node:url";

const repositoryRoot = fileURLToPath(new URL("..", import.meta.url));

function commandSequence(relativePath) {
  const source = readFileSync(`${repositoryRoot}/${relativePath}`, "utf8");
  const commands = source.match(/commands=\(\s*([\s\S]*?)\n\s*\)/);

  assert.ok(commands, `${relativePath} must define a commands array`);
  return commands[1].trim().split(/\s+/);
}

test("efctl links legacy Smart Gates before bringing them online", () => {
  const commands = commandSequence("scripts/efctl-world.sh");
  const create = commands.indexOf("gate/create-gates");
  const link = commands.indexOf("gate/link-gates");
  const online = commands.indexOf("gate/online");

  assert.notEqual(create, -1);
  assert.notEqual(link, -1);
  assert.notEqual(online, -1);
  assert.ok(create < link, "gates must exist before they are linked");
  assert.ok(link < online, "gate::link_gates requires both gates to be offline");
});

test("the gate-link proof is bound to the two gates", () => {
  const source = readFileSync(
    `${repositoryRoot}/ts-scripts/gate/link-gates.ts`,
    "utf8",
  );
  const call = source.match(/generateLocationProof\(([\s\S]*?)\);/);

  assert.ok(call, "link-gates.ts must generate a location proof");
  assert.equal(
    call[1].replace(/\s+/g, ""),
    "adminKeypair,playerCtx.address,gateAId,gateBId,LOCATION_HASH",
  );
});
