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
        catapult: { packageId: `0x${"d".repeat(64)}`, registryId: `0x${"e".repeat(64)}` },
        smartIndustry: { packageId: `0x${"d".repeat(64)}`, registryId: `0x${"e".repeat(64)}` },
        transponder: { packageId: `0x${"d".repeat(64)}`, registryId: `0x${"e".repeat(64)}` },
        assemblyAccess: { packageId: ACCESS_PACKAGE, registryId: ACCESS_REGISTRY },
    },
};

test("fresh NPC deployment records independent packages, type origins and registries", () => {
    assert.deepEqual(
        buildFreshNpcDeployment("A1B2C3D4", IDS, PACKAGE, NPC_PACKAGE, ACCESS_PACKAGE),
        {
        schemaVersion: 1,
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
            ),
        /different packages/,
    );
    assert.throws(
        () => buildFreshNpcDeployment("not-a-chain", IDS, PACKAGE, NPC_PACKAGE, ACCESS_PACKAGE),
        /chain ID/,
    );
    assert.throws(
        () => buildFreshNpcDeployment("a1b2c3d4", {
            ...IDS,
            world: { ...IDS.world, adminAcl: "0x0" },
        }, PACKAGE, NPC_PACKAGE, ACCESS_PACKAGE),
        /AdminACL/,
    );
});

test("deployment sync validates modules in their independent packages", () => {
    assert.doesNotThrow(() => assertPublishedModule(["npc"], "npc", "NPC"));
    assert.doesNotThrow(() =>
        assertPublishedModule(["assembly_access"], "assembly_access", "Assembly access"),
    );
    assert.throws(() => assertPublishedModule(["character"], "npc", "NPC"), /npc/);
    assert.throws(
        () => assertPublishedModule(["npc"], "assembly_access", "Assembly access"),
        /assembly_access/,
    );
});
