/** Write the versioned public world-feature manifest after a fresh publish. */
import * as fs from "node:fs";
import * as path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

import type { ExtractedObjectIds } from "./config";
import {
    getPublishedPackageId,
    readPublishOutputFile,
    resolvePublishOutputPath,
} from "./helper";
import { getExtractedObjectIdsPath } from "./world-object-ids";

export type WorldFeatureCapability = {
    status: "deployed";
    packageId: string;
    typeOrigin: string;
    registryId: string;
};

export type FreshWorldFeatureManifest = {
    format: "eve-frontier-world-features";
    schemaVersion: 1;
    chainId: string;
    world: {
        packageId: string;
        objectRegistryId: string;
        adminAclId: string;
    };
    capabilities: Record<string, WorldFeatureCapability>;
    factionConfig?: {
        default: { id: "default"; path: "factions/default.v1.json" };
        factions: Record<string, { path: string; fallback: "default" }>;
    };
    migration?: {
        source: "npc-deployment.json";
        sourceSchemaVersion: number;
        incompleteCapabilities: string[];
    };
};

const LEGACY_FEATURE_FIELDS = Object.freeze({
    npc: ["packageId", "typeOrigin", "npcRegistryId"],
    assemblyAccess: ["accessPackageId", "accessTypeOrigin", "accessRegistryId"],
    catapult: ["catapultPackageId", "catapultTypeOrigin", "catapultRegistryId"],
    smartIndustry: ["industryPackageId", "industryTypeOrigin", "industryRegistryId"],
    transponder: ["transponderPackageId", "transponderTypeOrigin", "transponderRegistryId"],
    actionQueue: ["actionPackageId", "actionTypeOrigin", "actionRegistryId"],
    industryActions: ["industryActionsPackageId", "industryActionsTypeOrigin", "industryActionsRegistryId"],
    logisticsActions: ["logisticsPackageId", "logisticsTypeOrigin", "logisticsRegistryId"],
    infrastructureActions: ["infrastructurePackageId", "infrastructureTypeOrigin", "infrastructureRegistryId"],
    automation: ["automationPackageId", "automationTypeOrigin", "automationRegistryId"],
} as const);

export const WORLD_FEATURE_CAPABILITY_NAMES = Object.freeze(
    Object.keys(LEGACY_FEATURE_FIELDS),
);

type FactionPolicyInput = {
    transponderCode?: string | null;
    startingRegion?: {
        regionID?: number | null;
        solarSystemIDs?: readonly number[];
    };
    membership?: {
        includedTypeIDs?: readonly number[];
        excludedTypeIDs?: readonly number[];
        typeListProfiles?: ReadonlyArray<{
            profileID: string;
            source: "npcProfiles";
            match: "factionIdentity";
        }>;
    };
    diplomacy?: {
        allies?: ReadonlyArray<{ factionKey: string; transponderCode?: string | null }>;
        enemies?: ReadonlyArray<{ factionKey: string; transponderCode?: string | null }>;
    };
    leadership?: ReadonlyArray<{ characterID: string; characterType: "npc" | "player" }>;
    commanders?: ReadonlyArray<{ characterID: string; characterType: "npc" | "player" }>;
};

function canonicalFactionKey(value: string): string {
    const normalized = String(value || "").trim().toLowerCase();
    const match = /^(\d{1,10})-[a-z0-9][a-z0-9_-]{0,95}$/.exec(normalized);
    if (!match || Number(match[1]) > 0xffffffff) {
        throw new Error("Faction feature keys must use factionID-factionStringOnlyID");
    }
    return normalized;
}

function normalizeFactionPolicy(
    value: FactionPolicyInput | undefined,
    factionKey: string,
): Record<string, unknown> {
    const source = value || {};
    const transponderCode = source.transponderCode == null
        ? null
        : String(source.transponderCode).trim().toUpperCase();
    if (transponderCode !== null && (
        !/^[A-Z0-9][A-Z0-9_:-]*$/.test(transponderCode) || transponderCode.length > 32
    )) throw new Error(`Faction ${factionKey} has an invalid transponder code`);
    const typeIDs = (values: readonly number[] | undefined, label: string) => {
        const result = [...new Set(values || [])];
        if (result.some(typeID => !Number.isSafeInteger(typeID) || typeID <= 0 || typeID > 0xffffffff)) {
            throw new Error(`${label} must contain positive u32 type IDs`);
        }
        if (result.length !== (values || []).length) throw new Error(`${label} contains duplicates`);
        return result.sort((left, right) => left - right);
    };
    const includedTypeIDs = typeIDs(source.membership?.includedTypeIDs, `Faction ${factionKey} included types`);
    const excludedTypeIDs = typeIDs(source.membership?.excludedTypeIDs, `Faction ${factionKey} excluded types`);
    if (source.startingRegion !== undefined && (
        !source.startingRegion || typeof source.startingRegion !== "object" ||
        Array.isArray(source.startingRegion)
    )) throw new Error(`Faction ${factionKey} has an invalid starting region`);
    const startingRegion = source.startingRegion || {};
    for (const key of Object.keys(startingRegion)) {
        if (key !== "regionID" && key !== "solarSystemIDs") {
            throw new Error(`Faction ${factionKey} has an unsupported starting region field ${key}`);
        }
    }
    const regionID = startingRegion.regionID ?? null;
    if (regionID !== null && (
        !Number.isSafeInteger(regionID) || regionID <= 0 || regionID > 0xffffffff
    )) throw new Error(`Faction ${factionKey} has an invalid starting region ID`);
    const solarSystemIDs = typeIDs(
        startingRegion.solarSystemIDs, `Faction ${factionKey} starting solar systems`,
    );
    if (includedTypeIDs.some(typeID => excludedTypeIDs.includes(typeID))) {
        throw new Error(`Faction ${factionKey} cannot include and exclude the same type ID`);
    }
    const seenProfiles = new Set<string>();
    const typeListProfiles = (source.membership?.typeListProfiles || []).map(profile => {
        const profileID = String(profile?.profileID || "").trim().toLowerCase();
        if (!/^[a-z0-9][a-z0-9:_-]{0,127}$/.test(profileID) || seenProfiles.has(profileID) ||
            profile?.source !== "npcProfiles" || profile?.match !== "factionIdentity") {
            throw new Error(`Faction ${factionKey} has an invalid type-list profile`);
        }
        seenProfiles.add(profileID);
        return { profileID, source: "npcProfiles", match: "factionIdentity" };
    });
    const contacts = (
        values: ReadonlyArray<{ factionKey: string; transponderCode?: string | null }> | undefined,
        label: string,
    ) => {
        const seen = new Set<string>();
        return (values || []).map(contact => {
            const targetKey = canonicalFactionKey(contact?.factionKey);
            const targetCode = contact?.transponderCode == null
                ? null
                : String(contact.transponderCode).trim().toUpperCase();
            if (targetKey === factionKey || seen.has(targetKey) || (targetCode !== null && (
                !/^[A-Z0-9][A-Z0-9_:-]*$/.test(targetCode) || targetCode.length > 32
            ))) throw new Error(`Faction ${factionKey} has an invalid ${label} contact`);
            seen.add(targetKey);
            return { factionKey: targetKey, transponderCode: targetCode };
        }).sort((left, right) => left.factionKey.localeCompare(right.factionKey));
    };
    const allies = contacts(source.diplomacy?.allies, "ally");
    const enemies = contacts(source.diplomacy?.enemies, "enemy");
    if (allies.some(ally => enemies.some(enemy => enemy.factionKey === ally.factionKey))) {
        throw new Error(`Faction ${factionKey} lists a contact as both ally and enemy`);
    }
    const characters = (
        values: ReadonlyArray<{ characterID: string; characterType: "npc" | "player" }> | undefined,
        label: string,
    ) => {
        const seen = new Set<string>();
        return (values || []).map(character => {
            const characterID = String(character?.characterID || "").trim();
            const characterType = String(character?.characterType || "").trim().toLowerCase();
            const identity = `${characterType}:${characterID}`;
            if (!/^[1-9][0-9]*$/.test(characterID) || BigInt(characterID) > ((1n << 64n) - 1n) ||
                (characterType !== "npc" && characterType !== "player") || seen.has(identity)) {
                throw new Error(`Faction ${factionKey} has an invalid ${label} character`);
            }
            seen.add(identity);
            return { characterID, characterType };
        });
    };
    return {
        transponderCode,
        startingRegion: { regionID, solarSystemIDs },
        membership: { includedTypeIDs, excludedTypeIDs, typeListProfiles },
        diplomacy: { allies, enemies },
        leadership: characters(source.leadership, "leadership"),
        commanders: characters(source.commanders, "commander"),
    };
}

function capabilityNames(values: readonly string[], label: string): string[] {
    if (!Array.isArray(values) || values.some(value =>
        typeof value !== "string" || !WORLD_FEATURE_CAPABILITY_NAMES.includes(value)
    )) {
        throw new Error(`${label} contains an unknown capability`);
    }
    return [...new Set(values)].sort();
}

/** Author split faction files without duplicating global package identities. */
export function buildSplitFactionFeatureConfiguration(
    factionKeys: readonly string[],
    defaultCapabilities: readonly string[] = WORLD_FEATURE_CAPABILITY_NAMES,
    overrides: Record<string, readonly string[] | undefined> = {},
    policies: Record<string, FactionPolicyInput | undefined> = {},
) {
    const keys = [...new Set(factionKeys)].sort();
    if (keys.length !== factionKeys.length) throw new Error("Faction feature keys must be unique");
    for (const factionKey of keys) {
        canonicalFactionKey(factionKey);
    }
    for (const factionKey of Object.keys(overrides)) {
        if (!keys.includes(factionKey)) throw new Error(`Faction override has no manifest entry: ${factionKey}`);
    }
    for (const factionKey of Object.keys(policies)) {
        if (!keys.includes(factionKey)) throw new Error(`Faction policy has no manifest entry: ${factionKey}`);
    }
    const defaultPath = "factions/default.v1.json" as const;
    const files: Record<string, Record<string, unknown>> = {
        [defaultPath]: {
            format: "eve-frontier-faction-features",
            schemaVersion: 2,
            configId: "default",
            capabilities: capabilityNames(defaultCapabilities, "Default faction config"),
        },
    };
    const references: Record<string, { path: string; fallback: "default" }> = {};
    for (const factionKey of keys) {
        const factionPath = `factions/${factionKey}.v1.json`;
        references[factionKey] = { path: factionPath, fallback: "default" };
        files[factionPath] = {
            format: "eve-frontier-faction-features",
            schemaVersion: 2,
            factionKey,
            fallback: "default",
            ...(overrides[factionKey] === undefined
                ? {}
                : { capabilities: capabilityNames(overrides[factionKey], `Faction ${factionKey}`) }),
            ...normalizeFactionPolicy(policies[factionKey], factionKey),
        };
    }
    for (const factionKey of keys) {
        const policy = files[`factions/${factionKey}.v1.json`] as any;
        for (const contact of [...policy.diplomacy.allies, ...policy.diplomacy.enemies]) {
            const target = files[`factions/${contact.factionKey}.v1.json`] as any;
            if (!target) throw new Error(`Faction ${factionKey} references unknown ${contact.factionKey}`);
            if (contact.transponderCode !== target.transponderCode) {
                throw new Error(`Faction ${factionKey} has a stale code for ${contact.factionKey}`);
            }
        }
    }
    return {
        factionConfig: {
            default: { id: "default" as const, path: defaultPath },
            factions: references,
        },
        files,
    };
}

export function assertPublishedModule(
    modules: unknown,
    requiredModule: string,
    packageLabel: string,
): asserts modules is string[] {
    if (!Array.isArray(modules)) {
        throw new Error(`${packageLabel} publish output has no published module list`);
    }
    if (!modules.includes(requiredModule)) {
        throw new Error(`${packageLabel} publish is missing required runtime module: ${requiredModule}`);
    }
}

function canonicalAddress(value: unknown, label: string): string {
    const address = String(value || "").trim().toLowerCase();
    if (!/^0x[0-9a-f]{64}$/.test(address) || /^0x0{64}$/.test(address)) {
        throw new Error(`${label} must be a canonical nonzero Sui address`);
    }
    return address;
}

/** Convert the historical flat manifest without requiring every feature. */
export function migrateLegacyNpcDeployment(
    legacy: Record<string, any>,
): FreshWorldFeatureManifest {
    const schemaVersion = legacy?.schemaVersion;
    if (!Number.isInteger(schemaVersion) || ![1, 2, 3].includes(schemaVersion)) {
        throw new Error("Legacy NPC deployment has an unsupported schema");
    }
    const capabilities: Record<string, WorldFeatureCapability> = {};
    const incompleteCapabilities: string[] = [];
    const source = { ...legacy };
    if (schemaVersion < 2) {
        source.actionPackageId ??= source.accessPackageId;
        source.actionTypeOrigin ??= source.accessTypeOrigin;
        source.actionRegistryId ??= source.accessRegistryId;
        source.industryActionsPackageId ??= source.industryPackageId;
        source.industryActionsTypeOrigin ??= source.industryTypeOrigin;
        source.industryActionsRegistryId ??= source.industryRegistryId;
    }
    if (schemaVersion < 3) {
        for (const prefix of ["logistics", "infrastructure", "automation"]) {
            source[`${prefix}PackageId`] ??= source.actionPackageId;
            source[`${prefix}TypeOrigin`] ??= source.actionTypeOrigin;
            source[`${prefix}RegistryId`] ??= source.actionRegistryId;
        }
    }
    for (const [name, fields] of Object.entries(LEGACY_FEATURE_FIELDS)) {
        const values = fields.map(field => source[field]);
        if (values.every(value => value === undefined || value === null || value === "")) {
            continue;
        }
        if (values.some(value => value === undefined || value === null || value === "")) {
            incompleteCapabilities.push(name);
            continue;
        }
        capabilities[name] = {
            status: "deployed",
            packageId: canonicalAddress(values[0], `${name} package`),
            typeOrigin: canonicalAddress(values[1], `${name} type origin`),
            registryId: canonicalAddress(values[2], `${name} registry`),
        };
    }
    const chainId = String(legacy.chainId || "").trim().toLowerCase();
    if (!/^[0-9a-f]+$/.test(chainId)) throw new Error("Legacy chain ID is invalid");
    return {
        format: "eve-frontier-world-features",
        schemaVersion: 1,
        chainId,
        world: {
            packageId: canonicalAddress(legacy.worldPackageId, "World package ID"),
            objectRegistryId: canonicalAddress(legacy.objectRegistryId, "ObjectRegistry ID"),
            adminAclId: canonicalAddress(legacy.adminAclId, "AdminACL ID"),
        },
        capabilities,
        migration: {
            source: "npc-deployment.json",
            sourceSchemaVersion: schemaVersion,
            incompleteCapabilities: incompleteCapabilities.sort(),
        },
    };
}

export function buildFreshWorldFeatureManifest(
    chainId: string,
    ids: ExtractedObjectIds,
    publishedWorldPackageId: string,
    publishedNpcPackageId: string,
    publishedAccessPackageId: string,
    publishedCatapultPackageId: string,
    publishedIndustryPackageId: string,
    publishedTransponderPackageId: string,
    publishedActionPackageId: string,
    publishedIndustryActionsPackageId: string,
    publishedLogisticsPackageId: string,
    publishedInfrastructurePackageId: string,
    publishedAutomationPackageId: string,
): FreshWorldFeatureManifest {
    const normalizedChain = String(chainId || "").trim().toLowerCase();
    if (!/^[0-9a-f]+$/.test(normalizedChain)) {
        throw new Error("Published chain ID is invalid");
    }
    const worldPackageId = canonicalAddress(publishedWorldPackageId, "Published world package ID");
    const packageId = canonicalAddress(publishedNpcPackageId, "Published NPC package ID");
    const accessPackageId = canonicalAddress(
        publishedAccessPackageId,
        "Published assembly-access package ID",
    );
    const catapultPackageId = canonicalAddress(
        publishedCatapultPackageId,
        "Published catapult package ID",
    );
    const industryPackageId = canonicalAddress(
        publishedIndustryPackageId,
        "Published Smart Industry package ID",
    );
    const transponderPackageId = canonicalAddress(
        publishedTransponderPackageId,
        "Published transponder package ID",
    );
    const actionPackageId = canonicalAddress(
        publishedActionPackageId,
        "Published action-queue package ID",
    );
    const industryActionsPackageId = canonicalAddress(
        publishedIndustryActionsPackageId,
        "Published Industry Actions package ID",
    );
    const logisticsPackageId = canonicalAddress(
        publishedLogisticsPackageId,
        "Published Logistics Actions package ID",
    );
    const infrastructurePackageId = canonicalAddress(
        publishedInfrastructurePackageId,
        "Published Infrastructure Actions package ID",
    );
    const automationPackageId = canonicalAddress(
        publishedAutomationPackageId,
        "Published Automation package ID",
    );
    if (canonicalAddress(ids.world.packageId, "Extracted world package ID") !== worldPackageId) {
        throw new Error("Publish output and extracted world IDs refer to different packages");
    }
    if (!ids.features) throw new Error("Extracted feature package IDs are missing");
    if (canonicalAddress(ids.features.npc.packageId, "Extracted NPC package ID") !== packageId) {
        throw new Error("Publish output and extracted NPC IDs refer to different packages");
    }
    if (
        canonicalAddress(ids.features.assemblyAccess.packageId, "Extracted assembly-access package ID") !==
        accessPackageId
    ) {
        throw new Error("Publish output and extracted assembly-access IDs refer to different packages");
    }
    if (
        canonicalAddress(ids.features.catapult.packageId, "Extracted catapult package ID") !==
        catapultPackageId
    ) {
        throw new Error("Publish output and extracted catapult IDs refer to different packages");
    }
    if (
        canonicalAddress(ids.features.smartIndustry.packageId, "Extracted Smart Industry package ID") !==
        industryPackageId
    ) {
        throw new Error("Publish output and extracted Smart Industry IDs refer to different packages");
    }
    if (
        canonicalAddress(ids.features.transponder.packageId, "Extracted transponder package ID") !==
        transponderPackageId
    ) {
        throw new Error("Publish output and extracted transponder IDs refer to different packages");
    }
    if (
        canonicalAddress(ids.features.actionQueue.packageId, "Extracted action-queue package ID") !==
        actionPackageId
    ) {
        throw new Error("Publish output and extracted action-queue IDs refer to different packages");
    }
    if (
        canonicalAddress(
            ids.features.industryActions.packageId,
            "Extracted Industry Actions package ID",
        ) !== industryActionsPackageId
    ) {
        throw new Error("Publish output and extracted Industry Actions IDs refer to different packages");
    }
    if (
        canonicalAddress(ids.features.logisticsActions.packageId, "Extracted Logistics Actions package ID") !==
        logisticsPackageId
    ) {
        throw new Error("Publish output and extracted Logistics Actions IDs refer to different packages");
    }
    if (
        canonicalAddress(
            ids.features.infrastructureActions.packageId,
            "Extracted Infrastructure Actions package ID",
        ) !== infrastructurePackageId
    ) {
        throw new Error("Publish output and extracted Infrastructure Actions IDs refer to different packages");
    }
    if (
        canonicalAddress(ids.features.automation.packageId, "Extracted Automation package ID") !==
        automationPackageId
    ) {
        throw new Error("Publish output and extracted Automation IDs refer to different packages");
    }
    const capability = (
        packageIdValue: string,
        registryIdValue: unknown,
        registryLabel: string,
    ): WorldFeatureCapability => ({
        status: "deployed",
        packageId: packageIdValue,
        typeOrigin: packageIdValue,
        registryId: canonicalAddress(registryIdValue, registryLabel),
    });
    return {
        format: "eve-frontier-world-features",
        schemaVersion: 1,
        chainId: normalizedChain,
        world: {
            packageId: worldPackageId,
            objectRegistryId: canonicalAddress(ids.world.objectRegistry, "ObjectRegistry ID"),
            adminAclId: canonicalAddress(ids.world.adminAcl, "AdminACL ID"),
        },
        capabilities: {
            npc: capability(packageId, ids.features.npc.registryId, "NpcRegistry ID"),
            assemblyAccess: capability(accessPackageId, ids.features.assemblyAccess.registryId, "AssemblyAccessRegistry ID"),
            catapult: capability(catapultPackageId, ids.features.catapult.registryId, "CatapultRegistry ID"),
            smartIndustry: capability(industryPackageId, ids.features.smartIndustry.registryId, "SmartIndustryRegistry ID"),
            transponder: capability(transponderPackageId, ids.features.transponder.registryId, "TransponderRegistry ID"),
            actionQueue: capability(actionPackageId, ids.features.actionQueue.registryId, "ActionQueueRegistry ID"),
            industryActions: capability(industryActionsPackageId, ids.features.industryActions.registryId, "IndustryActionRegistry ID"),
            logisticsActions: capability(logisticsPackageId, ids.features.logisticsActions.registryId, "LogisticsRegistry ID"),
            infrastructureActions: capability(infrastructurePackageId, ids.features.infrastructureActions.registryId, "InfrastructureActionRegistry ID"),
            automation: capability(automationPackageId, ids.features.automation.registryId, "AutomationRegistry ID"),
        },
    };
}

/** Historical export retained for scripts importing the old helper name. */
export const buildFreshNpcDeployment = buildFreshWorldFeatureManifest;

export function writeWorldFeatureManifest() {
    const network = process.env.SUI_NETWORK || "localnet";
    const publishPath = resolvePublishOutputPath(
        process.env.WORLD_PUBLISH_OUTPUT || `./deployments/${network}/world_package.json`,
    );
    const npcPublishPath = resolvePublishOutputPath(
        process.env.NPC_PUBLISH_OUTPUT || `./deployments/${network}/world_npc_package.json`,
    );
    const accessPublishPath = resolvePublishOutputPath(
        process.env.ASSEMBLY_ACCESS_PUBLISH_OUTPUT ||
            `./deployments/${network}/world_assembly_access_package.json`,
    );
    const catapultPublishPath = resolvePublishOutputPath(
        process.env.CATAPULT_PUBLISH_OUTPUT ||
            `./deployments/${network}/world_catapult_package.json`,
    );
    const industryPublishPath = resolvePublishOutputPath(
        process.env.SMART_INDUSTRY_PUBLISH_OUTPUT ||
            `./deployments/${network}/world_smart_industry_package.json`,
    );
    const transponderPublishPath = resolvePublishOutputPath(
        process.env.TRANSPONDER_PUBLISH_OUTPUT ||
            `./deployments/${network}/world_transponder_package.json`,
    );
    const actionPublishPath = resolvePublishOutputPath(
        process.env.ACTION_QUEUE_PUBLISH_OUTPUT ||
            `./deployments/${network}/world_action_queue_package.json`,
    );
    const industryActionsPublishPath = resolvePublishOutputPath(
        process.env.INDUSTRY_ACTIONS_PUBLISH_OUTPUT ||
            `./deployments/${network}/world_industry_actions_package.json`,
    );
    const logisticsPublishPath = resolvePublishOutputPath(
        process.env.LOGISTICS_ACTIONS_PUBLISH_OUTPUT ||
            `./deployments/${network}/world_logistics_actions_package.json`,
    );
    const infrastructurePublishPath = resolvePublishOutputPath(
        process.env.INFRASTRUCTURE_ACTIONS_PUBLISH_OUTPUT ||
            `./deployments/${network}/world_infrastructure_actions_package.json`,
    );
    const automationPublishPath = resolvePublishOutputPath(
        process.env.AUTOMATION_PUBLISH_OUTPUT ||
            `./deployments/${network}/world_automation_package.json`,
    );
    const publicationPath = path.resolve(
        process.env.WORLD_PUBLICATION_FILE || `./contracts/world/Pub.${network}.toml`,
    );
    const idsPath = getExtractedObjectIdsPath(network);
    const outputPath = path.resolve(`./deployments/${network}/world-features.v1.json`);
    const publish = readPublishOutputFile(publishPath);
    const npcPublish = readPublishOutputFile(npcPublishPath);
    const accessPublish = readPublishOutputFile(accessPublishPath);
    const catapultPublish = readPublishOutputFile(catapultPublishPath);
    const industryPublish = readPublishOutputFile(industryPublishPath);
    const transponderPublish = readPublishOutputFile(transponderPublishPath);
    const actionPublish = readPublishOutputFile(actionPublishPath);
    const industryActionsPublish = readPublishOutputFile(industryActionsPublishPath);
    const logisticsPublish = readPublishOutputFile(logisticsPublishPath);
    const infrastructurePublish = readPublishOutputFile(infrastructurePublishPath);
    const automationPublish = readPublishOutputFile(automationPublishPath);
    const npcPublished = npcPublish.objectChanges.find(change => change.type === "published");
    const accessPublished = accessPublish.objectChanges.find(change => change.type === "published");
    const catapultPublished = catapultPublish.objectChanges.find(change => change.type === "published");
    const industryPublished = industryPublish.objectChanges.find(change => change.type === "published");
    const transponderPublished = transponderPublish.objectChanges.find(change => change.type === "published");
    const actionPublished = actionPublish.objectChanges.find(change => change.type === "published");
    const industryActionsPublished = industryActionsPublish.objectChanges.find(
        change => change.type === "published",
    );
    const logisticsPublished = logisticsPublish.objectChanges.find(change => change.type === "published");
    const infrastructurePublished = infrastructurePublish.objectChanges.find(
        change => change.type === "published",
    );
    const automationPublished = automationPublish.objectChanges.find(change => change.type === "published");
    assertPublishedModule((npcPublished as any)?.modules, "npc", "NPC");
    assertPublishedModule((accessPublished as any)?.modules, "assembly_access", "Assembly access");
    assertPublishedModule((catapultPublished as any)?.modules, "catapult", "Catapult");
    assertPublishedModule((industryPublished as any)?.modules, "smart_industry", "Smart Industry");
    assertPublishedModule((transponderPublished as any)?.modules, "transponder", "Transponder");
    assertPublishedModule((actionPublished as any)?.modules, "action_queue", "Action queue");
    assertPublishedModule(
        (industryActionsPublished as any)?.modules,
        "industry_actions",
        "Industry Actions",
    );
    assertPublishedModule(
        (logisticsPublished as any)?.modules,
        "logistics_actions",
        "Logistics Actions",
    );
    assertPublishedModule(
        (infrastructurePublished as any)?.modules,
        "infrastructure_actions",
        "Infrastructure Actions",
    );
    assertPublishedModule((automationPublished as any)?.modules, "automation", "Automation");
    const publication = fs.readFileSync(publicationPath, "utf8");
    const chain = new RegExp('^chain-id\\s*=\\s*"([0-9a-fA-F]+)"\\s*$', "m")
        .exec(publication)?.[1];
    if (!chain) throw new Error(`World publication has no chain-id: ${publicationPath}`);
    const ids = JSON.parse(fs.readFileSync(idsPath, "utf8")) as ExtractedObjectIds;
    const manifest = buildFreshWorldFeatureManifest(
        chain,
        ids,
        getPublishedPackageId(publish.objectChanges),
        getPublishedPackageId(npcPublish.objectChanges),
        getPublishedPackageId(accessPublish.objectChanges),
        getPublishedPackageId(catapultPublish.objectChanges),
        getPublishedPackageId(industryPublish.objectChanges),
        getPublishedPackageId(transponderPublish.objectChanges),
        getPublishedPackageId(actionPublish.objectChanges),
        getPublishedPackageId(industryActionsPublish.objectChanges),
        getPublishedPackageId(logisticsPublish.objectChanges),
        getPublishedPackageId(infrastructurePublish.objectChanges),
        getPublishedPackageId(automationPublish.objectChanges),
    );
    const repositoryFactionSourcePath = path.resolve(
        path.dirname(fileURLToPath(import.meta.url)),
        "../../../npc-factions.config.json",
    );
    const configuredFactionSourcePath = String(
        process.env.WORLD_FACTION_FEATURES_SOURCE || "",
    ).trim();
    const factionSourcePath = configuredFactionSourcePath ||
        (fs.existsSync(repositoryFactionSourcePath) ? repositoryFactionSourcePath : "");
    let factionFiles: Record<string, Record<string, unknown>> = {};
    if (factionSourcePath) {
        const source = JSON.parse(fs.readFileSync(path.resolve(factionSourcePath), "utf8"));
        const defaultCapabilities = source?.defaultCapabilities ??
            source?.worldCapabilities ?? ["npc", "transponder"];
        if (!source || ![1, 2].includes(source.schemaVersion) || !Array.isArray(source.factions) ||
            !Array.isArray(defaultCapabilities)) {
            throw new Error("Faction feature source has an unsupported schema");
        }
        const factionKeys: string[] = [];
        const overrides: Record<string, readonly string[] | undefined> = {};
        const policies: Record<string, FactionPolicyInput | undefined> = {};
        const identities = new Map<string, string>();
        const entries = new Map<string, any>();
        for (const entry of source.factions) {
            if (!entry ||
                (entry.capabilities !== undefined && !Array.isArray(entry.capabilities))) {
                throw new Error("Faction feature source contains an invalid faction record");
            }
            const rawStringID = String(entry.factionKey || "").trim().toLowerCase();
            const numericID = Number(entry.factionID || 0);
            const factionKey = /^(\d{1,10})-[a-z0-9][a-z0-9_-]{0,95}$/.test(rawStringID)
                ? canonicalFactionKey(rawStringID)
                : canonicalFactionKey(`${numericID}-${rawStringID || "none"}`);
            factionKeys.push(factionKey);
            entries.set(factionKey, entry);
            if (numericID > 0) identities.set(`id:${numericID}`, factionKey);
            if (rawStringID && rawStringID !== factionKey) identities.set(`key:${rawStringID}`, factionKey);
            overrides[factionKey] = entry.capabilities;
            const signal = String(entry.transponderSignal || "").trim().toUpperCase();
            const suffix = String(entry.transponderSuffix || "").trim().toUpperCase();
            policies[factionKey] = {
                transponderCode: entry.transponderCode ??
                    (signal ? `${signal}${suffix ? `:${suffix}` : ""}` : null),
                startingRegion: entry.startingRegion ?? source.defaults?.startingRegion,
                membership: entry.membership ?? entry.typeMembership ?? source.defaults?.typeMembership,
                diplomacy: entry.diplomacy,
                leadership: entry.leadership ?? source.defaults?.leadership,
                commanders: entry.commanders ?? source.defaults?.commanders,
            };
        }
        const dispositions = new Map<string, "friendly" | "hostile">();
        for (const relation of Array.isArray(source.relations) ? source.relations : []) {
            if (!relation || !["friendly", "hostile", "neutral"].includes(relation.disposition)) {
                throw new Error("Faction feature source contains an invalid relation");
            }
            const sourceKeys = [
                ...(relation.sourceFactionIDs || []).map((id: unknown) => identities.get(`id:${Number(id)}`)),
                ...(relation.sourceFactionKeys || []).map((key: unknown) =>
                    identities.get(`key:${String(key).trim().toLowerCase()}`)),
            ];
            const targetKeys = [
                ...(relation.targetFactionIDs || []).map((id: unknown) => identities.get(`id:${Number(id)}`)),
                ...(relation.targetFactionKeys || []).map((key: unknown) =>
                    identities.get(`key:${String(key).trim().toLowerCase()}`)),
            ];
            if (sourceKeys.some((key: unknown) => !key) || targetKeys.some((key: unknown) => !key)) {
                throw new Error("Faction feature source relation references an unknown faction");
            }
            for (const sourceKey of sourceKeys as string[]) {
                for (const targetKey of targetKeys as string[]) {
                    if (sourceKey === targetKey || relation.disposition === "neutral") continue;
                    dispositions.set(`${sourceKey}\u0000${targetKey}`, relation.disposition);
                    if (relation.reciprocal === true) {
                        dispositions.set(`${targetKey}\u0000${sourceKey}`, relation.disposition);
                    }
                }
            }
        }
        for (const factionKey of factionKeys) {
            const direct = policies[factionKey]?.diplomacy;
            if (direct) continue;
            const allies: Array<{ factionKey: string; transponderCode: string | null }> = [];
            const enemies: Array<{ factionKey: string; transponderCode: string | null }> = [];
            for (const targetKey of factionKeys) {
                const disposition = dispositions.get(`${factionKey}\u0000${targetKey}`);
                if (!disposition) continue;
                const targetEntry = entries.get(targetKey);
                const targetSignal = String(targetEntry.transponderSignal || "").trim().toUpperCase();
                const targetSuffix = String(targetEntry.transponderSuffix || "").trim().toUpperCase();
                const contact = {
                    factionKey: targetKey,
                    transponderCode: targetEntry.transponderCode ??
                        (targetSignal ? `${targetSignal}${targetSuffix ? `:${targetSuffix}` : ""}` : null),
                };
                (disposition === "friendly" ? allies : enemies).push(contact);
            }
            policies[factionKey] = { ...policies[factionKey], diplomacy: { allies, enemies } };
        }
        const split = buildSplitFactionFeatureConfiguration(
            factionKeys,
            defaultCapabilities,
            overrides,
            policies,
        );
        manifest.factionConfig = split.factionConfig;
        factionFiles = split.files;
    }
    fs.mkdirSync(path.dirname(outputPath), { recursive: true });
    for (const [relativePath, value] of Object.entries(factionFiles)) {
        const factionPath = path.resolve(path.dirname(outputPath), relativePath);
        fs.mkdirSync(path.dirname(factionPath), { recursive: true });
        const factionTemporaryPath = `${factionPath}.tmp-${process.pid}`;
        fs.writeFileSync(factionTemporaryPath, `${JSON.stringify(value, null, 2)}\n`, "utf8");
        fs.renameSync(factionTemporaryPath, factionPath);
    }
    const temporaryPath = `${outputPath}.tmp-${process.pid}`;
    fs.writeFileSync(temporaryPath, `${JSON.stringify(manifest, null, 2)}\n`, "utf8");
    fs.renameSync(temporaryPath, outputPath);
    console.log(`Wrote ${outputPath}`);
}

if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
    writeWorldFeatureManifest();
}
