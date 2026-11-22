import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { chmodSync, copyFileSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { test } from "node:test";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
// Run these shell tests in the Linux development/CI container.
const shellUnavailable = process.platform === "win32" || spawnSync("bash", ["--version"]).status !== 0;
const envText = [
    "",
    "# Fake credentials; no real environment files are read by these fixtures.",
    "SUI_NETWORK=localnet",
    'SUI_RPC_URL="http://127.0.0.1:9000"',
    "ADMIN_PRIVATE_KEY='fake-test-key'",
    'TEST_LABEL="quoted value with spaces" # preserve quoting and comments',
    "TEST_LAST=tail",
].join("\r\n");
const verifyExports = `
bash -c '[[ "$SUI_NETWORK" == localnet && "$SUI_RPC_URL" == http://127.0.0.1:9000 &&
    "$ADMIN_PRIVATE_KEY" == fake-test-key && "$TEST_LABEL" == "quoted value with spaces" &&
    "$TEST_LAST" == tail ]]'
`;

function fixture(t, text = envText) {
    const dir = mkdtempSync(path.join(os.tmpdir(), "world-env-loader-"));
    t.after(() => rmSync(dir, { recursive: true, force: true }));
    mkdirSync(path.join(dir, "scripts"));
    copyFileSync(path.join(root, "scripts/lib.sh"), path.join(dir, "scripts/lib.sh"));
    if (text !== null) {
        writeFileSync(path.join(dir, ".env"), text);
        chmodSync(path.join(dir, ".env"), 0o444);
    }
    return dir;
}

function run(script, dir) {
    return spawnSync("bash", ["-euo", "pipefail", "-c", script], {
        cwd: dir,
        encoding: "utf8",
        env: { ...process.env, TEST_ENV_DIR: dir },
        timeout: 10000,
    });
}

for (const [label, text] of [["CRLF", envText], ["LF", envText.replaceAll("\r\n", "\n")]]) {
    test(`deployment setup loads a read-only ${label} .env without changing it`, { skip: shellUnavailable }, (t) => {
        const dir = fixture(t, text);
        const result = run(`source ./scripts/lib.sh\nsetup\n${verifyExports}`, dir);
        assert.equal(result.status, 0, result.stderr || result.stdout);
        assert.equal(readFileSync(path.join(dir, ".env"), "utf8"), text);
    });
}

test("deployment setup permits environment-only configuration without .env", { skip: shellUnavailable }, (t) => {
    const dir = fixture(t, null);
    const result = run("source ./scripts/lib.sh\nsetup", dir);
    assert.equal(result.status, 0, result.stderr || result.stdout);
});

test("Docker entrypoint accepts read-only CRLF env before configuring Sui", { skip: shellUnavailable }, (t) => {
    const dir = fixture(t);
    const source = readFileSync(path.join(root, "docker/entrypoint.sh"), "utf8");
    const boundary = source.indexOf('sui_init_config "$ENV" "$RPC_URL"');
    assert.ok(boundary > 0, "exercise the entrypoint's complete env loading and network selection");
    // Point the entrypoint at the fixture's lib.sh before it creates Sui configuration.
    const prelude = source.slice(0, boundary).replace(
        /^source \/app\/scripts\/lib\.sh$/m,
        'source "$TEST_ENV_DIR/scripts/lib.sh"'
    );
    const result = run(`${prelude}\n${verifyExports}`, dir);
    assert.equal(result.status, 0, result.stderr || result.stdout);
    assert.match(result.stdout, /Environment : localnet\n/);
    assert.match(result.stdout, /RPC URL     : http:\/\/127\.0\.0\.1:9000\n/);
    assert.equal(readFileSync(path.join(dir, ".env"), "utf8"), envText);
});
