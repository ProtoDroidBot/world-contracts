import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";

import {
    buildUpgradedFeatureDeployment,
    commitFeatureUpgrade,
    findUpgradeCapId,
} from "../ts-scripts/utils/update-feature-deployment";

const address = (character: string) => `0x${character.repeat(64)}`;

test("feature upgrade changes only the callable package identity", () => {
    const deployment = {
        format: "eve-frontier-world-features",
        schemaVersion: 1,
        chainId: "a1b2c3d4",
        world: { packageId: address("1") },
        capabilities: {
            smartIndustry: {
                status: "deployed",
                packageId: address("2"),
                typeOrigin: address("3"),
                registryId: address("4"),
            },
        },
        unrelated: { preserved: true },
    };
    const upgraded = buildUpgradedFeatureDeployment(
        deployment,
        "smart_industry",
        address("5"),
    );
    assert.equal(upgraded.capabilities.smartIndustry.packageId, address("5"));
    assert.equal(upgraded.capabilities.smartIndustry.typeOrigin, address("3"));
    assert.equal(upgraded.capabilities.smartIndustry.registryId, address("4"));
    assert.deepEqual(upgraded.unrelated, { preserved: true });
    assert.equal(deployment.capabilities.smartIndustry.packageId, address("2"));
});

test("feature upgrade rejects legacy manifests and unchanged package IDs", () => {
    const deployment = {
        format: "eve-frontier-world-features", schemaVersion: 1,
        capabilities: { smartIndustry: {
            status: "deployed", packageId: address("2"),
            typeOrigin: address("2"), registryId: address("4"),
        } },
    };
    assert.throws(() => buildUpgradedFeatureDeployment(
        deployment,
        "smart_industry",
        address("2"),
    ), /new package/);
    assert.throws(() => buildUpgradedFeatureDeployment(
        { schemaVersion: 1 },
        "smart_industry",
        address("5"),
    ), /world-features-v1/);
});

test("upgrade-cap discovery uses the package capability object", () => {
    assert.equal(findUpgradeCapId({ objectChanges: [
        { type: "created", objectType: "0x2::package::UpgradeCap", objectId: address("a") },
    ] }), address("a"));
    assert.throws(() => findUpgradeCapId({ objectChanges: [] }), /UpgradeCap/);
});

test("feature commit recovers a staged extracted ID and preserves the type origin", (t) => {
    const root = fs.mkdtempSync(path.join(os.tmpdir(), "feature-upgrade-"));
    t.after(() => fs.rmSync(root, { recursive: true, force: true }));
    const deploymentDir = path.join(root, "deployments", "localnet");
    fs.mkdirSync(deploymentDir, { recursive: true });
    const current = address("2");
    const next = address("5");
    const origin = address("3");
    const registry = address("4");
    fs.writeFileSync(path.join(deploymentDir, "world-features.v1.json"), JSON.stringify({
        format: "eve-frontier-world-features",
        schemaVersion: 1,
        chainId: "a1b2c3d4",
        world: { packageId: address("1"), objectRegistryId: address("6"), adminAclId: address("7") },
        capabilities: { smartIndustry: {
            status: "deployed", packageId: current,
            typeOrigin: origin, registryId: registry,
        } },
    }));
    // Simulate a crash after extracted IDs were staged but before the public
    // deployment manifest became callable.
    fs.writeFileSync(path.join(deploymentDir, "extracted-object-ids.json"), JSON.stringify({
        features: { smartIndustry: { packageId: next, registryId: registry } },
    }));
    fs.writeFileSync(path.join(deploymentDir, "world_smart_industry_package.json"), JSON.stringify({
        objectChanges: [
            { type: "published", packageId: origin, modules: ["smart_industry"] },
            { type: "created", objectType: "0x2::package::UpgradeCap", objectId: address("a") },
        ],
    }));
    const output = path.join(root, "upgrade.json");
    fs.writeFileSync(output, JSON.stringify({
        objectChanges: [
            { type: "published", packageId: next, modules: ["smart_industry"] },
        ],
    }));

    const result = commitFeatureUpgrade({
        root, network: "localnet", featureName: "smart_industry",
        upgradeOutputPath: output,
    });
    assert.equal(result.manifest.capabilities.smartIndustry.packageId, next);
    assert.equal(result.manifest.capabilities.smartIndustry.typeOrigin, origin);
    assert.equal(JSON.parse(fs.readFileSync(
        path.join(deploymentDir, "extracted-object-ids.json"), "utf8",
    )).features.smartIndustry.packageId, next);
});
