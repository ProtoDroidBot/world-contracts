import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

export type AssemblyEnergyEntry = {
    typeID: number;
    name: string;
    energyRequired: number;
};

export type AssemblyEnergyManifest = {
    schemaVersion: 1;
    clientBuild: number;
    assemblies: AssemblyEnergyEntry[];
};

const DEFAULT_CONFIG_PATH = path.resolve(
    path.dirname(fileURLToPath(import.meta.url)),
    "../../config/assembly-energy.json"
);

export function parseAssemblyEnergyManifest(
    value: unknown,
    expectedBuild?: number
): AssemblyEnergyManifest {
    if (!value || typeof value !== "object" || Array.isArray(value)) {
        throw new Error("Assembly energy configuration must be a JSON object");
    }
    const source = value as Record<string, unknown>;
    if (source.schemaVersion !== 1) {
        throw new Error("Assembly energy configuration has an unsupported schema version");
    }
    if (
        !Number.isSafeInteger(source.clientBuild) ||
        Number(source.clientBuild) <= 0 ||
        (expectedBuild !== undefined && source.clientBuild !== expectedBuild)
    ) {
        throw new Error(
            `Assembly energy configuration does not match client build ${expectedBuild ?? "unknown"}`
        );
    }
    if (!Array.isArray(source.assemblies) || source.assemblies.length === 0) {
        throw new Error("Assembly energy configuration must contain assemblies");
    }

    const seen = new Set<number>();
    let previousTypeID = 0;
    const assemblies = source.assemblies.map((raw, index): AssemblyEnergyEntry => {
        if (!raw || typeof raw !== "object" || Array.isArray(raw)) {
            throw new Error(`Assembly energy entry ${index} must be an object`);
        }
        const entry = raw as Record<string, unknown>;
        const typeID = Number(entry.typeID);
        const energyRequired = Number(entry.energyRequired);
        const name = typeof entry.name === "string" ? entry.name.trim() : "";
        if (!Number.isSafeInteger(typeID) || typeID <= 0) {
            throw new Error(`Assembly energy entry ${index} has an invalid typeID`);
        }
        if (seen.has(typeID)) {
            throw new Error(`Assembly energy configuration contains duplicate typeID ${typeID}`);
        }
        if (typeID <= previousTypeID) {
            throw new Error("Assembly energy entries must be sorted by ascending typeID");
        }
        if (!name || /[\u0000-\u001f\u007f]/.test(name)) {
            throw new Error(`Assembly energy entry ${typeID} has an invalid name`);
        }
        if (!Number.isSafeInteger(energyRequired) || energyRequired < 0) {
            throw new Error(`Assembly energy entry ${typeID} has an invalid energyRequired`);
        }
        seen.add(typeID);
        previousTypeID = typeID;
        return { typeID, name, energyRequired };
    });

    return {
        schemaVersion: 1,
        clientBuild: Number(source.clientBuild),
        assemblies,
    };
}

export function readAssemblyEnergyManifest(
    env: NodeJS.ProcessEnv = process.env
): AssemblyEnergyManifest & { path: string } {
    const configPath = path.resolve(
        String(env.ASSEMBLY_ENERGY_CONFIG_PATH || DEFAULT_CONFIG_PATH).trim()
    );
    let value: unknown;
    try {
        value = JSON.parse(fs.readFileSync(configPath, "utf8"));
    } catch (cause) {
        throw new Error(`Cannot read assembly energy configuration: ${configPath}`, { cause });
    }
    const buildText = String(env.EVEJS_CLIENT_BUILD || "3502403").trim();
    if (!/^\d+$/.test(buildText)) {
        throw new Error("EVEJS_CLIENT_BUILD must be a positive integer");
    }
    const expectedBuild = Number(buildText);
    if (!Number.isSafeInteger(expectedBuild) || expectedBuild <= 0) {
        throw new Error("EVEJS_CLIENT_BUILD must be a positive integer");
    }
    return { ...parseAssemblyEnergyManifest(value, expectedBuild), path: configPath };
}

export function planAssemblyEnergyReconciliation(
    current: ReadonlyArray<{ typeID: number; energyRequired: number }>,
    manifest: AssemblyEnergyManifest
) {
    const existing = new Map(current.map((entry) => [entry.typeID, entry.energyRequired]));
    const desired = new Map(
        manifest.assemblies
            .filter((entry) => entry.energyRequired > 0)
            .map((entry) => [entry.typeID, entry.energyRequired])
    );
    return {
        remove: [...existing]
            .filter(([typeID]) => !desired.has(typeID))
            .map(([typeID]) => typeID)
            .sort((a, b) => a - b),
        set: [...desired]
            .filter(([typeID, energyRequired]) => existing.get(typeID) !== energyRequired)
            .map(([typeID, energyRequired]) => ({ typeID, energyRequired }))
            .sort((a, b) => a.typeID - b.typeID),
    };
}
