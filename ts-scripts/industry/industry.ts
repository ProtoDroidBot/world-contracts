import "dotenv/config";
import { readFileSync, statSync } from "node:fs";
import { parseArgs } from "node:util";
import { createClient, keypairFromPrivateKey } from "../utils/client";
import { loadExtractedObjectIds } from "../utils/helper";
import { DEFAULT_RPC_URLS, type Network } from "../utils/config";
import {
    buildIndustryTransaction,
    deriveIndustryId,
    readIndustry,
    type IndustryWorld,
} from "./client";
import { parseIndustrySnapshot, parseIndustryProduction, parseIndustryLaneStates, u64 } from "./snapshot";

async function main() {
    const { positionals, values } = parseArgs({
        allowPositionals: true,
        options: {
            assembly: { type: "string" },
            snapshot: { type: "string" },
            execute: { type: "boolean", default: false },
            help: { type: "boolean", default: false },
        },
    });
    if (values.help) {
        console.log(
            "npm run industry -- read --assembly <assembly-object-id>\n" +
                "npm run industry -- sync --assembly <assembly-object-id> --snapshot <file.json> [--execute]\n" +
                "Snapshot file: {observed_at_ms, lanes: [{lane_id, snapshot: {owner_id, solar_system_id, blueprint_id, run_time, inputs, outputs, blueprint_inputs, blueprint_outputs}, production}]} (legacy snapshot/production is accepted as lane one)\n" +
                "Sync prints a transaction plan unless --execute is provided. Live game sync uses the EveJS worker."
        );
        return;
    }
    if (
        positionals.length !== 1 ||
        !["read", "sync"].includes(positionals[0]) ||
        !values.assembly
    ) {
        throw new Error("Specify read or sync and --assembly. Use --help for details.");
    }
    if (positionals[0] === "read" && (values.snapshot || values.execute))
        throw new Error("read does not accept --snapshot or --execute");
    const network = process.env.SUI_NETWORK || "localnet";
    if (!(network in DEFAULT_RPC_URLS)) throw new Error("Unsupported SUI_NETWORK");
    const extracted = loadExtractedObjectIds(network);
    const packageId = process.env.WORLD_PACKAGE_ID || extracted?.world.packageId;
    if (!packageId || !extracted?.world || extracted.world.packageId !== packageId) {
        throw new Error(
            "Missing or mismatched extracted-object-ids.json. Run extract-object-ids for this deployment."
        );
    }
    const world: IndustryWorld = {
        packageId,
        objectRegistry: extracted.world.objectRegistry,
        adminAcl: extracted.world.adminAcl,
        industryRegistry:
            process.env.SMART_INDUSTRY_REGISTRY_ID ||
            extracted.features?.smartIndustry.registryId ||
            "",
        industryPackageId:
            process.env.SMART_INDUSTRY_PACKAGE_ID ||
            extracted.features?.smartIndustry.packageId,
        industryTypeOrigin:
            process.env.SMART_INDUSTRY_TYPE_ORIGIN ||
            extracted.features?.smartIndustry.packageId,
    };
    if (!world.industryRegistry || !world.industryPackageId || !world.industryTypeOrigin) {
        throw new Error("Smart Industry package or registry IDs are missing from extracted-object-ids.json");
    }
    const client = createClient(network as Network);
    const previous = await readIndustry(client, world, values.assembly, positionals[0] === "sync");
    if (positionals[0] === "read") {
        console.log(
            JSON.stringify(
                previous ?? {
                    objectId: deriveIndustryId(world, values.assembly),
                    status: "not_synced",
                },
                null,
                2
            )
        );
        return;
    }
    if (!values.snapshot) throw new Error("sync requires --snapshot <file.json>");
    if (statSync(values.snapshot).size > 256 * 1024)
        throw new Error("Snapshot file exceeds 256 KiB");
    const document = JSON.parse(readFileSync(values.snapshot, "utf8"));
    const observedAtMs = u64(document.observed_at_ms, "observed_at_ms", true);
    const lanes = document.lanes === undefined ? undefined : parseIndustryLaneStates(document.lanes);
    const snapshot = parseIndustrySnapshot(document.snapshot ?? lanes?.[0]?.snapshot);
    const production = parseIndustryProduction(document.production ?? lanes?.[0]?.production);
    const tx = buildIndustryTransaction(
        world,
        values.assembly,
        snapshot,
        observedAtMs,
        previous,
        production,
        undefined,
        lanes,
    );
    if (!values.execute) {
        console.log(
            JSON.stringify(
                {
                    network,
                    operation: previous ? "sync" : "create",
                    objectId: deriveIndustryId(world, values.assembly),
                    expectedRevision: previous?.revision ?? "0",
                    observedAtMs,
                    snapshot,
                    production,
                    lanes,
                    transaction: tx.getData(),
                },
                null,
                2
            )
        );
        return;
    }
    const privateKey = process.env.ADMIN_PRIVATE_KEY;
    if (!privateKey) throw new Error("ADMIN_PRIVATE_KEY is required to execute a sync");
    const result = await client.signAndExecuteTransaction({
        transaction: tx,
        signer: keypairFromPrivateKey(privateKey),
        options: { showEffects: true, showEvents: true },
    });
    if (result.effects?.status.status !== "success")
        throw new Error(
            `Smart Industry sync failed: ${result.effects?.status.error ?? "missing execution effects"}`
        );
    await client.waitForTransaction({ digest: result.digest });
    console.log(
        JSON.stringify(
            { digest: result.digest, state: await readIndustry(client, world, values.assembly) },
            null,
            2
        )
    );
}

main().catch((error: unknown) => {
    console.error(error instanceof Error ? error.message : String(error));
    process.exitCode = 1;
});
