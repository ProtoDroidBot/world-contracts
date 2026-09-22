# NPC profiles

`world_npc::npc` adds explicit on-chain NPC identity and lifecycle state to the existing Character model. Each NPC retains a shared `character::Character` and wallet-owned `character::PlayerProfile` for compatibility, and receives a separate shared `npc::NpcProfile`. Existing Character and PlayerProfile struct layouts remain unchanged.

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

A fresh deployment publishes `npc` from `contracts/world_npc`, not from the base world package. Its new feature-package ID is both the call target and type origin, and its initializer creates the shared `NpcRegistry`. For an upgrade, keep the original base-world configuration and objects, preserve the first NPC type origin and registry, and change only the NPC call package to the latest compatible implementation.

The EveJS server reads `EVEJS_SUI_NPC_PACKAGE_ID`, `EVEJS_SUI_NPC_TYPE_ORIGIN`, and `EVEJS_SUI_NPC_REGISTRY_ID`, or the NPC fields in the combined public `npc-deployment.json` beside its synchronized `world.private.json`. `EVEJS_SUI_NPC_CONFIG_PATH` selects an explicit manifest. Environment overrides take precedence per field but cannot mask malformed or mismatched manifest data. The server revalidates the deployment fingerprint before submitting a signed operation.

The current version-3 manifest is an atomic ten-feature manifest despite its historical filename. Current synchronization requires the complete NPC, assembly-access, catapult, Smart Industry, transponder, queue, Industry Actions, Logistics Actions, Infrastructure Actions, and Automation package/origin/registry triples. Version 1 and 2 remain migration inputs. The complete schema and upgrade invariants are documented in [Package topology and deployment identity](package-topology.md). In particular, assembly access and the canonical action queue have independent package, type-origin, and registry identities; they must never be inferred from the NPC package in a split deployment.

Keep the authoritative manifest in `deployments/localnet/npc-deployment.json`. EveJS `FrontierWorld.ps1 sync` validates and copies its public runtime fields beside `world.private.json`, retaining the original world identity. Synchronization requires canonical full-length nonzero addresses and rejects malformed or mismatched manifests. If the source is absent but a destination manifest exists, sync fails closed and preserves that file for explicit reconciliation; it will not silently delete feature metadata. `sync -DryRun` performs validation without changing files. Synchronization itself does not publish or upgrade contracts.

The existing `scripts/deploy-world.sh` performs a fresh publish and cleans deployment outputs. It is not an upgrade procedure and must not be used to silently replace an existing world. Base-world synchronization also hashes its original deployment/publication artifacts: preserve those and store upgrade publication metadata separately. Existing synchronization assumes its base package identifies the original Character, TenantItemId, ObjectRegistry, and AdminACL types.

Before an upgrade, verify ownership and the policy of the existing UpgradeCap. These changes preserve old struct layouts and public signatures, but change some Character function bodies; an immutable or additive-only upgrade policy may disallow them. Quiesce the NPC worker and reconcile outstanding journals against the original configuration before switching its NPC package settings. A pending signed transaction is bound to its original chain/package fingerprint: the worker retains it and refuses to silently replay or discard it after a configuration change.

Source edits and these settings do not deploy anything. A deployment without this module must fail NPC provisioning, rather than treating a plain Character/PlayerProfile pair as a confirmed NPC. The server's NPC worker may register an existing compatible reserved-ID Character after the custom module is deployed; it does not publish, upgrade, or reset the chain itself.

## Verification

From this world-contracts checkout, `sui move test --path contracts/world_npc` builds and runs the NPC Move tests without submitting a live transaction. The test coverage includes faction-wallet consistency, reserved character IDs, profile registration, lifecycle revisions/death/respawn, and retirement. Run it with the Sui CLI supplied by the efctl build environment so the CLI and pinned framework agree.

In `EveJS-Frontier`, run `npm run build` followed by `npm run test:frontier-npc-identities` to check the server integration using an isolated game store and mocked chain clients. The deployment-config tests cover type-origin separation, base-world mismatches, malformed configuration, and changes between transaction preparation and submission. Actual publication or upgrade is an explicit deployment operation outside these tests.

### Current Localnet audit on 2026-09-20

The active chain is a fresh split deployment. Public RPC inspection confirmed that the configured NPC call package exists, exposes only the normalized `npc` module, and has a shared `NpcRegistry` whose exact type uses the configured NPC type origin. The NPC `UpgradeCap` also exists under the deployment admin. The authoritative and EveJS-synchronized combined manifests agree.

Focused EveJS world-sync and feature-configuration tests passed as part of the same audit. The protected-key read-only NPC transaction simulator was not rerun from the audit sandbox because its identity could not read `world.private.json`; the ACL was not weakened. The sibling TypeScript/Move suites must be rerun inside the rebuilt efctl environment before treating the current split source as release evidence. Older 2026-09-19 monolithic-package test counts and package IDs are historical and do not validate this split deployment.
