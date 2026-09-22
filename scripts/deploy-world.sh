#!/usr/bin/env bash
# Deploy world contracts.
# Usage: ./scripts/deploy-world.sh [localnet|testnet|mainnet|devnet]
source "$(dirname "$0")/lib.sh"

setup
ENV=$(get_env "${1:-}")
pnpm clean
rm -rf contracts/*/Pub.*.toml
mkdir -p "deployments/$ENV"
start_logging "$ENV" "deploy-world"

echo "--- pnpm i ---"
pnpm i

echo "--- sui client publish ---"
publish world "deployments/$ENV/world_package.json" "$ENV"

echo "--- publish feature packages ---"
SHARED_LOCALNET_PUBFILE="../world/Pub.localnet.toml"
publish world_npc "deployments/$ENV/world_npc_package.json" "$ENV" "$SHARED_LOCALNET_PUBFILE"
publish world_catapult "deployments/$ENV/world_catapult_package.json" "$ENV" "$SHARED_LOCALNET_PUBFILE"
publish world_smart_industry "deployments/$ENV/world_smart_industry_package.json" "$ENV" "$SHARED_LOCALNET_PUBFILE"
publish world_transponder "deployments/$ENV/world_transponder_package.json" "$ENV" "$SHARED_LOCALNET_PUBFILE"
publish world_assembly_access "deployments/$ENV/world_assembly_access_package.json" "$ENV" "$SHARED_LOCALNET_PUBFILE"
publish world_action_queue "deployments/$ENV/world_action_queue_package.json" "$ENV" "$SHARED_LOCALNET_PUBFILE"
publish world_industry_actions "deployments/$ENV/world_industry_actions_package.json" "$ENV" "$SHARED_LOCALNET_PUBFILE"
publish world_logistics_actions "deployments/$ENV/world_logistics_actions_package.json" "$ENV" "$SHARED_LOCALNET_PUBFILE"
publish world_infrastructure_actions "deployments/$ENV/world_infrastructure_actions_package.json" "$ENV" "$SHARED_LOCALNET_PUBFILE"
publish world_automation "deployments/$ENV/world_automation_package.json" "$ENV" "$SHARED_LOCALNET_PUBFILE"

echo "--- extract-object-ids ---"
export SUI_NETWORK="$ENV"
pnpm exec tsx ts-scripts/utils/extract-object-ids.ts

echo "--- write-world-features ---"
pnpm exec tsx ts-scripts/utils/write-world-features.ts

echo "Deployed world to $ENV. Output: deployments/$ENV/"
echo "Log: deployments/$ENV/deploy.log"
