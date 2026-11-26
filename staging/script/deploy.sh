#!/usr/bin/env bash
# Deploys the staging contracts on Base. See staging/README.md.
#
#   staging/script/deploy.sh system             rehearse a system redeploy on a local fork of Base
#   staging/script/deploy.sh system --live      redeploy the system on Base and update deployments/staging.json
#   staging/script/deploy.sh fixtures [--live]  same for the fixtures (test tokens, mocks, test vaults, faucet, pools)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
STAGING="$ROOT/staging"
CONFIG="$ROOT/deployments/staging.json"
CHAIN_ID=8453
ZERO=0x0000000000000000000000000000000000000000

die() { echo "error: $*" >&2; exit 1; }
log() { echo "==> $*" >&2; }
lower() { tr '[:upper:]' '[:lower:]' <<<"$1"; }
cfg() { jq -er "$1" "$CONFIG"; }

TARGET="${1:-}"
MODE="fork"
[[ "$TARGET" == system || "$TARGET" == fixtures ]] || die "usage: $0 <system|fixtures> [--live]"
if [[ $# -eq 2 && "$2" == --live ]]; then MODE="live"; elif [[ $# -ne 1 ]]; then die "usage: $0 <system|fixtures> [--live]"; fi

for bin in forge cast anvil jq git; do command -v "$bin" >/dev/null || die "$bin is not installed"; done
[[ -d "$ROOT/packages/xmetro/lib/openzeppelin-contracts" && -d "$ROOT/packages/commission/lib/openzeppelin-contracts" ]] \
  || die "install the package dependencies first (see staging/README.md)"

set -a
# shellcheck source=../staging.env
source "$STAGING/staging.env"
set +a
unset DEPLOYER_PRIVATE_KEY
BASE_RPC_URL="${BASE_RPC_URL:-https://mainnet.base.org}"
OWNER="$(cfg .owner)"

WORK="$(mktemp -d)"
ANVIL_PID=""
cleanup() {
  if [[ -n "$ANVIL_PID" ]]; then kill "$ANVIL_PID" 2>/dev/null || true; fi
  rm -rf "$WORK"
}
trap cleanup EXIT

if [[ "$MODE" == live ]]; then
  command -v op >/dev/null || die "1Password CLI (op) is required for --live"
  git -C "$ROOT" diff --quiet HEAD -- packages staging || die "commit or stash changes under packages/ and staging/ first"
  RPC_URL="$BASE_RPC_URL"
  (umask 077 && op read "$STAGING_SIGNER_OP_REF" >"$WORK/seed")
  [[ "$(lower "$(cast wallet address --mnemonic "$WORK/seed" --mnemonic-index 0)")" == "$(lower "$OWNER")" ]] \
    || die "the 1Password seed does not derive the staging owner $OWNER"
  SCRIPT_SIGNER=(--mnemonics "$WORK/seed" --mnemonic-indexes 0 --sender "$OWNER")
  TX_SIGNER=(--mnemonic "$WORK/seed" --mnemonic-index 0)
  read -r -p "Deploy a new staging $TARGET to Base as $OWNER? Type 'deploy' to continue: " answer
  [[ "$answer" == deploy ]] || die "aborted"
else
  PORT="${STAGING_FORK_PORT:-8547}"
  log "starting a local fork of Base on port $PORT"
  anvil --fork-url "$BASE_RPC_URL" --port "$PORT" --auto-impersonate --silent &
  ANVIL_PID=$!
  for _ in $(seq 1 60); do cast chain-id --rpc-url "http://127.0.0.1:$PORT" >/dev/null 2>&1 && break; sleep 1; done
  RPC_URL="http://127.0.0.1:$PORT"
  cast rpc anvil_setBalance "$OWNER" 0x56BC75E2D63100000 --rpc-url "$RPC_URL" >/dev/null
  SCRIPT_SIGNER=(--unlocked --sender "$OWNER")
  TX_SIGNER=(--unlocked --from "$OWNER")
fi
[[ "$(cast chain-id --rpc-url "$RPC_URL")" == "$CHAIN_ID" ]] || die "RPC is not Base"

TX_LOG="$WORK/transactions.log"
FORGE_LOG="$WORK/forge.log"
fail_log() { tail -n 60 "$FORGE_LOG" >&2; die "$1 failed; full forge output above"; }
: >"$TX_LOG"
send() {
  local out hash
  out="$(cast send --rpc-url "$RPC_URL" "${TX_SIGNER[@]}" --json "$@" 2>&1)" || die "transaction failed: $*: $out"
  hash="$(jq -er 'select(.status == "0x1") | .transactionHash' <<<"$out")" || die "transaction reverted: $*: $out"
  echo "$hash $*" >>"$TX_LOG"
  echo "$hash"
}
call() { cast call --rpc-url "$RPC_URL" "$@" | awk '{print $1}'; }
expect() { [[ "$(lower "$2")" == "$(lower "$3")" ]] || die "check failed: $1 is $2, expected $3"; }
latest_timestamp() { cast block latest --field timestamp --rpc-url "$RPC_URL"; }
tx_block() { cast receipt "$1" blockNumber --rpc-url "$RPC_URL"; }
broadcast_block() {
  local hex
  hex="$(jq -er --arg a "$(lower "$2")" 'first(.receipts[] | select((.contractAddress // "" | ascii_downcase) == $a) | .blockNumber)' "$1")"
  echo $((hex))
}

mask_immutables() {
  local code="${1#0x}" artifact="$2" start length
  while read -r start length; do
    code="${code:0:$((start * 2))}$(printf '%0*d' $((length * 2)) 0)${code:$(((start + length) * 2))}"
  done < <(jq -r '.deployedBytecode.immutableReferences // {} | .[][] | "\(.start) \(.length)"' "$artifact")
  echo "0x$code"
}

save_run() {
  local dir
  dir="$STAGING/runs/$(date -u +%Y-%m-%dT%H%M%SZ)-$TARGET-$(git -C "$ROOT" rev-parse --short HEAD)"
  mkdir -p "$dir"
  cp "$TX_LOG" "$dir/"
  for f in "$@"; do cp "$f" "$dir/$(basename "$(dirname "$(dirname "$(dirname "$f")")")")-$(basename "$f")"; done
  log "run record saved to ${dir#"$ROOT/"}"
}

publish() {
  local section="$1" value="$2"
  shift 2
  if [[ "$MODE" == fork ]]; then
    mkdir -p "$STAGING/output"
    jq . <<<"$value" >"$STAGING/output/$section-rehearsal.json"
    log "rehearsal passed; result in staging/output/$section-rehearsal.json (deployments/staging.json unchanged)"
    return
  fi
  local label
  label="$section-$(date -u +%Y-%m-%d)"
  jq --arg section "$section" --arg label "$label" --argjson value "$value" '
    .retired[$label] = (.[$section] as $old
      | [$old | paths(type == "object" and has("address"))]
      | reduce .[] as $p ({}; . + {($p | map(tostring) | join(".")): ($old | getpath($p).address)})
      | . + {sourceCommit: ($old.sourceCommit // null)})
    | .[$section] = $value' "$CONFIG" >"$WORK/staging.json"
  mv "$WORK/staging.json" "$CONFIG"
  save_run "$@"
  log "deployments/staging.json updated; the previous $section is under retired.$label"
}

deploy_fixtures() {
  log "staging/script/DeployFixtures.s.sol"
  (cd "$STAGING" && STAGING_OWNER="$OWNER" UNISWAP_V2_ROUTER="$(cfg .external.uniswapV2Router)" \
    forge script script/DeployFixtures.s.sol:DeployFixtures --rpc-url "$RPC_URL" --broadcast --slow "${SCRIPT_SIGNER[@]}") \
    >>"$FORGE_LOG" 2>&1 || fail_log DeployFixtures
  local out="$STAGING/output/fixtures.json" run="$STAGING/broadcast/DeployFixtures.s.sol/$CHAIN_ID/run-latest.json"
  local fixtures
  fixtures="$(jq --slurpfile run "$run" '
    def hex: ltrimstr("0x") | ascii_downcase | explode | reduce .[] as $c (0; . * 16 + (if $c >= 97 then $c - 87 else $c - 48 end));
    def at($a): {address: $a}
      + (first($run[0].receipts[] | select((.contractAddress // "" | ascii_downcase) == ($a | ascii_downcase)) | {deployBlock: (.blockNumber | hex)}) // {});
    {
      tokens: {TestUSDC: at(.TestUSDC), TestTHOR: at(.TestTHOR), TestYTHOR: at(.TestYTHOR), TestUSDT: at(.TestUSDT),
               TestWBTC: at(.TestWBTC), TestGHO: at(.TestGHO), TestXAUT: at(.TestXAUT), TestExtraToken: at(.TestExtraToken),
               TestSyrupUSDC: at(.TestSyrupUSDC)},
      thorVaults: {uTHOR: at(.uTHOR), vTHOR: at(.vTHOR)},
      TestTokenFaucet: (at(.TestTokenFaucet) + {spreadBps: 2000, cooldownSeconds: 300}),
      protocolMocks: {MockAaveV3Pool: at(.MockAaveV3Pool), MockScaledAToken: {address: .MockScaledAToken},
                      MockAaveV4Spoke: at(.MockAaveV4Spoke), MockAaveV4Giver: at(.MockAaveV4Giver),
                      MockSyrupRouter: at(.MockSyrupRouter), MockPoolPermissionManager: at(.MockPoolPermissionManager)},
      protocolConfig: {aaveV3ReferralCode: 17, aaveV4UsdcReserveId: 7,
                       mapleDepositData: "0x303a784d4554524f000000000000000000000000000000000000000000000000"},
      pools: (to_entries | map(select(.key | endswith("/USDC"))) | map({key, value: {address: .value}}) | from_entries)
    }' "$out")"
  publish fixtures "$fixtures" "$run"
}

build_trees() {
  log "copying packages and applying staging/timers.patch"
  mkdir -p "$WORK/xmetro" "$WORK/commission"
  for p in src script foundry.toml remappings.txt foundry.lock; do cp -R "$ROOT/packages/xmetro/$p" "$WORK/xmetro/"; done
  ln -s "$ROOT/packages/xmetro/lib" "$WORK/xmetro/lib"
  (cd "$WORK/xmetro" && git apply "$STAGING/timers.patch")
  for p in contracts script foundry.toml remappings.txt foundry.lock; do cp -R "$ROOT/packages/commission/$p" "$WORK/commission/"; done
  ln -s "$ROOT/packages/commission/lib" "$WORK/commission/lib"
  log "building the adapter artifact"
  (cd "$WORK/xmetro" && FOUNDRY_PROFILE=adapter forge build --skip test) >>"$FORGE_LOG" 2>&1 || fail_log "adapter build"
}

deploy_system() {
  build_trees
  local usdc thor ythor router_v2 start
  usdc="$(cfg .fixtures.tokens.TestUSDC.address)"
  thor="$(cfg .fixtures.tokens.TestTHOR.address)"
  ythor="$(cfg .fixtures.tokens.TestYTHOR.address)"
  router_v2="$(cfg .external.uniswapV2Router)"
  start=$(($(latest_timestamp) + MIGRATION_START_DELAY_SECONDS))

  EXPECTED_CHAIN_ID="$CHAIN_ID"
  DEPLOYER_ADDRESS="$OWNER"
  USDC="$usdc"
  THOR="$thor"
  YTHOR="$ythor"
  ROUTER_V2="$router_v2"
  ROUTER_V3="$(cfg .external.uniswapV3SwapRouter02)"
  ONEINCH_ROUTER="$(cfg .external.oneInchRouter)"
  REWARD_TOKEN_OUT_USDT="$(cfg .fixtures.tokens.TestUSDT.address)"
  REWARD_TOKEN_OUT_WBTC="$(cfg .fixtures.tokens.TestWBTC.address)"
  REWARD_TOKEN_OUT_GHO="$(cfg .fixtures.tokens.TestGHO.address)"
  REWARD_TOKEN_OUT_XAUT="$(cfg .fixtures.tokens.TestXAUT.address)"
  REWARD_TOKEN_OUT_SYRUP_USDC="$(cfg .fixtures.tokens.TestSyrupUSDC.address)"
  AAVE_V3_ENABLED=true
  AAVE_V3_POOL="$(cfg .fixtures.protocolMocks.MockAaveV3Pool.address)"
  AAVE_V3_AUSDC="$(cfg .fixtures.protocolMocks.MockScaledAToken.address)"
  AAVE_V3_REFERRAL_CODE="$(cfg .fixtures.protocolConfig.aaveV3ReferralCode)"
  AAVE_V4_ENABLED=true
  AAVE_V4_SPOKE="$(cfg .fixtures.protocolMocks.MockAaveV4Spoke.address)"
  AAVE_V4_GIVER="$(cfg .fixtures.protocolMocks.MockAaveV4Giver.address)"
  AAVE_V4_USDC_RESERVE_ID="$(cfg .fixtures.protocolConfig.aaveV4UsdcReserveId)"
  MAPLE_ENABLED=true
  MAPLE_SYRUP_ROUTER="$(cfg .fixtures.protocolMocks.MockSyrupRouter.address)"
  MAPLE_SYRUP_USDC="$(cfg .fixtures.tokens.TestSyrupUSDC.address)"
  MAPLE_DEPOSIT_DATA="$(cfg .fixtures.protocolConfig.mapleDepositData)"
  REWARD_DISTRIBUTOR_OPERATOR="$STAGING_OPERATOR"
  AUTO_COMPOUND_OPERATOR="$STAGING_OPERATOR"
  COMMISSION_VAULT="$ZERO"
  MAX_COMMISSION_SPLIT_BPS=0
  MIGRATION_START_TIME="$start"
  DEADLINE_THOR=$((start + MIGRATION_WINDOW_SECONDS))
  DEADLINE_YTHOR=$((start + MIGRATION_WINDOW_SECONDS))
  ADAPTER_ARTIFACT="out-adapter/XMetroDeFiAdapter.sol/XMetroDeFiAdapter.json"
  EXPECTED_ADAPTER_INITCODE_HASH="$(cast keccak "$(jq -r .bytecode.object "$WORK/xmetro/$ADAPTER_ARTIFACT")")"
  export EXPECTED_CHAIN_ID OWNER DEPLOYER_ADDRESS USDC THOR YTHOR ROUTER_V2 ROUTER_V3 ONEINCH_ROUTER \
    REWARD_TOKEN_OUT_USDT REWARD_TOKEN_OUT_WBTC REWARD_TOKEN_OUT_GHO REWARD_TOKEN_OUT_XAUT \
    REWARD_TOKEN_OUT_SYRUP_USDC AAVE_V3_ENABLED AAVE_V3_POOL AAVE_V3_AUSDC AAVE_V3_REFERRAL_CODE AAVE_V4_ENABLED \
    AAVE_V4_SPOKE AAVE_V4_GIVER AAVE_V4_USDC_RESERVE_ID MAPLE_ENABLED MAPLE_SYRUP_ROUTER MAPLE_SYRUP_USDC \
    MAPLE_DEPOSIT_DATA REWARD_DISTRIBUTOR_OPERATOR AUTO_COMPOUND_OPERATOR COMMISSION_VAULT \
    MAX_COMMISSION_SPLIT_BPS MIGRATION_START_TIME DEADLINE_THOR DEADLINE_YTHOR ADAPTER_ARTIFACT \
    EXPECTED_ADAPTER_INITCODE_HASH

  log "packages/xmetro script/Deploy.s.sol"
  (cd "$WORK/xmetro" && FOUNDRY_PROFILE=deploy forge script script/Deploy.s.sol:Deploy \
    --rpc-url "$RPC_URL" --broadcast --slow "${SCRIPT_SIGNER[@]}") \
    >>"$FORGE_LOG" 2>&1 || fail_log "xmetro Deploy.s.sol"
  local out="$WORK/xmetro/deployments/$CHAIN_ID/addresses.json"
  local metro xmetro impl proxy reward_distributor escrow
  metro="$(jq -er .metro "$out")"
  xmetro="$(jq -er .xMETRO "$out")"
  impl="$(jq -er .deFiAdapterImplementation "$out")"
  proxy="$(jq -er .deFiAdapterProxy "$out")"
  reward_distributor="$(jq -er .rewardDistributor "$out")"
  escrow="$(jq -er .escrow "$out")"

  log "packages/commission script/Deploy.s.sol"
  (cd "$WORK/commission" && USDC_ADDRESS="$usdc" DISTRIBUTOR_ADDRESS="$reward_distributor" OPERATOR_ADDRESS="$STAGING_OPERATOR" \
    GUARDIAN_ADDRESS="$COMMISSION_GUARDIAN" IS_MIGRATION_TARGET=false \
    forge script script/Deploy.s.sol:Deploy --rpc-url "$RPC_URL" --broadcast --slow "${SCRIPT_SIGNER[@]}") \
    >>"$FORGE_LOG" 2>&1 || fail_log "commission Deploy.s.sol"
  local vault_run="$WORK/commission/broadcast/Deploy.s.sol/$CHAIN_ID/run-latest.json" vault
  vault="$(jq -er 'first(.receipts[] | select(.contractAddress != null) | .contractAddress)' "$vault_run")"

  log "packages/xmetro script/DeployMetroDistributor.s.sol"
  (cd "$WORK/xmetro" && DISTRIBUTOR_VERSION=1 DISTRIBUTOR_OWNER="$OWNER" DISTRIBUTOR_XMETRO="$xmetro" \
    DISTRIBUTOR_COMMISSION_VAULT="$vault" DISTRIBUTOR_FORWARDER="$ZERO" DISTRIBUTOR_OPERATORS="$STAGING_OPERATOR" \
    FOUNDRY_PROFILE=deploy forge script script/DeployMetroDistributor.s.sol:DeployMetroDistributor \
    --rpc-url "$RPC_URL" --broadcast --slow "${SCRIPT_SIGNER[@]}") \
    >>"$FORGE_LOG" 2>&1 || fail_log DeployMetroDistributor.s.sol
  local distributor_run="$WORK/xmetro/broadcast/DeployMetroDistributor.s.sol/$CHAIN_ID/run-latest.json" distributor
  distributor="$(jq -er .distributor "$WORK/xmetro/deployments/$CHAIN_ID/metro-distributor-v1.json")"

  log "RateLimitedForwarder, owned by the staging owner (the production script requires a Safe owner)"
  local initcode args forwarder forwarder_tx
  initcode="$(jq -er .bytecode.object "$WORK/commission/out/RateLimitedForwarder.sol/RateLimitedForwarder.json")"
  args="$(cast abi-encode "constructor(address,address,address,uint256,uint256,uint256)" \
    "$usdc" "$distributor" "$OWNER" "$FORWARDER_DRIP_RATE" "$FORWARDER_DRIP_PERIOD" "$FORWARDER_MAX_RESERVE")"
  forwarder_tx="$(send --create "$initcode${args#0x}")"
  forwarder="$(cast receipt "$forwarder_tx" contractAddress --rpc-url "$RPC_URL")"
  expect "RateLimitedForwarder.owner" "$(call "$forwarder" "owner()(address)")" "$OWNER"
  expect "RateLimitedForwarder.paused" "$(call "$forwarder" "paused()(bool)")" true

  log "owner batch from DeployMetroDistributor"
  send "$vault" "setDistributor(address)" "$distributor" >/dev/null
  send "$distributor" "setCommissionVault(address)" "$vault" >/dev/null
  if [[ "$DISTRIBUTOR_MAX_COMMISSION_SPLIT_BPS" != 0 ]]; then
    send "$distributor" "setMaxCommissionSplitBps(uint16)" "$DISTRIBUTOR_MAX_COMMISSION_SPLIT_BPS" >/dev/null
  fi
  send "$distributor" "setForwarder(address)" "$forwarder" >/dev/null
  send "$xmetro" "setRewardDistributor(address)" "$distributor" >/dev/null
  send "$forwarder" "unpause()" >/dev/null

  log "staging extras: Maple mock permission for the new adapter, METRO/USDC pool, forwarder funding"
  send "$(cfg .fixtures.protocolMocks.MockPoolPermissionManager.address)" "setLenderBitmap(address,uint256)" "$proxy" 16 >/dev/null
  send "$metro" "setMinter(address,bool)" "$OWNER" true >/dev/null
  send "$metro" "mint(address,uint256)" "$OWNER" "$METRO_POOL_METRO" >/dev/null
  send "$metro" "setMinter(address,bool)" "$OWNER" false >/dev/null
  send "$usdc" "mint(address,uint256)" "$OWNER" "$METRO_POOL_USDC" >/dev/null
  send "$metro" "approve(address,uint256)" "$router_v2" "$METRO_POOL_METRO" >/dev/null
  send "$usdc" "approve(address,uint256)" "$router_v2" "$METRO_POOL_USDC" >/dev/null
  local pool_tx pair
  pool_tx="$(send "$router_v2" "addLiquidity(address,address,uint256,uint256,uint256,uint256,address,uint256)" \
    "$usdc" "$metro" "$METRO_POOL_USDC" "$METRO_POOL_METRO" "$METRO_POOL_USDC" "$METRO_POOL_METRO" "$OWNER" $(($(latest_timestamp) + 3600)))"
  pair="$(call "$(cfg .external.uniswapV2Factory)" "getPair(address,address)(address)" "$usdc" "$metro")"
  send "$usdc" "mint(address,uint256)" "$forwarder" "$FORWARDER_FUNDING" >/dev/null

  log "verifying bindings and the short-timer bytecode"
  expect "xMETRO.rewardDistributor" "$(call "$xmetro" "rewardDistributor()(address)")" "$distributor"
  expect "xMETRO.migrationEscrow" "$(call "$xmetro" "migrationEscrow()(address)")" "$escrow"
  expect "xMETRO.deFiAdapter" "$(call "$xmetro" "deFiAdapter()(address)")" "$proxy"
  expect "CommissionVault.distributor" "$(call "$vault" "distributor()(address)")" "$distributor"
  expect "MetroDistributorV1.commissionVault" "$(call "$distributor" "commissionVault()(address)")" "$vault"
  expect "MetroDistributorV1.forwarder" "$(call "$distributor" "forwarder()(address)")" "$forwarder"
  expect "RateLimitedForwarder.recipient" "$(call "$forwarder" "recipient()(address)")" "$distributor"
  expect "RateLimitedForwarder.paused after unpause" "$(call "$forwarder" "paused()(bool)")" false
  expect "METRO.isMinter(owner)" "$(call "$metro" "isMinter(address)(bool)" "$OWNER")" false
  local artifact="$WORK/xmetro/out-deploy/xMETRO.sol/xMETRO.json"
  expect "xMETRO runtime code" "$(mask_immutables "$(cast code "$xmetro" --rpc-url "$RPC_URL")" "$artifact")" \
    "$(mask_immutables "$(jq -r .deployedBytecode.object "$artifact")" "$artifact")"

  local timers system deploy_run="$WORK/xmetro/broadcast/Deploy.s.sol/$CHAIN_ID/run-latest.json"
  timers="$(jq -n \
    --argjson unstakeDelay "$(call "$xmetro" "UNSTAKE_DELAY()(uint64)")" \
    --argjson yThorExitRamp "$(call "$xmetro" "YTHOR_EXIT_RAMP()(uint64)")" \
    --argjson contributorCliff "$(call "$xmetro" "CONTRIBUTOR_CLIFF()(uint64)")" \
    --argjson contributorDuration "$(call "$xmetro" "CONTRIBUTOR_DURATION()(uint64)")" \
    '{unstakeDelay: $unstakeDelay, thorExitDelay: 3600, thorExitFullTime: 10800, yThorExitDelay: 14400,
      yThorExitRamp: $yThorExitRamp, contributorCliff: $contributorCliff, contributorDuration: $contributorDuration}')"
  system="$(jq -n \
    --arg commit "$(git -C "$ROOT" rev-parse --short HEAD)" --argjson timers "$timers" \
    --arg metro "$metro" --argjson metroBlock "$(broadcast_block "$deploy_run" "$metro")" \
    --arg xmetro "$xmetro" --argjson xmetroBlock "$(broadcast_block "$deploy_run" "$xmetro")" \
    --arg escrow "$escrow" --argjson escrowBlock "$(broadcast_block "$deploy_run" "$escrow")" \
    --arg proxy "$proxy" --argjson proxyBlock "$(broadcast_block "$deploy_run" "$proxy")" \
    --arg impl "$impl" --argjson implBlock "$(broadcast_block "$deploy_run" "$impl")" \
    --arg distributor "$distributor" --argjson distributorBlock "$(broadcast_block "$distributor_run" "$distributor")" \
    --arg vault "$vault" --argjson vaultBlock "$(broadcast_block "$vault_run" "$vault")" \
    --arg forwarder "$forwarder" --argjson forwarderBlock "$(tx_block "$forwarder_tx")" \
    --arg pair "$pair" --argjson pairBlock "$(tx_block "$pool_tx")" \
    --argjson start "$MIGRATION_START_TIME" --argjson deadline "$DEADLINE_THOR" \
    '{
      sourceCommit: $commit,
      distributor: "MetroDistributorV1",
      timersSeconds: $timers,
      contracts: {
        METRO: {address: $metro, deployBlock: $metroBlock},
        xMETRO: {address: $xmetro, deployBlock: $xmetroBlock},
        ThorMigrationEscrow: {address: $escrow, deployBlock: $escrowBlock},
        MetroDistributorV1: {address: $distributor, deployBlock: $distributorBlock},
        XMetroDeFiAdapterProxy: {address: $proxy, deployBlock: $proxyBlock},
        XMetroDeFiAdapterImplementation: {address: $impl, deployBlock: $implBlock},
        CommissionVault: {address: $vault, deployBlock: $vaultBlock},
        RateLimitedForwarder: {address: $forwarder, deployBlock: $forwarderBlock}
      },
      migration: {
        startTime: $start, deadlineThor: $deadline, deadlineYThor: $deadline,
        ratioThor: env.RATIO_THOR, ratioYThor: env.RATIO_YTHOR, capThor: env.CAP_THOR, capYThor: env.CAP_YTHOR,
        yThorRewardWeightBps: (env.YTHOR_REWARD_WEIGHT_BPS | tonumber)
      },
      commissionVault: {
        settlementTimelock: (env.SETTLEMENT_TIMELOCK | tonumber), payoutTimelock: (env.PAYOUT_TIMELOCK | tonumber),
        maxCodeDelta: env.MAX_CODE_DELTA, maxBatchDelta: env.MAX_BATCH_DELTA
      },
      forwarder: {dripRate: env.FORWARDER_DRIP_RATE, dripPeriod: (env.FORWARDER_DRIP_PERIOD | tonumber), maxReserve: env.FORWARDER_MAX_RESERVE},
      pools: {"METRO/USDC": {address: $pair, deployBlock: $pairBlock}}
    }')"
  publish system "$system" "$deploy_run" "$distributor_run" "$vault_run" "$out"
}

case "$TARGET" in
  system) deploy_system ;;
  fixtures) deploy_fixtures ;;
esac
