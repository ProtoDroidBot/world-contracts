# Smart Industry

`world::smart_industry` exposes the current Frontier Industry facility as a shared
Sui object. The game server supplies observations because Move cannot read the
local game database. Dapps and other Move contracts can read the shared object.

The existing `assembly::Assembly` remains the facility's lifecycle and energy
object. Its ID and owner capability are unchanged. Each `SmartIndustry` is derived
from the same ObjectRegistry using `IndustryKey { assembly_id: ID }`, so readers
can calculate its address without searching events. The ordinary `TenantItemId`
used for the parent and the `IndustryKey` used for its Industry data are distinct.

## Exposed state

- Parent assembly ID, tenant/item key, type ID, and observed assembly status
  (`1` offline, `2` online), read from the parent contract.
- Server-attested in-game owner and solar system IDs.
- Selected blueprint ID (`0` means none), runtime in seconds, input/output recipe
  quantities and maximum storage quantities.
- Actual input/output quantities aggregated by item type, in separate vectors.
- Revision, source observation time, and Sui Clock synchronization time, in
  milliseconds since the Unix epoch.
- Production job ID, running/discontinuing/stopped state, requested and completed
  runs, current/last run start and completion deadlines, and stop reason.

The Frontier server consumes one run's inputs when that run starts, adds its
products after the deadline, and repeats until the requested batch finishes or a
stop condition occurs. Discontinuing finishes the already paid run. Continuous
production has no requested-run limit. The server persists the paid recipe and
run progress so a restart can finish each due run exactly once.

These contracts mirror the resulting blueprint, inventory and production state.
They do not start production, mint items, transfer inventory custody, or
make the inventory balances spendable. Locations and inventories submitted to a
public chain become public observations. A retained record describes its last
observation; readers should also check whether the parent Assembly still exists.

## Live EveJS synchronization

The sibling `EveJS-Frontier` server now includes `suiIndustrySnapshot.ts`,
`suiIndustryChain.ts`, and `suiIndustrySync.ts`. Its existing five-second assembly
worker captures the current item store after assembly lifecycle reconciliation.
It reads `customInfo.evejsFrontierIndustry.blueprintID` and `.production`, authored build 3502403
recipes, and escrow item rows in input flag `20000` and output flag `20001`.
Escrow quantities are filtered by facility location and owner.

The worker creates the sidecar after its parent is available, then sends a full
replacement only when the blueprint, inventory, identity, or production/assembly
status changes. Production progress is part of the same synchronization
fingerprint, including transitions that leave inventory quantities unchanged.
Empty vectors clear previous contents. Source observations are checked again
immediately before the durable executor records a signed submission. The same
serialized queue and transaction journal used for Smart Assemblies handle
concurrent wallet operations and retries after uncertain transaction responses.
Unchanged state does not consume gas or advance timestamps.

The deployed world package must contain `smart_industry`. Publishing source files
does not modify an already deployed package. Deploy this checkout using the
project's world deployment procedure, synchronize that deployment with
`EveJS-Frontier/FrontierWorld.ps1 sync`, and rebuild/restart the EveJS server. Keep
the deployment package ID, registry, and ACL together; this integration uses the
existing localnet deployment configuration and authorized admin signer. An older
deployment without the production entry points cannot synchronize the new
observations; it must be upgraded before production can be reported synced.

For a manual **upgrade of an existing world**, retain the original world/Assembly
configuration. Set `SMART_INDUSTRY_PACKAGE_ID` to the upgraded package containing
the module, in both the server environment and CLI `.env`. The first package to
introduce this module is its type origin. If you upgrade it again, also set
`SMART_INDUSTRY_TYPE_ORIGIN` to that first Industry package ID while pointing
`SMART_INDUSTRY_PACKAGE_ID` at the latest implementation. Object derivation and
vector types use the origin; function calls use the implementation. For a fresh
deployment, both default to `WORLD_PACKAGE_ID` and need no overrides. These
settings do not publish or upgrade anything themselves.

The EveJS server can persist these upgrade IDs in a public `industry.json`
beside its synchronized `world.private.json` (normally under
`_local/frontier-world/<build>/`). Its format is:

```json
{
  "schemaVersion": 1,
  "chainId": "CHAIN_IDENTIFIER",
  "worldPackageId": "0xORIGINAL_WORLD_PACKAGE",
  "objectRegistryId": "0xORIGINAL_REGISTRY",
  "adminAclId": "0xORIGINAL_ACL",
  "packageId": "0xLATEST_INDUSTRY_IMPLEMENTATION",
  "typeOrigin": "0xFIRST_PACKAGE_CONTAINING_SMART_INDUSTRY"
}
```

Replace all placeholders with verified deployment values. `chainId` and the
three original world IDs must match the synchronized world configuration.
`EVEJS_SUI_INDUSTRY_CONFIG_PATH` selects another file location. The
`SMART_INDUSTRY_PACKAGE_ID` and `SMART_INDUSTRY_TYPE_ORIGIN` environment variables
override their respective file values; an invalid or mismatched file is always
rejected. With no file, existing environment/default behavior remains available.
Keep the original world configuration and extracted IDs unchanged when adding
an Industry upgrade; only the Industry implementation and type-origin settings
point to the added module.

This production upgrade preserves the original `Snapshot`, `SmartIndustry`, and
event layouts, and preserves the `create`/`sync` signatures. Production lives in
a dynamic field under the existing sidecar UID with name `{type: "u8", value: 0}`.
Its `ProductionRecord` contains `{revision, production}`. A compatible package
upgrade keeps existing sidecars and the original Industry type-origin setting.
The first production sync attaches the field to an existing sidecar. No world
reset or replacement registry is required.

Dynamic-field RPC reads must match `ProductionRecord.revision` against the parent
`SmartIndustry.revision` before combining inventory and progress. A missing field
is read as idle with `productionMirrored: false`, and cannot prove synchronized
production. The field's value type can originate in a later package than
`SmartIndustry`; clients verify the field's deterministic ID and sidecar owner.

The optional live HTTP API uses the existing wallet authentication mechanism:

- `POST /evejs/industry/auth/challenge` with `{ "walletAddress": "0x..." }`.
- Sign the returned `transactionData` with the wallet's transaction-signing API
  without submitting it, then `POST /evejs/industry/auth/session` with
  `{ "challengeId": "...", "signature": "..." }`.
- With the returned session's bearer token, call
  `POST /evejs/industry/<game-facility-id>/status` to read the live snapshot and
  chain sync status, or `POST /evejs/industry/<game-facility-id>/sync` to request a
  flush of the existing worker.

The live API requires the facility owner's authenticated character. It returns
the current facility data, `production` (`null` while idle), and a chain status of `disabled`,
`pending`, `synced`, or `error`, including confirmed object IDs and revision/time
fields when available. `chain.production` is the independently read chain value;
`chain.productionMirrored` confirms that a production field was read. `synced`
requires both inventory and production to equal the current local snapshot.
It verifies ownership again after asynchronous reads.
Public chain reads through the CLI or RPC do not require a game session.

## Contract calls and authorization

`new_item_stack` and `new_recipe_slot` construct entries. `new_snapshot` validates
the entire observation. All four vectors must contain at most 256 entries, be
strictly sorted by positive type ID, and have no duplicates or zero quantities.
Recipe capacity must cover one run. No selected blueprint requires zero runtime
and empty recipe vectors.

`create(registry, assembly, acl, observed_at_ms, snapshot, clock)` shares the new
object and emits `SmartIndustryCreatedEvent`. Initial revision is `1`.

`sync(industry, assembly, acl, expected_revision, observed_at_ms, snapshot, clock)`
atomically replaces it and emits `SmartIndustrySyncedEvent`. Both writes require
an authorized sponsor through `AdminACL`. Sync checks the exact parent and
revision and requires an observation newer than the previous one. Source time
cannot exceed Sui Clock by more than 30 seconds. On a revision conflict, capture
the current game state and read the chain again before retrying.

The new worker uses `create_with_production` and `sync_with_production`, which add
a `Production` argument immediately after `Snapshot`. `new_production` accepts
`job_id`, `state` (`0` idle, `1` running, `2` discontinuing, `3` stopped),
`requested_runs` (`0` continuous), `completed_runs`, `run_started_at_ms`,
`run_end_at_ms`, and `stop_reason` (empty unless stopped). `idle_production`
constructs the empty state. Legacy `create`/`sync` calls through the upgraded
implementation explicitly record idle production.

Production and inventory are written atomically with the same revision. Non-idle
jobs require a selected blueprint, positive job ID, increasing run timestamps,
and valid counters. A `COMPLETED` reason requires all finite requested runs to be
finished. Other reasons include `DISCONTINUED`, `INSUFFICIENT_INPUTS`,
`OUTPUT_CAPACITY_EXCEEDED`, `FACILITY_OFFLINE`, and `BLUEPRINT_CHANGED`.

All fields have public Move getters. Numeric owner/system and blueprint values
are attestations by the authorized server; the contract independently verifies
parent identity/status and snapshot structure, not the off-chain game database.

## CLI and SDK

The existing `SUI_NETWORK`, `SUI_RPC_URL`, `WORLD_PACKAGE_ID`, and
`deployments/<network>/extracted-object-ids.json` select the world. Reading and
printing a transaction plan do not require a signing key.

```bash
npm run industry -- read --assembly 0xASSEMBLY_OBJECT_ID
npm run industry -- sync --assembly 0xASSEMBLY_OBJECT_ID --snapshot facility.json
npm run industry -- sync --assembly 0xASSEMBLY_OBJECT_ID --snapshot facility.json --execute
```

Only `--execute` submits a transaction and requires `ADMIN_PRIVATE_KEY`. The
default sync command reads chain state, validates the source JSON, and prints a
transaction plan. It is not a simulation or a confirmation that the signer is
authorized. The live game worker is the normal sync path; the CLI is for explicit
server observations and diagnostics. Do not continually replay a saved file as
though it were current state.

Example `facility.json` (replace the observation timestamp and values with a
current server observation):

```json
{
  "observed_at_ms": "1700000000000",
  "production": {
    "job_id": "1", "state": "RUNNING", "requested_runs": "3", "completed_runs": "0",
    "run_started_at_ms": "1700000000000", "run_end_at_ms": "1700000012000", "stop_reason": null
  },
  "snapshot": {
    "owner_id": "90000001",
    "solar_system_id": "30000001",
    "blueprint_id": "1007",
    "run_time": "12",
    "inputs": [{ "type_id": "70001", "quantity": "10" }],
    "outputs": [],
    "blueprint_inputs": [{ "type_id": "70001", "quantity": "2", "max_quantity": "200" }],
    "blueprint_outputs": [{ "type_id": "70002", "quantity": "1", "max_quantity": "100" }]
  }
}
```

Example recipe/type numbers are illustrative, not an authored recipe. Use decimal
strings for u64 values. Unsafe JavaScript numbers and incomplete snapshots are
rejected. `ts-scripts/industry/client.ts` exports deterministic ID derivation,
typed chain reads, and pure transaction construction for other clients.
JSON uses named states and `requested_runs: null` for continuous production;
the transaction builder maps them to the numeric Move representation.

## Validation

```bash
sui move test --path contracts/world --build-env testnet smart_industry
npm run test:industry
pnpm exec tsc --noEmit
```

For server validation, build `EveJS-Frontier` and run its
`frontierSuiIndustry*.test.js` and Smart Assembly tests. All tests use synthetic
state or test scenarios; they do not publish contracts or modify the live chain.
