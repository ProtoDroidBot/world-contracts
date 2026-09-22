/** The server attests these observations; they do not create spendable inventory. */
export type ItemStack = { type_id: string; quantity: string };
export type RecipeSlot = ItemStack & { max_quantity: string };
export type IndustrySnapshot = {
    owner_id: string;
    solar_system_id: string;
    blueprint_id: string;
    run_time: string;
    inputs: ItemStack[];
    outputs: ItemStack[];
    blueprint_inputs: RecipeSlot[];
    blueprint_outputs: RecipeSlot[];
};
export type IndustryProduction = {
    job_id: string;
    state: "RUNNING" | "DISCONTINUING" | "STOPPED";
    requested_runs: string | null;
    completed_runs: string;
    run_started_at_ms: string;
    run_end_at_ms: string;
    stop_reason: string | null;
};
export type IndustryLaneProduction = {
    lane_id: string;
    production: IndustryProduction | null;
};
export type IndustryLaneState = {
    lane_id: string;
    snapshot: IndustrySnapshot;
    production: IndustryProduction | null;
};

export function u64(value: unknown, label: string, positive = false): string {
    if (
        !(typeof value === "string" && /^\d+$/.test(value)) &&
        !(typeof value === "number" && Number.isSafeInteger(value) && value >= 0) &&
        typeof value !== "bigint"
    )
        throw new Error(`${label} must be an exact unsigned integer`);
    const integer = BigInt(value as string | number | bigint);
    if (integer < (positive ? 1n : 0n) || integer > (1n << 64n) - 1n) {
        throw new Error(`${label} is outside the u64 range`);
    }
    return integer.toString();
}

function record(value: unknown, label: string): Record<string, unknown> {
    if (!value || typeof value !== "object" || Array.isArray(value)) {
        throw new Error(`${label} must be an object`);
    }
    return value as Record<string, unknown>;
}

function stacks(value: unknown, label: string, recipe: true): RecipeSlot[];
function stacks(value: unknown, label: string, recipe: false): ItemStack[];
function stacks(value: unknown, label: string, recipe: boolean): ItemStack[] {
    if (!Array.isArray(value) || value.length > 256) {
        throw new Error(`${label} must be an array of at most 256 entries`);
    }
    const result = value.map((entry, index) => {
        const row = record(entry, `${label}[${index}]`);
        const item = {
            type_id: u64(row.type_id, `${label} type_id`, true),
            quantity: u64(row.quantity, `${label} quantity`, true),
        };
        if (!recipe) return item;
        const max_quantity = u64(row.max_quantity, `${label} max_quantity`, true);
        if (BigInt(max_quantity) < BigInt(item.quantity)) {
            throw new Error(`${label} max_quantity must cover one run`);
        }
        return { ...item, max_quantity };
    });
    result.sort((a, b) =>
        BigInt(a.type_id) < BigInt(b.type_id) ? -1 : BigInt(a.type_id) > BigInt(b.type_id) ? 1 : 0
    );
    if (new Set(result.map((item) => item.type_id)).size !== result.length) {
        throw new Error(`${label} contains duplicate type IDs`);
    }
    return result;
}

/** Normalize integer strings and ordering, rejecting incomplete snapshots. */
export function parseIndustrySnapshot(value: unknown): IndustrySnapshot {
    const row = record(value, "snapshot");
    if (row.production != null)
        throw new Error("Production must be supplied separately from the inventory snapshot");
    const snapshot: IndustrySnapshot = {
        owner_id: u64(row.owner_id, "owner_id", true),
        solar_system_id: u64(row.solar_system_id, "solar_system_id", true),
        blueprint_id: u64(row.blueprint_id, "blueprint_id"),
        run_time: u64(row.run_time, "run_time"),
        inputs: stacks(row.inputs, "inputs", false),
        outputs: stacks(row.outputs, "outputs", false),
        blueprint_inputs: stacks(row.blueprint_inputs, "blueprint_inputs", true),
        blueprint_outputs: stacks(row.blueprint_outputs, "blueprint_outputs", true),
    };
    if (snapshot.blueprint_id === "0") {
        if (
            snapshot.run_time !== "0" ||
            snapshot.blueprint_inputs.length ||
            snapshot.blueprint_outputs.length
        ) {
            throw new Error("No blueprint requires zero run_time and empty recipe vectors");
        }
    } else if (snapshot.run_time === "0") {
        throw new Error("A selected blueprint requires a positive run_time in seconds");
    }
    return snapshot;
}

export function parseIndustryProduction(value: unknown): IndustryProduction | null {
    if (value == null) return null;
    const row = record(value, "production");
    if (!["RUNNING", "DISCONTINUING", "STOPPED"].includes(String(row.state))) throw new Error("Invalid production state");
    const production: IndustryProduction = {
        job_id: u64(row.job_id, "job_id", true), state: row.state as IndustryProduction["state"],
        requested_runs: row.requested_runs === null ? null : u64(row.requested_runs, "requested_runs", true),
        completed_runs: u64(row.completed_runs, "completed_runs"),
        run_started_at_ms: u64(row.run_started_at_ms, "run_started_at_ms"),
        run_end_at_ms: u64(row.run_end_at_ms, "run_end_at_ms"),
        stop_reason: row.stop_reason as string | null,
    };
    if (production.stop_reason !== null && (typeof production.stop_reason !== "string" || !/^[A-Z][A-Z0-9_]{0,63}$/.test(production.stop_reason))) {
        throw new Error("Invalid production stop reason");
    }
    if (BigInt(production.run_end_at_ms) <= BigInt(production.run_started_at_ms) ||
        (production.requested_runs !== null && (BigInt(production.completed_runs) > BigInt(production.requested_runs) ||
        (production.state !== "STOPPED" && production.completed_runs === production.requested_runs)))) throw new Error("Invalid production progress");
    if ((production.state === "STOPPED") !== (production.stop_reason !== null)) throw new Error("Invalid production stop state");
    if (production.stop_reason === "COMPLETED" && (production.requested_runs === null || production.completed_runs !== production.requested_runs)) {
        throw new Error("Completed production has unfinished runs");
    }
    return production;
}

export function parseIndustryLaneProductions(value: unknown): IndustryLaneProduction[] {
    if (!Array.isArray(value) || value.length === 0 || value.length > 16) {
        throw new Error("Production lanes must contain between one and sixteen entries");
    }
    let previous = 0n;
    const lanes = value.map((entry, index) => {
        const row = record(entry, `production lanes[${index}]`);
        const lane_id = u64(row.lane_id, "lane_id", true);
        if (BigInt(lane_id) <= previous || BigInt(lane_id) > 16n) {
            throw new Error("Production lanes must be strictly increasing");
        }
        previous = BigInt(lane_id);
        return { lane_id, production: parseIndustryProduction(row.production) };
    });
    if (lanes[0].lane_id !== "1") throw new Error("Production lane one is required");
    return lanes;
}

export function parseIndustryLaneStates(value: unknown): IndustryLaneState[] {
    if (!Array.isArray(value) || value.length === 0 || value.length > 16) {
        throw new Error("Industry lanes must contain between one and sixteen entries");
    }
    let previous = 0n;
    let owner: string | null = null;
    let solarSystem: string | null = null;
    const lanes = value.map((entry, index) => {
        const row = record(entry, `industry lanes[${index}]`);
        const lane_id = u64(row.lane_id, "lane_id", true);
        if (BigInt(lane_id) <= previous || BigInt(lane_id) > 16n) {
            throw new Error("Industry lanes must be strictly increasing");
        }
        previous = BigInt(lane_id);
        const snapshot = parseIndustrySnapshot(row.snapshot);
        const production = parseIndustryProduction(row.production);
        if (production && snapshot.blueprint_id === "0") {
            throw new Error("Lane production requires a selected blueprint");
        }
        owner ??= snapshot.owner_id;
        solarSystem ??= snapshot.solar_system_id;
        if (snapshot.owner_id !== owner || snapshot.solar_system_id !== solarSystem) {
            throw new Error("All Industry lanes must share owner and solar system identity");
        }
        return { lane_id, snapshot, production };
    });
    if (lanes[0].lane_id !== "1") throw new Error("Industry lane one is required");
    return lanes;
}
