# @evefrontier/world-sdk

A thin, builder-style TypeScript SDK for the EVE Frontier `world-contracts`

## Install

```sh
npm install @evefrontier/world-sdk @mysten/sui
```

`@mysten/sui` (v2) is a peer dependency.

## Usage

```ts
import { Transaction } from "@mysten/sui/transactions";
import { createWorldClient, createCharacter, getWorldConfig } from "@evefrontier/world-sdk";

const config = getWorldConfig("live");
const client = createWorldClient({ config });

const tx = new Transaction();
createCharacter(tx, config, {
    inGameId: 42n,
    tenant: "my-tenant",
    tribeId: 1,
    owner: "0x...",
});

// sign + execute `tx` with your keypair / wallet
```

### Local / CI

On `local`, load config from a generated `world.json` manifest:

```ts
import { loadWorldConfig, deriveObjectId } from "@evefrontier/world-sdk";

const config = loadWorldConfig("deployments/localnet/world.json");
const id = deriveObjectId(config, { id: 7n, tenant: "my-tenant" });
```

## Unified industry

Refining (`INDUSTRY_KIND.refining`) and manufacturing (`INDUSTRY_KIND.manufacturing`)
use the same recipe, job and transaction builders. Industry runs inside the
inventory package and accepts tenant-aware `ItemV2` assets. No migration from legacy `Item` assets is supplied. A game operator must independently
verify provenance before admitting any reconciled legacy balance through the trusted
V2 import boundary; a legacy export event alone is insufficient evidence.

Governed setup uses `createItemTypeRegistry`, `registerIndustryItemType`,
`createRecipeRegistry`, `publishIndustryRecipe`, `installInventoryV2` and
`installIndustry`. Catalog creation shares an object and returns its ID; use the
created-object effects to discover it and reference it in the next transaction.
Publishing added modules during an upgrade does not bootstrap catalogs.

Recipes use independent `RecipeLine[]` inputs and outputs, each containing
`{ typeId: bigint, quantityPerBatch: bigint }`. Use `readIndustryRecipe` to decode
an immutable revision and `quoteIndustryRecipe` to calculate every required input,
output, deficit, canonical volume and duration. Quotes are advisory; admission
rechecks current policy and capacity on-chain. `industryJson` serializes bigint
values to decimal strings without losing precision.

An owner exposes `industryStartRequirement` in an action. Then the funding flow is:

```ts
const inputsA = withdrawOwnedV2(tx, config, sourceA, {
  types, cap, moduleId: sourceModuleA,
  amounts: [{ typeId: 1001n, quantity: 300n }],
});
const inputsB = withdrawOwnedV2(tx, config, sourceB, {
  types, cap, moduleId: sourceModuleB,
  amounts: [{ typeId: 1002n, quantity: 120n }],
});
const inputs = concatIndustryItems(tx, config, [inputsA, inputsB]);
const request = interact(tx, config, tx.object(facility), "industry_start", []);
verifyProximity(tx, config, request, []);
verifyCaller(tx, config, request, cap);
const jobId = startIndustryJob(tx, config, facility, request, {
  types, recipes, recipe: recipeId, cap, inputs, batches: 3n,
});
completeRequest(tx, config, tx.object(facility), request);
```

For owned standalone assets, `makeIndustryItems(tx, config, itemIds)` builds the
input vector. Combine bulk withdrawals with `concatIndustryItems`, which invokes
Move vector concatenation. A vector returned by withdrawal or claim must never be
wrapped as a single item inside another vector. Recipe and bulk amount arrays must
contain unique types in ascending type-ID order.

Once mature, `settleIndustryJob` consumes all inputs and creates all outputs in the
job vault. `claimIndustryOutputs` returns the entire output vector, which can be
passed directly to `depositManyV2` (along with exact aggregate amounts) or
`transferIndustryItems`. For zero-duration recipes, funding, settling, claiming
and depositing can all share one PTB. If a separately committed job's destination
is full, a failed claim/deposit PTB leaves its products available for retry.

`cancelIndustryJob` followed by `claimIndustryRefund` returns
`[vector<ItemV2>, Coin<SUI>]`; consume both values in the transaction. Job recovery
builders complete their protected Requests internally, so removal of owner actions
cannot strand accepted jobs. The beneficiary's AccessCap is required for claims,
cancellation and refunds. `setIndustryPolicy` changes future starts and
`setIndustryLimits` updates trusted capacity allocations. `readIndustryJob`
provides a lossless summary plus Running/Completed/Cancelled state, while
`decodeIndustryEvent` decodes the full input/output arrays for all lifecycle events.

All u64 arguments use bigint. The current admission limits are 32 input types,
32 output types, 64 supplied item objects and 1,000,000 batches (individual recipes
and assemblies can impose smaller limits).

### Localnet fixture and verification

`pnpm --filter @evefrontier/world-sdk seed:industry` creates synthetic types,
recipes covering all four input/output cardinalities, inventories and one unified
industry assembly. It is restricted to localnet and records the fixture and
catalogs in `deployments/localnet/world.json`; `seed-world.sh localnet` includes it.
Use `itemTypeRegistry(config, tenant)` and `recipeRegistry(config, tenant)` for the
scoped catalog entries. No synthetic recipe is a production game recipe.

After deploying this checkout and exporting a funded admin `SUI_PRIVATE_KEY`, set
`SUI_GRPC_URL` (or `SUI_RPC_URL`) when the local node uses a nondefault endpoint.
The default is `http://127.0.0.1:9000`. For example, the isolated verification node
uses `SUI_GRPC_URL=http://127.0.0.1:19000`. Then run:

```sh
pnpm --filter @evefrontier/world-sdk typecheck
pnpm --filter @evefrontier/world-sdk test
pnpm --filter @evefrontier/world-sdk test:integration src/__integration__/industry.test.ts
```

The industry integration test provisions its own isolated fixtures, exercises
array-to-array processing, multi-source funding, rollback on the final destination
line, retryable claims, timed cancellation and customer recovery after the owner
removes every normal action. A second test exercises the complete admitted maximum:
32 input types supplied as 64 fragmented stacks, with all 32 output types delivered
in one transaction.

## Versioning

Manual semver. Each release states which contract release it supports — a
breaking Move ABI change is a breaking SDK release.

## License

MIT
