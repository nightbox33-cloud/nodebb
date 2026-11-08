#!/usr/bin/env bash
# 02_arbitrary_call_lever.sh
#
# Checks the two halves of the arbitrary-call signer bypass:
#   (A) the CONTRACTS half -- is the mainnet GatewayEVM implementation capable
#       of routing messageContext.sender == address(0) into a raw call?
#   (B) the CLIENT half -- does the ZetaClient line that mainnet runs generate
#       that payload, and does it have a guard?
#
# Everything is proven against the on-disk clones (source of truth for
# bytecode/ABI/params), no RPC is used.
#
# Usage: ./02_arbitrary_call_lever.sh [DEST]   (DEST default: /tmp/zeta)

set -uo pipefail
DEST="${1:-/tmp/zeta}"
EVM="$DEST/protocol-contracts-evm"
NODE="$DEST/node"

hr() { printf '\n=== %s\n' "$1"; }

hr "(A1) which released tag does mainnet run?  (node/VERSIONS.md)"
grep -n 'EVM Gateway' "$NODE"/VERSIONS.md | head -3

hr "(A2) mainnet GatewayEVM implementation address, as published by the repo"
git -C "$EVM" show origin/main:data/checksum/mainnet.json \
  | python3 -c 'import sys,json;d=json.load(sys.stdin);print("chain 1 ->",d["1"]["GatewayEVMImplementation"])'

hr "(A3) the broadcast run that deployed it, and whether the artefact carries the guard selector"
# keccak4(ArbitraryCallDisabled())            == 69b675aa
# keccak4(ArbitraryCallNotSupported())        == 35bb6796
# keccak4(depositPaused())                    == 02befd24
for c in $(git -C "$EVM" log --format=%h --all -- broadcast/DeployGatewayEVMImplementation.s.sol/1/run-latest.json); do
  git -C "$EVM" show "$c":broadcast/DeployGatewayEVMImplementation.s.sol/1/run-latest.json \
  | python3 -c "
import sys,json,datetime
d=json.load(sys.stdin); t=d['transactions'][0]; inp=t['transaction']['input']
print('  commit %-10s deploy=%s  arbCallDisabled=%d  depositPaused=%d' % (
  '$c', t['contractAddress'], inp.count('69b675aa'), inp.count('02befd24')))
"
done

hr "(A4) GatewayEVM.execute on the v14 line (what VERSIONS.md says mainnet runs)"
git -C "$EVM" show v14.0.1:contracts/evm/GatewayEVM.sol \
  | grep -n '_executeArbitraryCall\|function execute(\|function executeWithERC20' | head

hr "(A5) GatewayZEVM.call() -- user-reachable trigger, still present on v14 AND on deployed line"
for ref in v14.0.1 v15.0.0 develop origin/main; do
  printf '  %-12s GatewayZEVM.call=%s  GatewayEVM._executeArbitraryCall=%s\n' "$ref" \
    "$(git -C "$EVM" show $ref:contracts/zevm/GatewayZEVM.sol 2>/dev/null | grep -c 'function call(')" \
    "$(git -C "$EVM" show $ref:contracts/evm/GatewayEVM.sol 2>/dev/null | grep -c '_executeArbitraryCall')"
done

hr "(B1) client: MessageContext() turns IsArbitraryCall into sender=0x0 (main check-out)"
grep -n 'IsArbitraryCall' -A 3 "$NODE"/zetaclient/chains/evm/signer/outbound_data.go | sed -n '1,12p'

hr "(B2) client: does each release line carry the cancel guard?"
for ref in origin/release/v36 v36.0.6 v37.0.9 v38.0.1 v38.0.2 v38.0.3 v38.0.5 zetaclient_v37.0.10 zetaclient_v37.0.12 main; do
  n=$(git -C "$NODE" show "$ref":zetaclient/chains/evm/signer/v2_signer.go 2>/dev/null \
      | grep -c 'IsArbitraryCallCancellable\|IsGatewayExecuteOutbound')
  printf '  %-22s guard=%s\n' "$ref" "$n"
done

hr "(B3) the evm fork the client pins, per release (module-account/statedb hardening present?)"
for ref in v36.0.1 v36.0.4 v36.0.5 v36.0.6 v37.0.9 v38.0.5; do
  pin=$(git -C "$NODE" show "$ref":go.mod | awk '/zeta-chain\/evm /{print $NF}')
  short=${pin##*-}
  has=$(git -C "$DEST/evm" cat-file -e "$short" 2>/dev/null && \
        git -C "$DEST/evm" show "$short":x/vm/keeper/statedb.go 2>/dev/null \
        | grep -c 'BlockedAddr\|isModule')
  printf '  %-10s evm=%-42s blocking-gate-hits=%s\n' "$ref" "$pin" "${has:-n/a}"
done

echo
echo "Interpretation: A3 shows the last *reproducible* mainnet implementation is"
echo "0x9ef630ab... (2025-08-26, no guard).  The 2026 implementations that DO carry"
echo "the guard (0xb8afbcaf..., 0x9D7aD582...) have no broadcast artefact, so their"
echo "deployment provenance cannot be verified offline."

# --- (C) bytecode-level provenance: which implementation really has the guard ---
hr "(C1) mainnet GatewayEVM impl 0x9ef630ab (2025-08-26) -- selectors found by PUSH4"
git -C "$EVM" show bae2fa3:broadcast/DeployGatewayEVMImplementation.s.sol/1/run-latest.json \
| python3 -c "
import sys,json
i=json.load(sys.stdin)['transactions'][0]['transaction']['input'].lower()
for name,s in [('execute()','38e22527'),('executeWithERC20()','7bbe9afa'),
               ('ArbitraryCallDisabled()','69b675aa'),('depositPAUSED()','02befd24')]:
    print('   %-26s %s push4=%d' % (name, s, i.count('63'+s)))
"

hr "(C2) mainnet GatewayZEVM impl 0xef195bf4 (2025-08-26) -- is free call() present?"
git -C "$EVM" show 55c1146:broadcast/DeployGatewayZEVMImplementation.s.sol/7000/run-latest.json \
| python3 -c "
import sys,json
i=json.load(sys.stdin)['transactions'][0]['transaction']['input'].lower()
for name,s in [('call(...) [FREE]','06cb8983'),('withdrawAndCall(...)','7b15118b'),
               ('ArbitraryCallNotSupported()','35bb6796')]:
    print('   %-30s %s push4=%d' % (name, s, i.count('63'+s)))
"

hr "(C3) later GatewayZEVM impl 0x38bfe581 (de1acfe) -- call() removed?"
git -C "$EVM" show de1acfe:broadcast/DeployGatewayZEVMImplementation.s.sol/7000/run-latest.json \
| python3 -c "
import sys,json
i=json.load(sys.stdin)['transactions'][0]['transaction']['input'].lower()
for name,s in [('call(...) [FREE]','06cb8983'),('withdrawAndCall(...)','7b15118b')]:
    print('   %-30s %s push4=%d' % (name, s, i.count('63'+s)))
"

hr "(C4) does any broadcast run mention each implementation address?"
for a in 9d7ad582 b8afbcaf 38bfe581 9ef630ab; do
  n=$(git -C "$EVM" log --all -S "$a" --format=%h -- broadcast | wc -l)
  printf '   %s  commits-touching-broadcast=%s\n' "$a" "$n"
done
echo "   note: b8afbcaf/38bfe581 have a run (inside de1acfe) whose 'commit' field is 619af80,"
echo "         a squash-merge SHA absent from the repo; 9d7ad582 has no run at all."
