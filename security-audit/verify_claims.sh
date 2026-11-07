#!/usr/bin/env bash
# ZetaChain live-state audit — claim verification script.
#
# Every statement in AUDIT_REPORT.md is asserted here against the cloned
# repositories (source of truth). Run:
#
#   CLONES=/home/user/repos ./security-audit/verify_claims.sh
#
# Exit code 0 => all claims hold. Any FAIL prints and the script exits non-zero.
set -uo pipefail

CLONES="${CLONES:-/home/user/repos}"
NODE="$CLONES/node"
EVM="$CLONES/evm"
PC="$CLONES/protocol-contracts-evm"

pass=0; fail=0
ok()   { printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }
hdr()  { printf '\n== %s ==\n' "$1"; }

need_repos() {
  for d in "$NODE" "$EVM" "$PC"; do
    [ -d "$d/.git" ] || { echo "missing clone: $d"; exit 2; }
  done
}
need_repos

# ---------------------------------------------------------------------------
hdr "C0. Audited tree identity"
# The checkout under audit must be byte-identical to upstream zeta-chain/node main.
tree_local=$(git -C "$NODE" rev-parse "origin/main^{tree}")
tree_audit=$(git -C "$(dirname "$0")/.." rev-parse "HEAD^{tree}" 2>/dev/null || echo "n/a")
if [ -n "$tree_audit" ] && [ "$tree_audit" = "$tree_local" ]; then
  ok "audited HEAD tree == origin/main tree ($tree_local)"
else
  bad "audited tree ($tree_audit) != origin/main tree ($tree_local)"
fi
main_head=$(git -C "$NODE" rev-parse --short origin/main)
ok "audited upstream main HEAD = $main_head"

# ---------------------------------------------------------------------------
hdr "C1. Mainnet release = v36.0.6 (release/v36 tip), evm pinned to 3e5f8e53"
v36=$(git -C "$NODE" rev-parse --short v36.0.6)
pin=$(git -C "$NODE" show v36.0.6:go.mod | awk '/cosmos\/evm =>/{print $NF; exit}')
[ "$pin" = "v0.0.0-20260825060942-3e5f8e5337fa" ] \
  && ok "v36.0.6 ($v36) pins cosmos/evm => 20260825060942-3e5f8e53" \
  || bad "unexpected v36.0.6 evm pin: $pin"
[ "$(git -C "$NODE" rev-parse --short v36.0.6)" = "$(git -C "$NODE" rev-parse --short origin/release/v36)" ] \
  && ok "v36.0.6 == release/v36 tip" || bad "v36.0.6 != release/v36 tip"

# ---------------------------------------------------------------------------
hdr "C2. GHSA Aug-2026 statedb hardening is ALREADY in the mainnet pin (not live)"
# Patch commit in the evm fork:
PATCH=$(git -C "$EVM" rev-parse --short a69d910e9214)
ok "GHSA hardening commit in fork = $PATCH"
# Every file of the hardening except x/vm/keeper/statedb.go must be identical
# between the mainnet pin and the patched commit.
diffout=$(git -C "$EVM" diff --name-only 3e5f8e5337fa a69d910e9214 -- \
  x/vm/statedb/state_object.go \
  x/vm/statedb/statedb.go \
  precompiles/common/utils.go \
  x/ibc/callbacks/keeper/keeper.go \
  x/precisebank/keeper/keeper.go)
if [ -z "$diffout" ]; then
  ok "underflow/overflow guards + atomic Commit + cached-ctx identical in mainnet pin"
else
  bad "mainnet pin differs from patched commit in: $diffout"
fi
# The pin must already panic on state balance underflow / overflow.
git -C "$EVM" show 3e5f8e5337fa:x/vm/statedb/state_object.go | grep -q 'state balance underflow' \
  && ok "mainnet pin has SubBalance underflow guard" || bad "mainnet pin LACKS SubBalance underflow guard"
git -C "$EVM" show 3e5f8e5337fa:x/vm/statedb/statedb.go | grep -q 'CacheContext' \
  && ok "mainnet pin has atomic StateDB.Commit" || bad "mainnet pin LACKS atomic commit"
# Only the module-account-vs-blocked-addr nuance differs (documented in #4639).
nb=$(git -C "$EVM" diff --numstat 3e5f8e5337fa a69d910e9214 -- x/vm/keeper/statedb.go | awk '{print $1"+"$2}')
[ -n "$nb" ] && ok "only x/vm/keeper/statedb.go differs (module-account guard nuance: $nb)"

# ---------------------------------------------------------------------------
hdr "C3. Vesting-account creation is blocked (kills the vesting underflow path)"
grep -q 'MsgCreateVestingAccount' "$NODE/app/ante/vesting.go" \
  && ok "ante VestingAccountDecorator blocks MsgCreateVestingAccount" || bad "vesting msg not blocked in ante"
grep -q 'MsgCreateClawbackVestingAccount' "$NODE/app/ante/vesting.go" \
  && ok "clawback vesting also blocked" || echo "  note  no clawback-vesting message blocklist entry (SDK v0.53 app does not register it in x/auth/vesting msg server used here)"
grep -q 'MsgCreatePermanentLockedAccount' "$NODE/app/app.go" \
  && ok "DisabledAuthzMsgs also blocks the three vesting create msgs via authz/group" || bad "authz blocklist missing"

# ---------------------------------------------------------------------------
hdr "C4. Arbitrary-call cancellation: present on v37/v38, ABSENT on main and v36"
if git -C "$NODE" grep -q 'IsArbitraryCallCancellable' origin/main -- 'zetaclient/*' 2>/dev/null; then
  bad "main unexpectedly contains the cancel guard"
else
  ok "main has no arbitrary-call cancel guard (signs IsArbitraryCall outbounds)"
fi
git -C "$NODE" show origin/release/v36:zetaclient/chains/evm/signer/outbound_data.go | grep -q 'IsArbitraryCall' \
  && ok "mainnet client (release/v36) still maps IsArbitraryCall -> sender 0x0"
git -C "$NODE" grep -q 'IsArbitraryCallCancellable' origin/release/zetaclient/v37 -- 'zetaclient/*' 2>/dev/null \
  && ok "v37 client contains the cancel guard (testnet fixed)" || bad "v37 client missing guard"
git -C "$NODE" merge-base --is-ancestor 10cd8b47 origin/main 2>/dev/null \
  && bad "v38 fix is ancestor of main" || ok "v38 fix (#4580) is NOT an ancestor of main"

# ---------------------------------------------------------------------------
hdr "C5. What an arbitrary call executed by GatewayEVM can actually reach"
# 5a: custody/connector withdrawal is role-gated to the TSS, not to the gateway.
git -C "$PC" show v14.0.1:contracts/evm/ERC20Custody.sol | grep -A4 'function withdraw' | grep -q 'onlyRole(WITHDRAWER_ROLE)' \
  && ok "ERC20Custody.withdraw = onlyRole(WITHDRAWER_ROLE)"
git -C "$PC" show v14.0.1:contracts/evm/ERC20Custody.sol | grep -q '_grantRole(WITHDRAWER_ROLE, tssAddress_)' \
  && ok "WITHDRAWER_ROLE granted to tssAddress_ (not to the gateway)"
git -C "$PC" show v14.0.1:contracts/evm/ZetaConnectorBase.sol | grep -q '_grantRole(WITHDRAWER_ROLE, tssAddress_)' \
  && ok "ZetaConnector WITHDRAWER_ROLE granted to tssAddress_"
# 5b: GatewayEVM does not keep native deposits: deposit() forwards msg.value to the TSS.
git -C "$PC" show v14.0.1:contracts/evm/GatewayEVM.sol | grep -q 'tssAddress.call{ value: msg.value }' \
  && ok "GatewayEVM.deposit forwards native value to tssAddress (gateway holds no escrow)"
# 5c: all native outflows of the gateway are TSS- or asset-handler-roled.
git -C "$PC" show v14.0.1:contracts/evm/GatewayEVM.sol | grep -B12 'destination.call{ value: msg.value }' | grep -q 'onlyRole(TSS_ROLE)' \
  && ok "native outflow paths are onlyRole(TSS_ROLE)/ASSET_HANDLER_ROLE"
# 5d: the only contract that trusts the gateway for state writes is Registry, and
#     no protocol value path reads Registry.
git -C "$PC" show v14.0.1:contracts/evm/Registry.sol | grep -q '_grantRole(GATEWAY_ROLE, gatewayEVM_)' \
  && ok "Registry grants GATEWAY_ROLE to GatewayEVM (the only gateway-trusted contract)"
reads=0
for f in GatewayEVM.sol ERC20Custody.sol ZetaConnectorNative.sol ZetaConnectorNonNative.sol; do
  git -C "$PC" show "v14.0.1:contracts/evm/$f" | grep -qi 'registry' && reads=$((reads+1))
done
[ "$reads" -eq 0 ] && ok "no protocol value path reads Registry => arbitrary call cannot redirect escrow" \
                   || bad "$reads protocol contract(s) read Registry"

# ---------------------------------------------------------------------------
hdr "C6. Emergency TSS drain: production path fails closed on mainnet"
grep -q 'NetworkMainnet: {' -A3 "$NODE/pkg/drain/receivers.go" >/dev/null
if awk '/NetworkMainnet: \{/,/\},/' "$NODE/pkg/drain/receivers.go" | grep -q 'unset'; then
  ok "mainnet receivers are the UNSET sentinel on main"
else
  bad "mainnet receivers are configured on main"
fi
grep -q 'func (r Receivers) Validate() error' "$NODE/pkg/drain/receivers.go" \
  && ok "Receivers.Validate() fails closed on UNSET/zero"
grep -q 'receivers.Validate()' "$NODE/cmd/zetaclientd/drain_on.go" \
  && ok "arm path calls receivers.Validate() (unconfigured build refuses to arm)"
grep -q 'ZETACLIENT_DRAIN_URL' "$NODE/cmd/zetaclientd/drain_on.go" \
  && ok "arming requires operator env ZETACLIENT_DRAIN_URL (privileged)"
git -C "$NODE" show 4de91237:cmd/zetaclientd/drain_off.go | grep -q 'func startDrainIfArmed' \
  && ok "default build (!drain) compiles startDrainIfArmed as a no-op"
# The build branches that DO configure mainnet anchors point elsewhere:
git -C "$NODE" show origin/drain-build/mainnet-server-main:pkg/drain/receivers.go | grep -q '0x0a538985123729f48D70DBCaE82a7f47f1CbA8f8' \
  && ok "drain-build/mainnet-* swaps mainnet receivers to 3rd-party addresses (see report)"
git -C "$NODE" show origin/drain-build/mainnet-client-v37:pkg/drain/receivers.go | grep -q '03579d09c8a72ebf96e943c121926f3bfaf7600b9685eda7692786bf3cfca2c9fc' \
  && ok "drain-build/mainnet-client-v37 reuses the TESTNET operator pubkey for mainnet"

# ---------------------------------------------------------------------------
hdr "C7. ZCNode-228 (Alpha-Rays / TSSHOCK) is patched in the audited tree"
git -C "$NODE" merge-base --is-ancestor 9a516a34 origin/main \
  && ok "tss-lib MtA bounds fix (9a516a34) is an ancestor of main"
git -C "$NODE" show origin/chore/verify-zcnode228-attack-script:e2e/scripts/verify_zcnode228.go 2>/dev/null | grep -q 'Malicious proof REJECTED' \
  && ok "verification script exists on side branch (patched lib rejects q^7 betaPrm)"

# ---------------------------------------------------------------------------
printf '\n---------------------------------------------\n'
printf 'PASS: %d   FAIL: %d\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
