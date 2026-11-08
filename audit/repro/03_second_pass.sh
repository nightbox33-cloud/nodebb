#!/usr/bin/env bash
# 03_second_pass.sh -- the vectors checked in the intensive second round.
# Every assertion below is a *negative* result; the script prints the evidence.
set -uo pipefail
DEST="${1:-/tmp/zeta}"
NODE="$DEST/node"
EVM="$DEST/protocol-contracts-evm"
SOL="$DEST/protocol-contracts-solana"
hr() { printf '\n=== %s\n' "$1"; }

hr "(1) EVM observer: logs are filtered by emitter address AND topic0"
grep -n "Addresses: addresses" -B6 "$NODE"/zetaclient/chains/evm/observer/inbound.go | tail -8
grep -n "ValidateEvmTxLog(&ethlog, gatewayAddr" "$NODE"/zetaclient/chains/evm/observer/v2_inbound.go

hr "(2) ZRC20.deposit (the mint primitive) is gated; SystemContract.depositAndCall is onlyFungible"
grep -n "msg.sender != FUNGIBLE_MODULE_ADDRESS && msg.sender != SYSTEM_CONTRACT_ADDRESS" -A3 "$EVM"/contracts/zevm/ZRC20.sol
grep -n "function depositAndCall" -A3 "$EVM"/contracts/zevm/SystemContract.sol | head -8
grep -n "onlyProtocol" "$EVM"/contracts/zevm/GatewayZEVM.sol | head -4

hr "(3) ZETA accounting is a pure accumulator (never blocks a movement)"
grep -rn "GetZetaAccounting\|AbortedZetaAmount" "$NODE"/x/crosschain --include=*.go | grep -v _test | grep -v pb.go

hr "(4) TSS rate-limiter fix be79663d is NOT in the live v36.0.6 line"
git -C "$NODE" merge-base --is-ancestor be79663d v36.0.6 && echo "  PRESENT" || echo "  ABSENT in v36.0.6 (and it is a local semaphore, see PR #4072 body)"

hr "(5) MtA/TSSHOCK: tss-lib hardening per release (attacker must be a TSS participant)"
for t in v36.0.5 v36.0.6 zetaclient_v37.0.12 v38.0.5; do
  printf '  %-20s tss-lib=%s\n' "$t" "$(git -C "$NODE" show $t:go.mod | awk '/bnb-chain\/tss-lib =>/{print $NF}')"
done
git -C "$DEST/tss-lib" log -1 --format='  hardening commit: %h %cs %s' a4af30e

hr "(6) Solana gateway: message hash binds nonce+amount+destination+sender+data"
git -C "$SOL" show v5.0.0:programs/gateway/src/utils/validate_message_hash.rs | sed -n '20,36p'
git -C "$SOL" show v5.0.0:programs/gateway/src/utils/verify_and_update_nonce.rs | sed -n '1,20p'

hr "(7) refundStrandedFunds is DEFAULT_ADMIN_ROLE (privileged)"
grep -n "function refundStrandedFunds" -A8 "$EVM"/contracts/evm/ERC20Custody.sol
