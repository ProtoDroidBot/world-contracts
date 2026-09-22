import assert from "node:assert/strict";
import test from "node:test";

import {
    assertPublishedModule,
    buildFreshNpcDeployment,
} from "../ts-scripts/utils/write-npc-deployment";

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

test("fresh NPC deployment records independent packages, type origins and registries", () => {
    assert.deepEqual(
        buildFreshNpcDeployment(
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
        ),
        {
            schemaVersion: 3,
            chainId: "a1b2c3d4",
            worldPackageId: PACKAGE,
            objectRegistryId: REGISTRY,
            adminAclId: ACL,
            packageId: NPC_PACKAGE,
            typeOrigin: NPC_PACKAGE,
            npcRegistryId: NPC_REGISTRY,
            accessPackageId: ACCESS_PACKAGE,
            accessTypeOrigin: ACCESS_PACKAGE,
            accessRegistryId: ACCESS_REGISTRY,
            catapultPackageId: CATAPULT_PACKAGE,
            catapultTypeOrigin: CATAPULT_PACKAGE,
            catapultRegistryId: CATAPULT_REGISTRY,
            industryPackageId: INDUSTRY_PACKAGE,
            industryTypeOrigin: INDUSTRY_PACKAGE,
            industryRegistryId: INDUSTRY_REGISTRY,
            transponderPackageId: TRANSPONDER_PACKAGE,
            transponderTypeOrigin: TRANSPONDER_PACKAGE,
            transponderRegistryId: TRANSPONDER_REGISTRY,
            actionPackageId: ACTION_PACKAGE,
            actionTypeOrigin: ACTION_PACKAGE,
            actionRegistryId: ACTION_REGISTRY,
            industryActionsPackageId: INDUSTRY_ACTIONS_PACKAGE,
            industryActionsTypeOrigin: INDUSTRY_ACTIONS_PACKAGE,
            industryActionsRegistryId: INDUSTRY_ACTIONS_REGISTRY,
            logisticsPackageId: LOGISTICS_PACKAGE,
            logisticsTypeOrigin: LOGISTICS_PACKAGE,
            logisticsRegistryId: LOGISTICS_REGISTRY,
            infrastructurePackageId: INFRASTRUCTURE_PACKAGE,
            infrastructureTypeOrigin: INFRASTRUCTURE_PACKAGE,
            infrastructureRegistryId: INFRASTRUCTURE_REGISTRY,
            automationPackageId: AUTOMATION_PACKAGE,
            automationTypeOrigin: AUTOMATION_PACKAGE,
            automationRegistryId: AUTOMATION_REGISTRY,
        },
    );
});

test("fresh NPC manifest rejects mismatched packages and unsafe identities", () => {
    assert.throws(
        () =>
            buildFreshNpcDeployment(
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
        () => buildFreshNpcDeployment(
            "not-a-chain", IDS, PACKAGE, NPC_PACKAGE, ACCESS_PACKAGE,
            CATAPULT_PACKAGE, INDUSTRY_PACKAGE, TRANSPONDER_PACKAGE,
            ACTION_PACKAGE, INDUSTRY_ACTIONS_PACKAGE,
            LOGISTICS_PACKAGE, INFRASTRUCTURE_PACKAGE, AUTOMATION_PACKAGE,
        ),
        /chain ID/,
    );
    assert.throws(
        () => buildFreshNpcDeployment("a1b2c3d4", {
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
