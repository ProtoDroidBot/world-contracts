# World Contracts

Sui Move smart contracts for EVE Frontier.

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
   sui keytool export --key-identity YOUR_ADDRESS
   
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
pnpm install --frozen-lockfile
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

For the 3712181 EveJS stack, use `./FrontierWorld.ps1 up -Build 3712181` at the
EveJS repository root.
It publishes the 0607 SDK packages and the legacy game contracts on the same
localnet. See [package topology and deployment identity](docs/package-topology.md).

For standalone SDK development, start a local Sui node and fund your active
address. Publish the modular packages, then publish EVE currency if your tests
use it.

```bash
./scripts/deploy-world.sh localnet
./scripts/deploy-currency.sh localnet
```

### Progress on V1 
TODO 
- Docker files update 
- All README's
- Workflows 
   - integration test
   - publish to mvr 
   - publish sdks
   - deploy workflow 

