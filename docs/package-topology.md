# Package topology and deployment identity

The deployed world is one base package plus five first-party feature packages. Do not assume that a module name implies the base-world package address. Runtime callers use the feature's configured call-package ID, while object derivation and type checks use its stable type-origin ID.

## Current package map

| Package directory | Runtime module | Direct local dependencies | Manifest fields |
| --- | --- | --- | --- |
| `contracts/world` | Base world modules such as `character`, `assembly`, `gate`, and `storage_unit` | None | `worldPackageId`, `objectRegistryId`, `adminAclId` |
| `contracts/world_npc` | `npc` | `world` | `packageId`, `typeOrigin`, `npcRegistryId` |
| `contracts/world_assembly_access` | `assembly_access` | `world`, `world_npc` | `accessPackageId`, `accessTypeOrigin`, `accessRegistryId` |
| `contracts/world_catapult` | `catapult` | `world` | `catapultPackageId`, `catapultTypeOrigin`, `catapultRegistryId` |
| `contracts/world_smart_industry` | `smart_industry` | `world` | `industryPackageId`, `industryTypeOrigin`, `industryRegistryId` |
| `contracts/world_transponder` | `transponder` | `world`, `world_npc` | `transponderPackageId`, `transponderTypeOrigin`, `transponderRegistryId` |

The source address names (`world_npc`, `world_assembly_access`, and so on) are compile-time names. A submitted Move target has the form `<configured-call-package>::<module>::<function>`.

Each feature identity has three distinct parts:

- **Call package:** the latest compatible implementation used for Move calls. It changes after a package upgrade.
- **Type origin:** the first package that introduced the feature's key/object types. It remains stable across upgrades so deterministic IDs and exact type checks do not change.
- **Registry:** the shared feature registry created by the initial package. It remains stable across compatible upgrades.

The base-world package, Object Registry, and Admin ACL are separate invariants. Replacing those values is a new world, not a feature upgrade.

## Fresh deployment

`scripts/deploy-world.sh` publishes in dependency order:

1. `world`;
2. `world_npc`;
3. `world_catapult`;
4. `world_smart_industry`;
5. `world_transponder`;
6. `world_assembly_access`.

It then writes `deployments/<network>/extracted-object-ids.json` and the combined public feature manifest. On a fresh deployment, every feature's call package and type origin are the same newly published feature-package ID.

The feature packages reuse `contracts/world/Pub.<network>.toml` so their local `world` and `world_npc` dependencies resolve to the packages published earlier in the same deployment. This shared publication file is an input/output artifact, not an assertion that the feature modules live in the base package.

`deploy-world.sh` begins with `pnpm clean` and removes deployment/publication outputs. It is a fresh-publish command. It is not an upgrade command and must not be used when the intent is to preserve an existing world identity.

## Combined feature manifest

The authoritative public manifest is `deployments/<network>/npc-deployment.json`. The filename is historical; schema version 1 binds all five feature packages and registries:

```json
{
  "schemaVersion": 1,
  "chainId": "CHAIN_IDENTIFIER",
  "worldPackageId": "0xORIGINAL_WORLD_PACKAGE",
  "objectRegistryId": "0xORIGINAL_OBJECT_REGISTRY",
  "adminAclId": "0xORIGINAL_ADMIN_ACL",
  "packageId": "0xLATEST_NPC_PACKAGE",
  "typeOrigin": "0xFIRST_NPC_PACKAGE",
  "npcRegistryId": "0xNPC_REGISTRY",
  "accessPackageId": "0xLATEST_ACCESS_PACKAGE",
  "accessTypeOrigin": "0xFIRST_ACCESS_PACKAGE",
  "accessRegistryId": "0xACCESS_REGISTRY",
  "catapultPackageId": "0xLATEST_CATAPULT_PACKAGE",
  "catapultTypeOrigin": "0xFIRST_CATAPULT_PACKAGE",
  "catapultRegistryId": "0xCATAPULT_REGISTRY",
  "industryPackageId": "0xLATEST_INDUSTRY_PACKAGE",
  "industryTypeOrigin": "0xFIRST_INDUSTRY_PACKAGE",
  "industryRegistryId": "0xINDUSTRY_REGISTRY",
  "transponderPackageId": "0xLATEST_TRANSPONDER_PACKAGE",
  "transponderTypeOrigin": "0xFIRST_TRANSPONDER_PACKAGE",
  "transponderRegistryId": "0xTRANSPONDER_REGISTRY"
}
```

All addresses are canonical, nonzero Sui addresses. The chain and base-world values must match `extracted-object-ids.json` and the base publication metadata. Current EveJS synchronization treats the version-1 manifest as one atomic record; partial feature manifests are not supported.

## Upgrade invariants and current limitation

A supported feature upgrade must:

1. use that feature's existing `UpgradeCap` and an allowed upgrade policy;
2. compile against compatible base-world and, where applicable, NPC package APIs;
3. preserve the feature type origin and registry;
4. replace only the feature call-package ID in the combined manifest;
5. retain the original base-world package, Object Registry, and Admin ACL;
6. reconcile or quiesce pending signed transaction journals before switching the runtime fingerprint; and
7. store the new publication evidence without deleting the original deployment evidence.

The repository does not yet provide a per-feature upgrade script that performs these steps. `ts-scripts/utils/write-npc-deployment.ts` is a fresh-deployment writer and deliberately sets every type origin to its newly published package. Do not use it to author upgrade metadata.

The feature packages also require a compatible base ABI. `world_npc` calls NPC bridge functions in `character`; access and transponder depend on `world_npc`; the other sidecars call base assembly/gate APIs. Package splitting isolates feature type origins, but does not make the features installable on an arbitrary older base package. Historical base-package bytecode remains callable after an upgrade, so new guard logic does not retroactively constrain old entry points.

## Synchronization and verification boundary

EveJS `FrontierWorld.ps1 sync` validates the base deployment, base publication metadata, live chain ID, combined manifest schema, canonical addresses, and base-world bindings. It copies only the public manifest fields beside the protected `world.private.json`.

Current synchronization does not query each live feature package for its expected module and does not include the combined manifest or per-feature publish outputs in the private config's deployment hashes. Before activating an upgraded manifest, independently verify:

- the call package exists and exposes the expected normalized module;
- the registry exists as a shared object with the exact type-origin type;
- the retained type origin and registry match the prior deployment;
- the `UpgradeCap` owner and policy are the intended values; and
- a feature-specific dry run or transaction simulation succeeds.

These checks are deployment requirements even when address/schema validation passes.

## Build and test commands

Use the Sui CLI supplied by the efctl build environment so the CLI and pinned framework agree. The aggregate scripts use POSIX `find`/`xargs` and are intended for that Linux environment:

```sh
pnpm install
pnpm build
pnpm test
pnpm test:npc-deployment
pnpm test:industry
```

Focused Move suites can be run independently:

```sh
sui move test --path contracts/world
sui move test --path contracts/world_npc
sui move test --path contracts/world_assembly_access
sui move test --path contracts/world_catapult
sui move test --path contracts/world_smart_industry
sui move test --path contracts/world_transponder
```

Tests and source must be committed and reviewed together with intentional `Move.lock` changes. Generated publication files and deployment JSON are environment-specific evidence; define their retention policy explicitly rather than relying on an uncommitted working tree.
