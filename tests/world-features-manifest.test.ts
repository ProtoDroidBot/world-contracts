import assert from "node:assert/strict";
import test from "node:test";

import {
    assertPublishedModule,
    buildSplitFactionFeatureConfiguration,
    buildFreshWorldFeatureManifest,
    migrateLegacyNpcDeployment,
} from "../ts-scripts/utils/write-world-features";

const PACKAGE = `0x${"1".repeat(64)}`;
const REGISTRY = `0x${"2".repeat(64)}`;
const ACL = `0x${"3".repeat(64)}`;
const NPC_PACKAGE = `0x${"9".repeat(64)}`;
const NPC_REGISTRY = `0x${"a".repeat(64)}`;
const ACCESS_PACKAGE = `0x${"b".repeat(64)}`;
const ACCESS_REGISTRY = `0x${"c".repeat(64)}`;
const CATAPULT_PACKAGE = `0x${"d".repeat(64)}`;
const CATAPULT_REGISTRY = `0x${"e".repeat(64)}`;
const INDUSTRY_PACKAGE = `0x${"4".repeat(64)}`;
const INDUSTRY_REGISTRY = `0x${"5".repeat(64)}`;
const TRANSPONDER_PACKAGE = `0x${"6".repeat(64)}`;
const TRANSPONDER_REGISTRY = `0x${"7".repeat(64)}`;
const ACTION_PACKAGE = `0x${"8".repeat(64)}`;
const ACTION_REGISTRY = `0x${"f".repeat(64)}`;
const INDUSTRY_ACTIONS_PACKAGE = `0x${"a".repeat(64)}`;
const INDUSTRY_ACTIONS_REGISTRY = `0x${"d".repeat(64)}`;
const LOGISTICS_PACKAGE = `0x${"01".repeat(32)}`;
const LOGISTICS_REGISTRY = `0x${"02".repeat(32)}`;
const INFRASTRUCTURE_PACKAGE = `0x${"03".repeat(32)}`;
const INFRASTRUCTURE_REGISTRY = `0x${"04".repeat(32)}`;
const AUTOMATION_PACKAGE = `0x${"05".repeat(32)}`;
const AUTOMATION_REGISTRY = `0x${"06".repeat(32)}`;
const IDS = {
    network: "localnet",
    world: {
        packageId: PACKAGE,
        governorCap: `0x${"4".repeat(64)}`,
        serverAddressRegistry: `0x${"5".repeat(64)}`,
        objectRegistry: REGISTRY,
        adminAcl: ACL,
        energyConfig: `0x${"6".repeat(64)}`,
        fuelConfig: `0x${"7".repeat(64)}`,
        gateConfig: `0x${"8".repeat(64)}`,
    },
    features: {
        npc: { packageId: NPC_PACKAGE, registryId: NPC_REGISTRY },
        catapult: { packageId: CATAPULT_PACKAGE, registryId: CATAPULT_REGISTRY },
        smartIndustry: { packageId: INDUSTRY_PACKAGE, registryId: INDUSTRY_REGISTRY },
        transponder: { packageId: TRANSPONDER_PACKAGE, registryId: TRANSPONDER_REGISTRY },
        assemblyAccess: { packageId: ACCESS_PACKAGE, registryId: ACCESS_REGISTRY },
        actionQueue: { packageId: ACTION_PACKAGE, registryId: ACTION_REGISTRY },
        industryActions: {
            packageId: INDUSTRY_ACTIONS_PACKAGE,
            registryId: INDUSTRY_ACTIONS_REGISTRY,
        },
        logisticsActions: { packageId: LOGISTICS_PACKAGE, registryId: LOGISTICS_REGISTRY },
        infrastructureActions: {
            packageId: INFRASTRUCTURE_PACKAGE,
            registryId: INFRASTRUCTURE_REGISTRY,
        },
        automation: { packageId: AUTOMATION_PACKAGE, registryId: AUTOMATION_REGISTRY },
    },
};

test("fresh world-feature deployment records independent packages, type origins and registries", () => {
    const manifest = buildFreshWorldFeatureManifest(
            "A1B2C3D4",
            IDS,
            PACKAGE,
            NPC_PACKAGE,
            ACCESS_PACKAGE,
            CATAPULT_PACKAGE,
            INDUSTRY_PACKAGE,
            TRANSPONDER_PACKAGE,
            ACTION_PACKAGE,
            INDUSTRY_ACTIONS_PACKAGE,
            LOGISTICS_PACKAGE,
            INFRASTRUCTURE_PACKAGE,
            AUTOMATION_PACKAGE,
        );
    assert.equal(manifest.format, "eve-frontier-world-features");
    assert.equal(manifest.schemaVersion, 1);
    assert.equal(manifest.chainId, "a1b2c3d4");
    assert.deepEqual(manifest.world, {
        packageId: PACKAGE,
        objectRegistryId: REGISTRY,
        adminAclId: ACL,
    });
    assert.deepEqual(manifest.capabilities.npc, {
        status: "deployed", packageId: NPC_PACKAGE,
        typeOrigin: NPC_PACKAGE, registryId: NPC_REGISTRY,
    });
    assert.deepEqual(manifest.capabilities.assemblyAccess, {
        status: "deployed", packageId: ACCESS_PACKAGE,
        typeOrigin: ACCESS_PACKAGE, registryId: ACCESS_REGISTRY,
    });
    assert.deepEqual(manifest.capabilities.automation, {
        status: "deployed", packageId: AUTOMATION_PACKAGE,
        typeOrigin: AUTOMATION_PACKAGE, registryId: AUTOMATION_REGISTRY,
    });
    assert.equal(Object.keys(manifest.capabilities).length, 10);
});

test("legacy migration preserves complete features and isolates incomplete ones", () => {
    const migrated = migrateLegacyNpcDeployment({
        schemaVersion: 3,
        chainId: "A1B2C3D4",
        worldPackageId: PACKAGE,
        objectRegistryId: REGISTRY,
        adminAclId: ACL,
        packageId: NPC_PACKAGE,
        typeOrigin: NPC_PACKAGE,
        npcRegistryId: NPC_REGISTRY,
        accessPackageId: ACCESS_PACKAGE,
        accessTypeOrigin: ACCESS_PACKAGE,
        // Deliberately missing accessRegistryId.
        catapultPackageId: CATAPULT_PACKAGE,
        catapultTypeOrigin: CATAPULT_PACKAGE,
        catapultRegistryId: CATAPULT_REGISTRY,
    });
    assert.equal(migrated.capabilities.npc.packageId, NPC_PACKAGE);
    assert.equal(migrated.capabilities.catapult.registryId, CATAPULT_REGISTRY);
    assert.equal(migrated.capabilities.assemblyAccess, undefined);
    assert.deepEqual(migrated.migration?.incompleteCapabilities, ["assemblyAccess"]);
});

test("split faction configs reference and inherit the default policy", () => {
    const split = buildSplitFactionFeatureConfiguration(
        ["500010-guristas", "500001-caldari"],
        ["transponder", "npc"],
        { "500010-guristas": ["npc"] },
        {
            "500001-caldari": {
                transponderCode: "CALDARI",
                startingRegion: { regionID: 10000005, solarSystemIDs: [30000052] },
                membership: {
                    includedTypeIDs: [101],
                    typeListProfiles: [{
                        profileID: "npc-profiles-by-faction",
                        source: "npcProfiles",
                        match: "factionIdentity",
                    }],
                },
                diplomacy: {
                    enemies: [{ factionKey: "500010-guristas", transponderCode: "GURISTAS" }],
                },
                leadership: [],
                commanders: [],
            },
            "500010-guristas": {
                transponderCode: "GURISTAS",
                diplomacy: {
                    enemies: [{ factionKey: "500001-caldari", transponderCode: "CALDARI" }],
                },
            },
        },
    );
    assert.deepEqual(split.factionConfig.default, {
        id: "default", path: "factions/default.v1.json",
    });
    assert.deepEqual(split.factionConfig.factions["500001-caldari"], {
        path: "factions/500001-caldari.v1.json", fallback: "default",
    });
    assert.deepEqual(split.files["factions/default.v1.json"].capabilities, ["npc", "transponder"]);
    assert.equal("capabilities" in split.files["factions/500001-caldari.v1.json"], false);
    assert.deepEqual(split.files["factions/500010-guristas.v1.json"].capabilities, ["npc"]);
    assert.equal(split.files["factions/500001-caldari.v1.json"].schemaVersion, 2);
    assert.deepEqual(
        (split.files["factions/500001-caldari.v1.json"].membership as any).includedTypeIDs,
        [101],
    );
    assert.deepEqual(split.files["factions/500001-caldari.v1.json"].leadership, []);
    assert.deepEqual(split.files["factions/500001-caldari.v1.json"].startingRegion, {
        regionID: 10000005, solarSystemIDs: [30000052],
    });
    assert.throws(() => buildSplitFactionFeatureConfiguration(
        ["500001-caldari"], ["npc"], {}, {
            "500001-caldari": {
                startingRegion: { regionID: -1, solarSystemIDs: [30000052] },
            },
        },
    ), /invalid starting region ID/);
});

test("fresh world-feature manifest rejects mismatched packages and unsafe identities", () => {
    assert.throws(
        () =>
            buildFreshWorldFeatureManifest(
                "a1b2c3d4",
                IDS,
                `0x${"f".repeat(64)}`,
                NPC_PACKAGE,
                ACCESS_PACKAGE,
                CATAPULT_PACKAGE,
                INDUSTRY_PACKAGE,
                TRANSPONDER_PACKAGE,
                ACTION_PACKAGE,
                INDUSTRY_ACTIONS_PACKAGE,
                LOGISTICS_PACKAGE,
                INFRASTRUCTURE_PACKAGE,
                AUTOMATION_PACKAGE,
            ),
        /different packages/,
    );
    assert.throws(
        () => buildFreshWorldFeatureManifest(
            "not-a-chain", IDS, PACKAGE, NPC_PACKAGE, ACCESS_PACKAGE,
            CATAPULT_PACKAGE, INDUSTRY_PACKAGE, TRANSPONDER_PACKAGE,
            ACTION_PACKAGE, INDUSTRY_ACTIONS_PACKAGE,
            LOGISTICS_PACKAGE, INFRASTRUCTURE_PACKAGE, AUTOMATION_PACKAGE,
        ),
        /chain ID/,
    );
    assert.throws(
        () => buildFreshWorldFeatureManifest("a1b2c3d4", {
            ...IDS,
            world: { ...IDS.world, adminAcl: "0x0" },
        }, PACKAGE, NPC_PACKAGE, ACCESS_PACKAGE, CATAPULT_PACKAGE, INDUSTRY_PACKAGE,
        TRANSPONDER_PACKAGE, ACTION_PACKAGE, INDUSTRY_ACTIONS_PACKAGE,
        LOGISTICS_PACKAGE, INFRASTRUCTURE_PACKAGE, AUTOMATION_PACKAGE),
        /AdminACL/,
    );
});

test("deployment sync validates modules in their independent packages", () => {
    assert.doesNotThrow(() => assertPublishedModule(["npc"], "npc", "NPC"));
    assert.doesNotThrow(() =>
        assertPublishedModule(["assembly_access"], "assembly_access", "Assembly access"),
    );
    assert.doesNotThrow(() => assertPublishedModule(["catapult"], "catapult", "Catapult"));
    assert.doesNotThrow(() =>
        assertPublishedModule(["smart_industry"], "smart_industry", "Smart Industry"),
    );
    assert.doesNotThrow(() =>
        assertPublishedModule(["transponder"], "transponder", "Transponder"),
    );
    assert.doesNotThrow(() =>
        assertPublishedModule(["action_queue"], "action_queue", "Action queue"),
    );
    assert.doesNotThrow(() =>
        assertPublishedModule(["industry_actions"], "industry_actions", "Industry Actions"),
    );
    assert.doesNotThrow(() =>
        assertPublishedModule(["logistics_actions"], "logistics_actions", "Logistics Actions"),
    );
    assert.doesNotThrow(() =>
        assertPublishedModule(
            ["infrastructure_actions"],
            "infrastructure_actions",
            "Infrastructure Actions",
        ),
    );
    assert.doesNotThrow(() =>
        assertPublishedModule(["automation"], "automation", "Automation"),
    );
    assert.throws(() => assertPublishedModule(["character"], "npc", "NPC"), /npc/);
    assert.throws(
        () => assertPublishedModule(["npc"], "assembly_access", "Assembly access"),
        /assembly_access/,
    );
});
