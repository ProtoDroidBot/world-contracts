# World Contracts

Sui Move smart contracts for EVE Frontier.

## Important Notice

This repository contains code intended for future use. While its not currently active in game or
production ready, it is being shared early for visibility, collaboration, review and reference.

The project is actively under development, and changes should be expected as work progresses.

For more context around this feel free to check out the [press release](https://www.ccpgames.com/news/2025/eve-frontier-to-launch-on-layer-1-blockchain-sui).

If you are looking for the current contracts used in game they can be found here: [projectawakening/world-chain-contracts](https://github.com/projectawakening/world-chain-contracts)

## Quick Start

### Prerequisites
- Docker (only for containerized deployment)
- OR Sui CLI + Node.js (for local development)

### Setup

1. **Create environment file and configure:**
   ```bash
   cp env.example .env
   ```

2. **Get your private key:**
   ```bash
   # If you have an existing Sui wallet:
   sui keytool export --address YOUR_ADDRESS
   
   # Or generate a new one:
   sui keytool generate ed25519
   
   # Copy the private key (without 0x prefix) to .env
   ```

## Docker Deployment

### Build Image
```bash
docker build -t world-contracts:latest --target release-stage -f docker/Dockerfile .
```

### Deploy & Configure
```bash
docker run --rm \
  -v "$(pwd)/.env:/app/.env:ro" \
  -v "$(pwd)/deployments:/app/deployments" \
  world-contracts:latest
```

On failure, check `deployments/<env>/deploy.log` for details.

## Localnet snapshot image

For a **pre-baked Sui localnet** Docker image (deployed contracts, Postgres-backed indexer, and object IDs for downstream integration tests), see **[`docker/README.md`](docker/README.md)**. It covers how to run the stack with [`docker/docker-compose-snapshot-image.yml`](docker/docker-compose-snapshot-image.yml) and where the image is published on GitHub Container Registry.

## Local Development

### Install Dependencies
```bash
pnpm install
```

### Build Contracts
```bash
pnpm build
```

### Run Tests
```bash
pnpm test
```

### Deploy Locally
```bash
# Uses SUI_NETWORK from .env (default: localnet)
pnpm deploy-world
```

`deploy-world` is a fresh-publish command. It cleans publication and deployment
outputs, publishes the base world plus five first-party feature packages, and
writes a combined feature manifest. It is not an upgrade command. See
[Package topology and deployment identity](docs/package-topology.md) before
operating on an existing deployment.

## Package topology

The current deployment contains:

- the base `world` package;
- `world_npc` (`npc`);
- `world_assembly_access` (`assembly_access`);
- `world_catapult` (`catapult`);
- `world_smart_industry` (`smart_industry`);
- `world_transponder` (`transponder`);
- `world_action_queue` (`action_queue`);
- `world_industry_actions` (`industry_actions`);
- `world_logistics_actions` (`logistics_actions`);
- `world_infrastructure_actions` (`infrastructure_actions`); and
- `world_automation` (`automation`).

Each feature has an independent call package, stable type origin, and shared
registry recorded in `deployments/<network>/world-features.v1.json`. The
manifest uses independent capability records and can represent partial
deployments. Optional faction policy uses a default file plus one explicitly
referenced file per canonical faction key. Historical `npc-deployment.json`
schemas remain migration inputs. Do not target a feature through
the base package unless the deployment manifest explicitly identifies that
package as the feature call target.

For EveJS client build 3502403, `env.example` configures Mini/Small Gate
(`88086`) and Slingshot/Smart Catapult (`95627`) to **65 light-years**, and
Heavy Gate (`84955`) and Heavy Slingshot/Smart Catapult (`95677`) to
**365 light-years**.
The `MAX_DISTANCES` entries are exact integer meters: `614947480717752000`
and `3453166622491992000`, using `9460730472580800` meters per light-year.
`scripts/configure-world.sh` applies these values from `.env` after deployment;
an existing `.env` must contain the same updated gate entries. Gate range remains
configurable through `gate::set_max_distance`.

`world_catapult::catapult` adds a deterministic one-way route sidecar to the existing
Slingshot `Gate` object. The route commits the source gate and solar system,
one destination solar system, exact distance, revision, and update time. It
does not require or create a destination Gate. Route creation and changes use
`AdminACL`, require the source gate offline and unpaired, and enforce the
configured type range; jump authorization requires the source gate online.
See [Smart Catapult routes](docs/catapult.md) for its object, authorization,
deployment, and test model.

EveJS `FrontierWorld.ps1` uses this build's `3502403/world-contracts` checkout
by default. The sibling `smart-assembly-control/world-contracts` checkout is a
separate reference copy. Run `node --test tests/gate-distance-config.test.mjs`
to check the defaults, including the extracted client component data when present.

## Smart Industry

`world_smart_industry::smart_industry` adds a shared, blockchain-readable snapshot to existing
Industry assemblies. The EveJS server syncs their current blueprint, recipe limits,
and input/output inventories through the existing assembly worker. See
[Smart Industry](docs/smart-industry.md) for the contract API, live sync setup,
authorization, and read/sync CLI. Run `pnpm test:industry` for its TypeScript
tests and `sui move test --path contracts/world_smart_industry` for Move tests.

## NPC profiles and assembly access

`world_npc::npc` provides persistent NPC profiles, faction-wallet binding, and
lifecycle synchronization without changing the base Character/Profile layouts.
`world_assembly_access::assembly_access` provides smart-assembly policies,
attenuated delegation, revocation, and cross-owner custody authorization. See
[NPC profiles](docs/npc-profiles.md) and
[Assembly access](docs/assembly-access.md).

## Private transponder commitments

`world_transponder::transponder` stores domain-separated BLAKE2b-256 commitments for private
tribe and NPC-faction transponder codes. Plaintext codes and random salts remain
off-chain. See [Transponder commitments](docs/transponder-commitments.md) for the
hash protocol, authorization model, rotation/revocation lifecycle, and deployment
identity rules.

## Documentation Automation

Whenever changes are **pushed to `main`**, the workflow at
[`.github/workflows/docs-update.yml`](.github/workflows/docs-update.yml)
automatically creates a **draft pull request** in
[`evefrontier/builder-documentation`](https://github.com/evefrontier/builder-documentation)
with a `@copilot` comment that instructs Copilot to update the relevant docs.

### How it works

1. The workflow triggers on `push` to `main`.
2. It resolves the merged PR associated with the push’s merge commit via
   `GET /repos/{owner}/{repo}/commits/{sha}/pulls` (skipping if none is found).
3. It fetches the list of changed files from the merged PR via the GitHub API.
4. It consults [`.github/docs-mapping.json`](.github/docs-mapping.json) to map
   changed source paths to documentation files in `builder-documentation`.
   - If no mapping matches, the fallback targets `smart-contracts/eve-frontier-world-explainer.md`.
5. A new branch (`docs/world-contracts-pr-<number>`) is created in
   `evefrontier/builder-documentation` with a scaffold placeholder commit.
6. A **draft PR** is opened in `builder-documentation` whose body contains:
   - A link to the merged `world-contracts` PR
   - A summary of changed files
   - Explicit `@copilot` instructions to update the identified docs
7. A follow-up PR comment is posted to ensure `@copilot` is notified.

### Required secret

Add the following secret to the `evefrontier/world-contracts` repository
(**Settings → Secrets and variables → Actions**):

| Secret name      | Description |
|------------------|-------------|
| `DOCS_REPO_PAT`  | A GitHub Personal Access Token (classic) **or** a fine-grained PAT with the following permissions on `evefrontier/builder-documentation`: `Contents: Read and write`, `Pull requests: Read and write`. |

> **Fine-grained PAT scopes** (recommended): resource owner = `evefrontier`,
> repository = `builder-documentation`, permissions = `Contents (read/write)` +
> `Pull requests (read/write)`.
>
> **Classic PAT scopes**: `repo` (full repository access).

### Customizing the path → docs mapping

Edit [`.github/docs-mapping.json`](.github/docs-mapping.json) to add or adjust
mappings. Each entry has:

```jsonc
{
  "paths": ["contracts/world/sources/assemblies/storage_unit"],  // path prefixes to match
  "docs":  ["smart-assemblies/storage-unit/README.md"],          // docs files to update
  "section": "Smart Assemblies - Storage Unit"                   // human-readable label
}
```

A `fallback` entry covers changes that don't match any specific path.
The current mapping has no feature-specific entries for the five split
`contracts/world_*` packages, so those changes use the fallback world overview.
Add explicit mappings when the downstream builder documentation gains dedicated
NPC, assembly-access, catapult, Industry, or transponder pages.

### Avoiding infinite loops

The workflow is scoped to `evefrontier/world-contracts` only and writes to a
different repository (`evefrontier/builder-documentation`). Changes in
`builder-documentation` do **not** trigger this workflow, so there is no
risk of an automation loop.
