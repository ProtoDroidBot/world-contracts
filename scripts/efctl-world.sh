#!/usr/bin/env bash
# efctl's localnet lifecycle uses the legacy game ABI and the 0607 SDK packages.
source "$(dirname "$0")/lib.sh"

setup
ACTION="${1:?Usage: efctl-world.sh [deploy|configure|seed] [localnet]}"
shift
ENV=$(get_env "${1:-}")
if [[ "$ENV" != "localnet" ]]; then
    echo "The efctl integration deploys to localnet. Use scripts/deploy-world.sh for a named environment." >&2
    exit 1
fi
DEPLOY_DIR="deployments/$ENV"
export SUI_NETWORK="$ENV"

legacy_packages=(
    world world_npc world_catapult world_smart_industry world_transponder world_assembly_access
    world_action_queue world_industry_actions world_logistics_actions world_infrastructure_actions
    world_automation
)

case "$ACTION" in
    deploy)
        # On a fresh node, invalidate the previous exports before publishing.
        # Keep named environments and other world-contracts outputs intact.
        legacy_pubfile="$REPO_ROOT/contracts/world/Pub.$ENV.toml"
        ensure_deploy_dir "$ENV"
        rm -f "$legacy_pubfile" "$DEPLOY_DIR/extracted-object-ids.json" "$DEPLOY_DIR/world-features.v1.json" \
            "$DEPLOY_DIR/builder_package.json" "$DEPLOY_DIR/world.json"

        export SUI_PRIVATE_KEY="${SUI_PRIVATE_KEY:-${ADMIN_PRIVATE_KEY:-}}"
        bash "$SCRIPT_DIR/deploy-world.sh" "$ENV"

        start_logging "$ENV" "deploy legacy game world"
        for pkg in "${legacy_packages[@]}"; do
            publish "$pkg" "$ENV" "$legacy_pubfile" "$DEPLOY_DIR/${pkg}_package.json"
        done
        pnpm exec tsx ts-scripts/utils/extract-object-ids.ts
        pnpm exec tsx ts-scripts/utils/write-world-features.ts
        ;;
    configure)
        start_logging "$ENV" "configure legacy game world"
        pnpm exec tsx ts-scripts/access/setup-access.ts
        pnpm exec tsx ts-scripts/network-node/configure-fuel-energy.ts
        pnpm exec tsx ts-scripts/gate/configure-distance.ts
        ;;
    seed)
        start_logging "$ENV" "seed legacy game world"
        delay_seconds="${DELAY_SECONDS:-5}"
        commands=(
            character/create-character
            network-node/create-nwn
            network-node/deposit-fuel
            network-node/online-nwn
            storage-unit/create-storage-unit
            storage-unit/online
            storage-unit/game-item-to-chain
            storage-unit/deposit-to-ephemeral-inventory
            gate/create-gates
            gate/link-gates
            gate/online
        )
        for index in "${!commands[@]}"; do
            command="${commands[$index]}"
            echo "==> Step $((index + 1))/${#commands[@]}: $command"
            pnpm exec tsx "ts-scripts/$command.ts"
            if [[ "$index" -lt $((${#commands[@]} - 1)) ]]; then
                sleep "$delay_seconds"
            fi
        done
        ;;
    *)
        echo "Usage: $0 [deploy|configure|seed] [localnet]" >&2
        exit 1
        ;;
esac
