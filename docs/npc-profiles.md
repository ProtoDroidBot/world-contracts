# NPC profiles

`world::npc` adds explicit on-chain NPC identity and lifecycle state to the existing Character model. Each NPC retains a shared `character::Character` and wallet-owned `character::PlayerProfile` for compatibility, and receives a separate shared `npc::NpcProfile`. Existing Character and PlayerProfile struct layouts remain unchanged.

The profile is derived under the world ObjectRegistry using `NpcProfileKey { character_id: ID }`. This key has its own type and does not consume another ordinary `TenantItemId`. Readers can calculate its object ID from the registry, Character ID, and the NPC module's type-origin package. A dynamic field on the Character marks it as an NPC and points to that profile.

## Faction and pilot identity

NPC game-character IDs are restricted to `1500000000..1599999999`, inclusive. The EveJS human allocator and human provisioning path exclude this range. Ship/entity IDs remain independent and can change when the pilot respawns.

Faction keys use `<factionID>-<factionStringOnlyID>`, with `0` for an absent numeric ID and `none` for an absent string. Examples are `500012-none`, `0-osa`, and `500012-blood-raiders`. The string is canonical lowercase ASCII, begins with a letter or digit, and allows letters, digits, hyphens and underscores, up to 96 characters. The literal input `none` is reserved for absence. Server code trims/lowercases input before submission; contract code validates the canonical representation.

The registry binds each tenant/faction pair to one immutable faction wallet and AdminACL. Multiple NPC profiles in that faction share the wallet, while retaining distinct game-character and Character/Profile IDs. A conflicting wallet or ACL cannot overwrite an existing binding. Profile registration validates the parent Character's reserved ID and wallet. The server's deterministic development wallet namespace is `<tenant>:npc-faction:<canonical faction key>`; the contract checks identity and binding, rather than attempting to derive a private key.

## Contract API

All state-changing NPC operations require an authorized sponsor through the world AdminACL.

- `create_npc_character`: receives the normal Character creation inputs, followed by faction ID/string and initial lifecycle values (`incarnation`, `active_entity_id`, `deaths`). It creates the compatible Character/Profile pair and registers the shared NPC profile atomically, returning the Character for the ordinary `character::share_character` call.
- `register_profile(registry, character, admin_acl, faction_id, faction_string_id, incarnation, active_entity_id, deaths, ctx)`: adds the deterministic profile and NPC marker to an existing unmarked Character in the reserved NPC range. It supports reconciling NPC Characters created before the custom module was available.
- `sync_lifecycle(profile, admin_acl, expected_revision, incarnation, active_entity_id, deaths, ctx)`: applies a monotonic lifecycle snapshot. It accepts coalesced updates across incarnations, rejects stale revisions and decreasing counters, and cannot change or reactivate an entity within the same incarnation. Clearing the active entity in that incarnation can account for at most one death. An exact duplicate snapshot leaves the revision unchanged.
- `retire(profile, admin_acl, expected_revision, ctx)`: permanently retires the pilot, clears its active entity, and advances the revision. Retirement blocks later lifecycle synchronization.

`character::is_npc_character` and `character::npc_profile_id` expose the dynamic marker. The upgraded Character mutation functions reject deletion and changes to wallet, tenant, or tribe for marked NPC Characters. This preserves the immutable profile/Character relationship through the new entry points. Sui retains old package bytecode, so an upgrade cannot retroactively enforce these new checks on calls to a historical implementation.

Public profile accessors expose `id`, `character_id`, `registry_id`, `admin_acl_id`, `tenant`, `npc_id`, `profile_faction_key`, `wallet_address`, `revision`, `incarnation`, `active_entity_id`, `deaths`, and `is_retired`. `new_profile_key` constructs the deterministic key for Move readers. Registration emits `NpcProfileRegistered`; lifecycle changes and retirement emit `NpcLifecycleSynced`.

Normal death and respawn use lifecycle synchronization, preserving the Character, PlayerProfile, faction binding, and NpcProfile. Retirement is separate and explicit. Do not delete/recreate a Character on death: the registry's derived identity is not reclaimable after deletion.

Deleting a Character through historical bytecode or another external administrative path can leave its separate NpcProfile alive. Readers must verify the parent as well as the profile. The server cannot treat the remaining profile as a healthy Character or reclaim its consumed derivation key; recovery requires an explicit administrative migration or new world.

## Deployment identity and upgrades

A fresh world publish containing this module uses its world package ID as both the NPC call target and type origin. For an upgrade, keep the original base-world configuration and objects. The NPC call target is the latest implementation package; its type origin is the first package introducing `NpcProfile` and `NpcProfileKey`. Retain that origin across later upgrades or readers will calculate different profile IDs.

The EveJS server reads `EVEJS_SUI_NPC_PACKAGE_ID` and `EVEJS_SUI_NPC_TYPE_ORIGIN`, or a public `npc-deployment.json` beside its synchronized `world.private.json`. `EVEJS_SUI_NPC_CONFIG_PATH` selects an explicit file. Its schema is:

```json
{
  "schemaVersion": 1,
  "chainId": "CHAIN_IDENTIFIER",
  "worldPackageId": "0xORIGINAL_WORLD_PACKAGE",
  "objectRegistryId": "0xORIGINAL_REGISTRY",
  "adminAclId": "0xORIGINAL_ACL",
  "packageId": "0xLATEST_NPC_IMPLEMENTATION",
  "typeOrigin": "0xFIRST_PACKAGE_CONTAINING_NPC",
  "accessPackageId": "0xLATEST_ASSEMBLY_ACCESS_IMPLEMENTATION",
  "accessTypeOrigin": "0xFIRST_PACKAGE_CONTAINING_ASSEMBLY_ACCESS"
}
```

Replace placeholders with verified deployment values. Base chain/package/registry/ACL values must match the synchronized world. Environment overrides take precedence per field but cannot mask malformed or mismatched file data. The conventional sibling is optional; an explicitly selected file must exist. The server revalidates the deployment fingerprint before submitting a signed operation.

The assembly-access pair is optional for manifests created before that module existed, but the two fields must appear together. When absent, the server falls back to the configured NPC package for backward compatibility and chain verification fails closed if that package does not contain `assembly_access`. `EVEJS_SUI_ASSEMBLY_ACCESS_PACKAGE_ID` and `EVEJS_SUI_ASSEMBLY_ACCESS_TYPE_ORIGIN` provide the equivalent explicit overrides. Keeping the access type origin independent is required when `assembly_access` is introduced by a later package upgrade than `npc`.

Keep the authoritative manifest in `deployments/localnet/npc-deployment.json`. EveJS `FrontierWorld.ps1 sync` validates and copies its public runtime fields beside `world.private.json`, retaining the original world identity. Synchronization requires canonical full-length nonzero addresses and rejects malformed or mismatched manifests. If the source is absent but a destination manifest exists, sync fails closed and preserves that file for explicit reconciliation; it will not silently delete upgrade metadata or fall back to the base package. `sync -DryRun` performs validation without changing files. Synchronization itself does not publish or upgrade contracts.

The existing `scripts/deploy-world.sh` performs a fresh publish and cleans deployment outputs. It is not an upgrade procedure and must not be used to silently replace an existing world. Base-world synchronization also hashes its original deployment/publication artifacts: preserve those and store upgrade publication metadata separately. Existing synchronization assumes its base package identifies the original Character, TenantItemId, ObjectRegistry, and AdminACL types.

Before an upgrade, verify ownership and the policy of the existing UpgradeCap. These changes preserve old struct layouts and public signatures, but change some Character function bodies; an immutable or additive-only upgrade policy may disallow them. Quiesce the NPC worker and reconcile outstanding journals against the original configuration before switching its NPC package settings. A pending signed transaction is bound to its original chain/package fingerprint: the worker retains it and refuses to silently replay or discard it after a configuration change.

Source edits and these settings do not deploy anything. A deployment without this module must fail NPC provisioning, rather than treating a plain Character/PlayerProfile pair as a confirmed NPC. The server's NPC worker may register an existing compatible reserved-ID Character after the custom module is deployed; it does not publish, upgrade, or reset the chain itself.

## Verification

From this world-contracts checkout, `sui move test --path contracts/world` builds and runs the Move tests without submitting a live transaction. The test coverage includes faction-wallet consistency, reserved character IDs, profile registration, lifecycle revisions/death/respawn, and retirement.

In `EveJS-Frontier`, run `npm run build` followed by `npm run test:frontier-npc-identities` to check the server integration using an isolated game store and mocked chain clients. The deployment-config tests cover type-origin separation, base-world mismatches, malformed configuration, and changes between transaction preparation and submission. Actual publication or upgrade is an explicit deployment operation outside these tests.

### Validation on 2026-09-19

The installed CLI was `sui 1.78.0-d8459684b41e`. The checkout's pinned framework commit `b0535f1f3a3310e71790e90d8ae4e8ca840c897e` compiled the sources, but that CLI could not execute its framework: both NPC tests and existing Character tests failed before their test bodies with `sui::funds_accumulator` / `MISSING_DEPENDENCY` / `UNEXPECTED_VERIFIER_ERROR`. This is a toolchain/framework mismatch, not a passing test run for that pinned dependency.

An isolated package copy used the already-cached framework commit `25ac21790b21157a3872ffa240546a3950a371be` (2026-08-19), with `implicit-dependencies = false` and local `sui`/`std` dependencies only in the copy. Against that compatible framework, all **352 world tests passed**, including **32 NPC tests** and **18 existing Character tests**. The command was `sui move test --path <isolated-package> --build-env testnet --silence-warnings --no-lint`.

The original `Move.toml` and `Move.lock` were not modified for validation, and no package was published or upgraded. Before deployment, use a CLI compatible with the chosen pinned framework and rerun the tests and chain-specific upgrade checks.

### Localnet synchronization on 2026-09-19

The current `sui-playground` container provides `sui 1.80.0-ceaaff1cc84c`, matching the world publication. All **352 world tests passed with the project's pinned framework** using that CLI.

The active Localnet was freshly published with the NPC module already present, so no upgrade transaction was required:

- Chain: `975e618c`.
- Base world, NPC call target, and first NPC type origin: `0xb3fa0f21d69d5adc5ce4cfbf384ff4115a158161b0f52c208a261ffbfd55eca0`.
- ObjectRegistry: `0x52621e07e445933925dea0330668741c964bda7239eae5372d693abfc094a4dd`.
- AdminACL: `0x51d75d762ed87a01f55c6a912278158241eaf3325dcb30ab6e9200988a47dddd`.

The authoritative public manifest is `deployments/localnet/npc-deployment.json`. EveJS `FrontierWorld.ps1 sync` copied it alongside the protected world configuration, then funded all 20 configured faction wallets from the synchronized admin account to the common 10 SUI target. Funding transaction `3b1SyuNkPmvK7ZDcrzrF6tZDbwPUTvheosYTuDcvW1p7` transferred 200 SUI in total; the admin already had sufficient SUI, so no faucet request was needed. A read-only repeat preview found zero under-budget wallets.

EveJS `npm run frontier:npc:verify` passed against this deployment. It simulated the real server transaction builder with checks enabled, verified Character, PlayerProfile and NpcProfile types, checked faction ownership and identity events, and confirmed that simulated objects remained absent. No permanent smoke-test NPC was created, and no Localnet or EveJS restart was performed.
