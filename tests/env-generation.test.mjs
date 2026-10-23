import assert from "node:assert/strict";
import {
    chmodSync,
    existsSync,
    mkdirSync,
    mkdtempSync,
    readFileSync,
    rmSync,
    writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import test from "node:test";

const generator = fileURLToPath(
    new URL("../../builder-scaffold/docker/scripts/generate-world-env.sh", import.meta.url)
);
const shellAvailable =
    process.platform !== "win32" &&
    spawnSync("bash", ["-c", "exit 0"], { timeout: 5000 }).status === 0;
const skip = !existsSync(generator) || !shellAvailable;

test(
    "env generation selects explicit keys, current Sui keys, then the legacy export",
    { skip },
    (t) => {
        const fixture = mkdtempSync(join(tmpdir(), "world env selection "));
        t.after(() => rmSync(fixture, { recursive: true, force: true }));
        const configDir = join(fixture, "sui-config");
        mkdirSync(configDir);
        const currentKeys = join(configDir, ".env.sui");
        const legacyKeys = join(fixture, "legacy.env.sui");
        const explicitKeys = join(fixture, "explicit.env.sui");
        const source = readFileSync(generator, "utf8");
        // Isolate the fixed legacy path so this test never reads real container keys.
        const fixtureGenerator = join(fixture, "generate-world-env.sh");
        assert.ok(source.includes("/workspace/builder-scaffold/docker/.env.sui"));
        writeFileSync(
            fixtureGenerator,
            source.replaceAll("/workspace/builder-scaffold/docker/.env.sui", legacyKeys)
        );
        writeFileSync(
            join(fixture, "env.example"),
            [
                "SUI_NETWORK=",
                "ADMIN_ADDRESS=",
                "SPONSOR_ADDRESSES=",
                "ADMIN_PRIVATE_KEY=",
                "GOVERNOR_PRIVATE_KEY=",
                "PLAYER_A_PRIVATE_KEY=",
                "PLAYER_B_PRIVATE_KEY=",
                "",
            ].join("\n")
        );
        for (const [path, label] of [
            [currentKeys, "current"],
            [legacyKeys, "legacy"],
            [explicitKeys, "explicit"],
        ]) {
            writeFileSync(
                path,
                [
                    "SUI_NETWORK=localnet",
                    `ADMIN_ADDRESS=0xfake_${label}`,
                    `ADMIN_PRIVATE_KEY=fake_${label}_key`,
                    "PLAYER_A_PRIVATE_KEY=fake_player_a",
                    "PLAYER_B_PRIVATE_KEY=fake_player_b",
                    "",
                ].join("\n")
            );
        }
        const environment = { ...process.env, SUI_CONFIG_DIR: configDir };
        delete environment.ENV_SUI;
        function run(overrides = {}) {
            return spawnSync("bash", [fixtureGenerator, fixture], {
                encoding: "utf8",
                env: { ...environment, ...overrides },
                timeout: 10000,
            });
        }
        const explicit = run({ ENV_SUI: explicitKeys });
        assert.equal(explicit.status, 0, explicit.stderr);
        assert.match(readFileSync(join(fixture, ".env"), "utf8"), /ADMIN_ADDRESS=0xfake_explicit/);
        const current = run();
        assert.equal(current.status, 0, current.stderr);
        assert.match(readFileSync(join(fixture, ".env"), "utf8"), /ADMIN_ADDRESS=0xfake_current/);
        const missingExplicit = run({ ENV_SUI: join(fixture, "missing.env") });
        assert.notEqual(
            missingExplicit.status,
            0,
            "An explicit missing file must not fall back to different keys"
        );
        rmSync(currentKeys);
        const legacy = run();
        assert.equal(legacy.status, 0, legacy.stderr);
        assert.match(readFileSync(join(fixture, ".env"), "utf8"), /ADMIN_ADDRESS=0xfake_legacy/);
    }
);

test(
    "Compose persists the same Sui configuration directory used by the image",
    { skip: !existsSync(generator) },
    () => {
        const dockerfile = readFileSync(
            new URL("../../builder-scaffold/docker/Dockerfile", import.meta.url),
            "utf8"
        );
        const compose = readFileSync(
            new URL("../../builder-scaffold/docker/compose.yml", import.meta.url),
            "utf8"
        );
        const configDir = dockerfile.match(/^ENV SUI_CONFIG_DIR=(.+)$/m)?.[1]?.trim();
        assert.ok(configDir, "Dockerfile must declare the Sui configuration directory");
        assert.ok(
            compose.split(/\r?\n/).some((line) => line.trim() === `- sui-config:${configDir}`),
            "The named volume must cover the directory where the entrypoint writes keys"
        );
    }
);

for (const lineEnding of ["\n", "\r\n"]) {
    for (const finalNewline of [false, true]) {
        test(
            `world env generation normalizes ${lineEnding === "\n" ? "LF" : "CRLF"} inputs, final newline ${finalNewline}`,
            { skip },
            (t) => {
                const fixture = mkdtempSync(join(tmpdir(), "world env generator "));
                t.after(() => rmSync(fixture, { recursive: true, force: true }));
                const sourcePath = join(fixture, "keys.env");
                const templatePath = join(fixture, "env.example");
                const source =
                    [
                        "# Fake test keys, never usable on chain",
                        "SUI_NETWORK=localnet",
                        "ADMIN_ADDRESS=0xfake_admin",
                        "ADMIN_PRIVATE_KEY=fake_admin_key",
                        "PLAYER_A_PRIVATE_KEY=fake_player_a_key",
                        "PLAYER_B_PRIVATE_KEY=fake_player_b_key",
                    ].join(lineEnding) + (finalNewline ? lineEnding : "");
                const template =
                    [
                        "# Template settings must remain intact",
                        "",
                        "SUI_NETWORK=testnet",
                        "ADMIN_ADDRESS=",
                        "SPONSOR_ADDRESSES=",
                        "ADMIN_PRIVATE_KEY=",
                        "GOVERNOR_PRIVATE_KEY=",
                        "PLAYER_A_PRIVATE_KEY=",
                        "PLAYER_B_PRIVATE_KEY=",
                        "",
                        "QUOTED_SETTING='two words'",
                        'URL_SETTING="https://example.invalid/?one=1&two=2"',
                        "LAST_SETTING=preserved",
                    ].join(lineEnding) + (finalNewline ? lineEnding : "");
                writeFileSync(sourcePath, source);
                writeFileSync(templatePath, template);
                chmodSync(sourcePath, 0o444);
                chmodSync(templatePath, 0o444);

                const generated = spawnSync("bash", [generator, fixture], {
                    encoding: "utf8",
                    env: { ...process.env, ENV_SUI: sourcePath },
                    timeout: 10000,
                });
                assert.equal(generated.status, 0, generated.stderr);
                assert.doesNotMatch(
                    generated.stdout + generated.stderr,
                    /fake_admin_key|fake_player_[ab]_key/
                );
                const outputPath = join(fixture, ".env");
                const output = readFileSync(outputPath, "utf8");
                assert.equal(output.includes("\r"), false);
                assert.equal(output.endsWith("\n"), finalNewline);
                assert.equal(readFileSync(sourcePath, "utf8"), source);
                assert.equal(readFileSync(templatePath, "utf8"), template);
                assert.ok(output.includes("\n\nQUOTED_SETTING='two words'\n"));
                assert.ok(output.includes('URL_SETTING="https://example.invalid/?one=1&two=2"'));

                const loaded = spawnSync(
                    "bash",
                    [
                        "-c",
                        [
                            "set -eu",
                            'source "$1"',
                            'test "$SUI_NETWORK" = localnet',
                            'test "$ADMIN_ADDRESS" = 0xfake_admin',
                            'test "$SPONSOR_ADDRESSES" = 0xfake_admin',
                            'test "$ADMIN_PRIVATE_KEY" = fake_admin_key',
                            'test "$GOVERNOR_PRIVATE_KEY" = fake_admin_key',
                            'test "$PLAYER_A_PRIVATE_KEY" = fake_player_a_key',
                            'test "$PLAYER_B_PRIVATE_KEY" = fake_player_b_key',
                            'test "$QUOTED_SETTING" = "two words"',
                            'test "$URL_SETTING" = "https://example.invalid/?one=1&two=2"',
                            'test "$LAST_SETTING" = preserved',
                        ].join("\n"),
                        "env-test",
                        outputPath,
                    ],
                    { encoding: "utf8", timeout: 10000 }
                );
                assert.equal(loaded.status, 0, loaded.stderr);
            }
        );
    }
}
