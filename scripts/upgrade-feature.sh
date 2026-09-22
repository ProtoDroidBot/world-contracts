#!/usr/bin/env bash
# Upgrade one split feature without cleaning deployments or replacing type origins.
# Execution is deliberately opt-in: ./scripts/upgrade-feature.sh smart_industry localnet --execute
source "$(dirname "$0")/lib.sh"

setup
FEATURE="${1:-}"
ENV=$(get_env "${2:-localnet}")
MODE="${3:---dry-run}"
case "$FEATURE" in smart_industry|npc|assembly_access) ;; *)
    echo "Usage: $0 smart_industry|npc|assembly_access [network] [--dry-run|--execute]" >&2
    exit 1
esac
[[ "$MODE" == "--dry-run" || "$MODE" == "--execute" ]] || {
    echo "Upgrade mode must be --dry-run or --execute" >&2; exit 1;
}

ROOT=$(git rev-parse --show-toplevel)
[[ "$ROOT" == "$REPO_ROOT" ]] || {
    echo "Refusing ambiguous world-contracts root: expected $REPO_ROOT, git reports $ROOT" >&2; exit 1;
}
TSX="$REPO_ROOT/node_modules/.bin/tsx"
[[ -x "$TSX" ]] || {
    echo "Missing local tsx runtime. Install the locked world-contracts dependencies first." >&2; exit 1;
}
# Call the locked binary directly: pnpm may print install/progress text to
# stdout, which must never contaminate JSON captured by this script.
PREFLIGHT=$("$TSX" ts-scripts/utils/update-feature-deployment.ts preflight "$FEATURE" "$ENV")
PACKAGE_DIR=$(node -e 'const v=JSON.parse(process.argv[1]); process.stdout.write(v.packageDir)' "$PREFLIGHT")
UPGRADE_CAP=$(node -e 'const v=JSON.parse(process.argv[1]); process.stdout.write(v.upgradeCapId)' "$PREFLIGHT")
echo "Feature: $FEATURE"
echo "Repository: $REPO_ROOT"
echo "Package: $PACKAGE_DIR"
echo "Network: $ENV"
echo "UpgradeCap: $UPGRADE_CAP"

sui client switch --env "$ENV"
BUILD_ENV_ARGS=()
if [[ "$ENV" == "localnet" ]]; then
    # The efctl Localnet resolves the framework/dependency addresses through
    # the testnet build profile, matching the existing test-publish workflow.
    BUILD_ENV_ARGS=(--build-env testnet)
fi
sui move build "${BUILD_ENV_ARGS[@]}" --path "$PACKAGE_DIR"
if [[ "$MODE" != "--execute" ]]; then
    echo "Dry run complete. No chain or deployment files were changed."
    exit 0
fi

mkdir -p "deployments/$ENV/upgrades"
OUTPUT="deployments/$ENV/upgrades/${FEATURE}-$(date +%Y%m%d-%H%M%S).json"
TMP=$(mktemp)
trap 'rm -f -- "$TMP"' EXIT
(cd "$PACKAGE_DIR" && sui client upgrade "${BUILD_ENV_ARGS[@]}" \
    --upgrade-capability "$UPGRADE_CAP" --json) > "$TMP"
"$TSX" ts-scripts/utils/extract-json.ts "$TMP" > "$OUTPUT"
[[ -s "$OUTPUT" ]] || { echo "Upgrade produced no verified JSON output" >&2; exit 1; }
"$TSX" ts-scripts/utils/update-feature-deployment.ts commit "$FEATURE" "$ENV" "$OUTPUT"
echo "Upgraded $FEATURE. Output: $OUTPUT"
