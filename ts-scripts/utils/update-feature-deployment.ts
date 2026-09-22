/** Upgrade one split feature package without changing its type origin or registry. */
import fs from "node:fs";
import path from "node:path";
import { pathToFileURL } from "node:url";
import { migrateLegacyNpcDeployment } from "./write-world-features";

const FEATURES = Object.freeze({
    smart_industry: {
        publishFile: "world_smart_industry_package.json",
        module: "smart_industry",
        manifestPackage: "industryPackageId",
        manifestOrigin: "industryTypeOrigin",
        manifestRegistry: "industryRegistryId",
        extractedFeature: "smartIndustry",
        capability: "smartIndustry",
    },
    npc: {
        publishFile: "world_npc_package.json", module: "npc",
        manifestPackage: "packageId", manifestOrigin: "typeOrigin",
        manifestRegistry: "npcRegistryId", extractedFeature: "npc",
        capability: "npc",
    },
    assembly_access: {
        publishFile: "world_assembly_access_package.json", module: "assembly_access",
        manifestPackage: "accessPackageId", manifestOrigin: "accessTypeOrigin",
        manifestRegistry: "accessRegistryId", extractedFeature: "assemblyAccess",
        capability: "assemblyAccess",
    },
});

type FeatureName = keyof typeof FEATURES;

function address(value: unknown, label: string) {
    const normalized = String(value || "").trim().toLowerCase();
    if (!/^0x[0-9a-f]{64}$/.test(normalized) || /^0x0{64}$/.test(normalized)) {
        throw new Error(`${label} must be a canonical nonzero Sui address`);
    }
    return normalized;
}

function readJson(file: string) {
    return JSON.parse(fs.readFileSync(file, "utf8"));
}

function publishedChange(output: any, moduleName: string) {
    const change = output?.objectChanges?.find((entry: any) => entry?.type === "published");
    if (!change || !Array.isArray(change.modules) || !change.modules.includes(moduleName)) {
        throw new Error(`Upgrade output does not publish ${moduleName}`);
    }
    return change;
}

export function findUpgradeCapId(output: any) {
    const change = output?.objectChanges?.find((entry: any) =>
        entry?.objectType === "0x2::package::UpgradeCap" && entry?.objectId);
    return address(change?.objectId, "UpgradeCap object ID");
}

export function buildUpgradedFeatureDeployment(
    current: Record<string, any>,
    featureName: FeatureName,
    nextPackageId: string,
): Record<string, any> {
    const feature = FEATURES[featureName];
    if (!feature) throw new Error(`Unsupported split feature ${featureName}`);
    if (current?.format === "eve-frontier-world-features" && current?.schemaVersion === 1) {
        const binding = current.capabilities?.[feature.capability];
        if (!binding || binding.status !== "deployed") {
            throw new Error(`World feature ${feature.capability} is not deployed`);
        }
        const previousPackageId = address(binding.packageId, "Current feature package");
        const typeOrigin = address(binding.typeOrigin, "Feature type origin");
        const registryId = address(binding.registryId, "Feature registry");
        const next = address(nextPackageId, "Upgraded feature package");
        if (next === previousPackageId) throw new Error("Upgrade did not create a new package version");
        return {
            ...current,
            capabilities: {
                ...current.capabilities,
                [feature.capability]: {
                    status: "deployed",
                    packageId: next,
                    typeOrigin,
                    registryId,
                },
            },
        };
    }
    if (!Number.isInteger(current?.schemaVersion) || current.schemaVersion < 3) {
        throw new Error("A world-features-v1 or schema-v3 legacy deployment is required for upgrades");
    }
    const previousPackageId = address(current[feature.manifestPackage], "Current feature package");
    const typeOrigin = address(current[feature.manifestOrigin], "Feature type origin");
    const registryId = address(current[feature.manifestRegistry], "Feature registry");
    const next = address(nextPackageId, "Upgraded feature package");
    if (next === previousPackageId) throw new Error("Upgrade did not create a new package version");
    return {
        ...current,
        [feature.manifestPackage]: next,
        [feature.manifestOrigin]: typeOrigin,
        [feature.manifestRegistry]: registryId,
    };
}

function atomicWriteJson(file: string, value: unknown) {
    const temporary = `${file}.tmp-${process.pid}`;
    fs.writeFileSync(temporary, `${JSON.stringify(value, null, 2)}\n`, "utf8");
    fs.renameSync(temporary, file);
}

function validateFeatureDeployment(
    root: string,
    network: string,
    featureName: FeatureName,
    stagedPackageId: string | null = null,
) {
    const feature = FEATURES[featureName];
    if (!feature) throw new Error(`Unsupported split feature ${featureName}`);
    const deploymentDir = path.resolve(root, "deployments", network);
    const versionedManifestPath = path.join(deploymentDir, "world-features.v1.json");
    const legacyManifestPath = path.join(deploymentDir, "npc-deployment.json");
    const manifestPath = fs.existsSync(versionedManifestPath)
        ? versionedManifestPath
        : legacyManifestPath;
    const extractedPath = path.join(deploymentDir, "extracted-object-ids.json");
    const originalPublishPath = path.join(deploymentDir, feature.publishFile);
    const rawManifest = readJson(manifestPath);
    const manifest = manifestPath === legacyManifestPath
        ? migrateLegacyNpcDeployment(rawManifest)
        : rawManifest;
    const extracted = readJson(extractedPath);
    const originalPublish = readJson(originalPublishPath);
    if (manifest?.format !== "eve-frontier-world-features" || manifest?.schemaVersion !== 1) {
        throw new Error("A world-features-v1 deployment is required for upgrades");
    }
    const binding = manifest.capabilities?.[feature.capability];
    if (!binding || binding.status !== "deployed") {
        throw new Error(`World feature ${feature.capability} is not deployed`);
    }
    const currentPackage = address(binding.packageId, "Manifest package");
    const typeOrigin = address(binding.typeOrigin, "Manifest type origin");
    const registryId = address(binding.registryId, "Manifest registry");
    const extractedFeature = extracted?.features?.[feature.extractedFeature];
    if (!extractedFeature) throw new Error("Extracted split feature metadata is missing");
    const extractedPackage = address(extractedFeature.packageId, "Extracted package");
    if (![currentPackage, stagedPackageId].filter(Boolean).includes(extractedPackage) ||
        address(extractedFeature.registryId, "Extracted registry") !== registryId) {
        throw new Error("Package split metadata disagrees; refusing to update the deployment");
    }
    const originalPackage = address(
        publishedChange(originalPublish, feature.module).packageId,
        "Original publish package",
    );
    if (originalPackage !== typeOrigin) {
        throw new Error("Original publish does not match the feature type origin");
    }
    return {
        feature,
        deploymentDir,
        versionedManifestPath,
        manifestPath,
        extractedPath,
        originalPublishPath,
        manifest,
        extracted,
        originalPublish,
        currentPackage,
        typeOrigin,
        registryId,
        upgradeCapId: findUpgradeCapId(originalPublish),
    };
}

export function preflightFeatureUpgrade(options: {
    root: string; network: string; featureName: FeatureName;
}) {
    const validated = validateFeatureDeployment(
        options.root, options.network, options.featureName,
    );
    const packageDir = `contracts/world_${options.featureName}`;
    const manifestPath = path.resolve(options.root, packageDir, "Move.toml");
    if (!fs.statSync(manifestPath).isFile()) {
        throw new Error(`Split feature Move manifest is missing: ${manifestPath}`);
    }
    return {
        featureName: options.featureName,
        packageDir,
        upgradeCapId: validated.upgradeCapId,
        currentPackageId: validated.currentPackage,
        typeOrigin: validated.typeOrigin,
        registryId: validated.registryId,
    };
}

export function commitFeatureUpgrade(options: {
    root: string; network: string; featureName: FeatureName; upgradeOutputPath: string;
}) {
    const featureConfig = FEATURES[options.featureName];
    if (!featureConfig) throw new Error(`Unsupported split feature ${options.featureName}`);
    const upgradeOutput = readJson(path.resolve(options.upgradeOutputPath));
    const nextPublished = publishedChange(upgradeOutput, featureConfig.module);
    const nextPackage = address(nextPublished.packageId, "Upgraded package");
    const validated = validateFeatureDeployment(
        options.root, options.network, options.featureName, nextPackage,
    );
    const {
        feature, versionedManifestPath, manifestPath, extractedPath, manifest, extracted,
        currentPackage, typeOrigin,
    } = validated;
    if (nextPackage === currentPackage) {
        return { manifestPath, extractedPath, manifest, alreadyCommitted: true };
    }
    const nextManifest = buildUpgradedFeatureDeployment(
        manifest, options.featureName, nextPackage,
    );
    const nextExtracted = structuredClone(extracted);
    nextExtracted.features[feature.extractedFeature].packageId = nextPackage;
    if (address(nextManifest.capabilities[feature.capability].typeOrigin, "Preserved type origin") !== typeOrigin) {
        throw new Error("Upgrade attempted to replace the feature type origin");
    }
    // Commit the public manifest last. A crash before this rename leaves the
    // runtime on the old safe package. Recovery accepts that exact staged
    // extracted package and completes the manifest rename idempotently.
    atomicWriteJson(extractedPath, nextExtracted);
    atomicWriteJson(versionedManifestPath, nextManifest);
    return { manifestPath: versionedManifestPath, extractedPath, manifest: nextManifest };
}

function main() {
    const [mode, featureInput, network = "localnet", outputInput] = process.argv.slice(2);
    const featureName = featureInput as FeatureName;
    const feature = FEATURES[featureName];
    if (!feature) throw new Error(`Unsupported split feature ${featureInput}`);
    const root = path.resolve(process.cwd());
    if (mode === "preflight") {
        process.stdout.write(`${JSON.stringify(preflightFeatureUpgrade({
            root, network, featureName,
        }))}\n`);
        return;
    }
    if (mode === "commit" && outputInput) {
        const result = commitFeatureUpgrade({ root, network, featureName, upgradeOutputPath: outputInput });
        process.stdout.write(`${JSON.stringify(result)}\n`);
        return;
    }
    throw new Error("Usage: update-feature-deployment.ts preflight|commit FEATURE NETWORK [UPGRADE_JSON]");
}

if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) main();
