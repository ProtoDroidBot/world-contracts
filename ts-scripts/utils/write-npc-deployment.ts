/** Write public NPC deployment identity after a fresh world publish. */
import * as fs from "node:fs";
import * as path from "node:path";
import { pathToFileURL } from "node:url";

import type { ExtractedObjectIds } from "./config";
import {
    getPublishedPackageId,
    readPublishOutputFile,
    resolvePublishOutputPath,
} from "./helper";
import { getExtractedObjectIdsPath } from "./world-object-ids";

type FreshNpcDeployment = {
    schemaVersion: 1;
    chainId: string;
    worldPackageId: string;
    objectRegistryId: string;
    adminAclId: string;
    packageId: string;
    typeOrigin: string;
    npcRegistryId: string;
    accessPackageId: string;
    accessTypeOrigin: string;
    accessRegistryId: string;
    catapultPackageId: string;
    catapultTypeOrigin: string;
    catapultRegistryId: string;
    industryPackageId: string;
    industryTypeOrigin: string;
    industryRegistryId: string;
    transponderPackageId: string;
    transponderTypeOrigin: string;
    transponderRegistryId: string;
};

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

export function buildFreshNpcDeployment(
    chainId: string,
    ids: ExtractedObjectIds,
    publishedWorldPackageId: string,
    publishedNpcPackageId: string,
    publishedAccessPackageId: string,
    publishedCatapultPackageId: string,
    publishedIndustryPackageId: string,
    publishedTransponderPackageId: string,
): FreshNpcDeployment {
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
    return {
        schemaVersion: 1,
        chainId: normalizedChain,
        worldPackageId,
        objectRegistryId: canonicalAddress(ids.world.objectRegistry, "ObjectRegistry ID"),
        adminAclId: canonicalAddress(ids.world.adminAcl, "AdminACL ID"),
        packageId,
        typeOrigin: packageId,
        npcRegistryId: canonicalAddress(ids.features.npc.registryId, "NpcRegistry ID"),
        accessPackageId,
        accessTypeOrigin: accessPackageId,
        accessRegistryId: canonicalAddress(
            ids.features.assemblyAccess.registryId,
            "AssemblyAccessRegistry ID",
        ),
        catapultPackageId,
        catapultTypeOrigin: catapultPackageId,
        catapultRegistryId: canonicalAddress(
            ids.features.catapult.registryId,
            "CatapultRegistry ID",
        ),
        industryPackageId,
        industryTypeOrigin: industryPackageId,
        industryRegistryId: canonicalAddress(
            ids.features.smartIndustry.registryId,
            "SmartIndustryRegistry ID",
        ),
        transponderPackageId,
        transponderTypeOrigin: transponderPackageId,
        transponderRegistryId: canonicalAddress(
            ids.features.transponder.registryId,
            "TransponderRegistry ID",
        ),
    };
}

function main() {
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
    const publicationPath = path.resolve(
        process.env.WORLD_PUBLICATION_FILE || `./contracts/world/Pub.${network}.toml`,
    );
    const idsPath = getExtractedObjectIdsPath(network);
    const outputPath = path.resolve(`./deployments/${network}/npc-deployment.json`);
    const publish = readPublishOutputFile(publishPath);
    const npcPublish = readPublishOutputFile(npcPublishPath);
    const accessPublish = readPublishOutputFile(accessPublishPath);
    const catapultPublish = readPublishOutputFile(catapultPublishPath);
    const industryPublish = readPublishOutputFile(industryPublishPath);
    const transponderPublish = readPublishOutputFile(transponderPublishPath);
    const npcPublished = npcPublish.objectChanges.find(change => change.type === "published");
    const accessPublished = accessPublish.objectChanges.find(change => change.type === "published");
    const catapultPublished = catapultPublish.objectChanges.find(change => change.type === "published");
    const industryPublished = industryPublish.objectChanges.find(change => change.type === "published");
    const transponderPublished = transponderPublish.objectChanges.find(change => change.type === "published");
    assertPublishedModule((npcPublished as any)?.modules, "npc", "NPC");
    assertPublishedModule((accessPublished as any)?.modules, "assembly_access", "Assembly access");
    assertPublishedModule((catapultPublished as any)?.modules, "catapult", "Catapult");
    assertPublishedModule((industryPublished as any)?.modules, "smart_industry", "Smart Industry");
    assertPublishedModule((transponderPublished as any)?.modules, "transponder", "Transponder");
    const publication = fs.readFileSync(publicationPath, "utf8");
    const chain = new RegExp('^chain-id\\s*=\\s*"([0-9a-fA-F]+)"\\s*$', "m")
        .exec(publication)?.[1];
    if (!chain) throw new Error(`World publication has no chain-id: ${publicationPath}`);
    const ids = JSON.parse(fs.readFileSync(idsPath, "utf8")) as ExtractedObjectIds;
    const manifest = buildFreshNpcDeployment(
        chain,
        ids,
        getPublishedPackageId(publish.objectChanges),
        getPublishedPackageId(npcPublish.objectChanges),
        getPublishedPackageId(accessPublish.objectChanges),
        getPublishedPackageId(catapultPublish.objectChanges),
        getPublishedPackageId(industryPublish.objectChanges),
        getPublishedPackageId(transponderPublish.objectChanges),
    );
    fs.mkdirSync(path.dirname(outputPath), { recursive: true });
    const temporaryPath = `${outputPath}.tmp-${process.pid}`;
    fs.writeFileSync(temporaryPath, `${JSON.stringify(manifest, null, 2)}\n`, "utf8");
    fs.renameSync(temporaryPath, outputPath);
    console.log(`Wrote ${outputPath}`);
}

if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
    main();
}
