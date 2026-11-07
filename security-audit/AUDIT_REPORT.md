# Auditoría ofensiva — ZetaChain (ZetaCore / ZetaClient / gateways)

**Fecha:** 2026-11-07 · **Rama de trabajo:** `arena/8aea69bb-nodebb`
**Objetivo auditado:** `nightbox33-cloud/nodebb` @ `4de91237` — árbol **byte-idéntico** a `zeta-chain/node` `main` (`tree 0e15bb65`). No es NodeBB: es el nodo de ZetaChain.

---

## 0. VEREDICTO

# **NO CRÍTICO LIVE** (no probado ningún drenaje permissionless de fondos de terceros)

Ningún candidato cumple los 4 criterios simultáneamente. Los cinco candidatos serios y
**el hecho exacto que los mata**:

| # | Candidato | Por qué NO es crítico live |
|---|---|---|
| 1 | **GHSA Aug-2026 "statedb hardening"** (underflow de `SubBalance` → mint) en `zeta-chain/evm` | Mainnet corre `v36.0.6`, que **ya contiene** el hardening: su pin `evm@3e5f8e53` es idéntico a `a69d910` en `state_object.go`, `statedb.go`, `precompiles/common/utils.go`, `x/ibc/callbacks` y `x/precisebank`; solo difiere `x/vm/keeper/statedb.go` (matiz module-account vs blocked-addr, no launderflow). Además el vector que lo hace alcanzable (cuenta vesting + delegar monedas bloqueadas) está **bloqueado en el ante**: `MsgCreateVestingAccount`, `MsgCreatePermanentLockedAccount`, `MsgCreatePeriodicVestingAccount` rechazados directo y vía authz/group. |
| 2 | **V2 arbitrary call → GatewayEVM ejecuta calldata arbitraria como el Gateway** (hotfix #4575/#4576/#4580 solo en v37/v38; mainnet es v36) | El primitivo no mueve escrow: `ERC20Custody.withdraw*` y `ZetaConnector*.withdraw*` son `onlyRole(WITHDRAWER_ROLE)` = **TSS** (no el Gateway); `GatewayEVM.deposit()` reenvía el nativo **directo a `tssAddress`** (el Gateway no custodia saldo); y el contrato que sí confía en el Gateway (`Registry`, `GATEWAY_ROLE`) **no lo lee ninguna ruta de valor** del protocolo. Además el patch de contratos que desactiva arbitrary calls (#633) fue **desplegado en mainnet** (impls `0xb8afbcaf…`, luego `0x9D7aD582…`, con tx reales en `broadcast/*/1/run-latest.json`). Queda como capacidad de *spoofing* hacia integradores, no como drenaje. |
| 3 | **ZCNode-228 Alpha-Rays / TSSHOCK** (MtA `betaPrm = q^7`) | Parcheado en el árbol auditado: `9a516a34` (*tighten MtA proof bounds in tss-lib*) es ancestro de `main`; el script de verificación del lado `chore/verify-zcnode228-attack-script` espera y obtiene **REJECT**. Además exige participar en keygen (rol bonded). |
| 4 | **Subsistema "emergency TSS drain"** (mueve 100% de BTC + nativo EVM de la TSS) | En `main`/v36 **falla cerrado**: `receiversByNetwork[mainnet] = UNSET` y `receivers.Validate()` aborta el armado; el poller solo existe con build tag `drain` y exige `ZETACLIENT_DRAIN_URL` (env del operador). El build por defecto compila `startDrainIfArmed` como no-op. |
| 5 | **Fee/denominación cointype ZETA (#4542)** | Corregido **antes** de v36.0.6 (feb-2026) y además es solo un campo de accounting (`UserGasFeePaid`), no un movimiento de inventario ajeno. |

**Riesgo real más grave encontrado (NO calificable, ver §6):** dos ramas `drain-build/mainnet-*`
reescriben los receivers mainnet a direcciones de terceros (`0x0a538985…`, `bc1qkl02…`) y **reutilizan
la clave de operador de testnet** para mainnet. Es riesgo de cadena de suministro/insider: exige que
los operadores compilen y **armen** ese build (rol privilegiado) ⇒ falla el criterio 2.

---

## 1. ESTADO LIVE ANCLADO (fuente: clones, no explorer)

No hay egress RPC en este sandbox (solo `github.com`, `codeload`, `api.github.com`,
`registry.npmjs.org`, `pypi.org`, `files.pythonhosted.org`); verificado: `zetachain-evm.blockpi.network`
y `zetachain.blockscout.com` → `000`. Por eso el ancla es **el artefacto versionado**, no la lectura
on-chain. Los ítems que dependen de estado on-chain se listan como *gaps* en §7 con el comando exacto.

| Componente | Versión live | Artefacto/commit que lo fija |
|---|---|---|
| ZetaCore / ZetaClient mainnet | **v36** (`v36.0.6`) | `zeta-chain/node` tag `v36.0.6` = `ea7aa71989a17d9d6a413a2aa7e6f36ff8b68544` (= tip `release/v36`) |
| `cosmos/evm` (EVM de ZetaChain) | pin mainnet | `go.mod` de v36.0.6 → `zeta-chain/evm@3e5f8e5337fa` (v0.0.0-20260825060942) |
| EVM Gateway / Custody / Connector mainnet | **v14** | `protocol-contracts-evm` tag `v14.0.1` = `dbd47a37559bc8e4035131b731c9a0fe64a02058` |
| Testnet (referencia de lo ya parcheado) | v37 (client) / v15 (gateway) | `zetaclient_v37.0.12`, `v15.0.0` |

**`VERSIONS.md` (main):** mainnet ZetaCore **v36** · ZetaClient **v36** · EVM Gateway **v14** ·
Solana **v5** · Sui **v1** · TON **v2**. Testnet ya en v37/v15/v6/v2.

Direcciones mainnet (de `data/checksum/mainnet.json`, que es lo que firma el repo de contratos):

| chain | GatewayEVM (proxy) | ERC20Custody | TSS |
|---|---|---|---|
| 1 (Ethereum) | `0x48B9AACC350b20147001f88821d31731Ba4C30ed` | `0x0Bad40D9e9C369f2223c835E108f43a45fd223B5` | `0x70e967acFcC17c3941E87562161406d41676FD83` |
| 56 (BNB) | `0x48B9AACC350b20147001f88821d31731Ba4C30ed` | `0x0Bad40D9e9C369f2223c835E108f43a45fd223B5` | idem |
| 137 (Polygon) | `0x48B9AACC350b20147001f88821d31731Ba4C30ed` | `0x0Bad40D9e9C369f2223c835E108f43a45fd223B5` | idem |
| 8453 (Base) | `0x48B9AACC350b20147001f88821d31731Ba4C30ed` | `0x0Bad40D9e9C369f2223c835E108f43a45fd223B5` | idem |
| 42161 (Arbitrum) | `0x1C53e188Bc2E471f9D4A4762CFf843d32C2C8549` | `0xECe33274237E6422f2668eD7dEE5901b16336aA0` | idem |
| 43114 (Avalanche) | `0x1C53e188Bc2E471f9D4A4762CFf843d32C2C8549` | `0xECe33274237E6422f2668eD7dEE5901b16336aA0` | idem |
| 7000 (ZetaChain) | GatewayZEVM `0xfEDD7A6e3Ef1cC470fbfbF955a22D793dDC0F44E`, FungibleModule `0x735b14BB79463307AAcBED86DAf3322B1e6226aB` | — | — |

Impls del Gateway (EIP‑1967, cambiar por upgrade): v14.0.1 → `0x9ef630aB803FE9a7F46214242731298EE7025794`;
`protocol-contracts-evm@main` (impl desplegada real en chain 1, bloque `0x17d61c3`) → `0xb8afbcaf8125d61e0a06907312239a3db69307c5`,
y la más reciente registrada en checksum → `0x9D7aD5821A40B9e90199E343f3AfC1591FbDfa52`.

*Program ids:* Solana gateway **v5**, Sui **v1**, TON **v2** (per `VERSIONS.md`); no auditados en
profundidad porque el valor en riesgo principal está en la TSS nativa + custody EVM (ver §5).

---

## 2. REQUISITO PREVIO — repos de la fundación

**Org enumerada:** `zeta-chain` (GitHub) — **76 repositorios** vía `api.github.com/orgs/zeta-chain/repos?per_page=100`
(3 páginas). Inventario guardado en `/home/user/repo_inventory.json`.

**Clonados completos (todas las ramas + tags, `--no-single-branch`), HEAD al momento del clone:**

```
node                     4de91237  tags=515  branches=84
protocol-contracts-evm   eeb2c85   tags=44   branches=20
protocol-contracts-solana 0ee7e43  tags=14   branches=51
protocol-contracts-sui   421b94e   tags=4    branches=24
protocol-contracts-ton   19cac2e   tags=6    branches=8
go-tss                   a0868ab   tags=10   branches=35
evm (fork cosmos/evm)    fed5d32   tags=17   branches=30
networks                 4355880   tags=45   branches=9
network-mainnet          b3f21af   tags=0    branches=31
network-config           34efb4b   tags=3    branches=7
contract-addresses       b96bd82   tags=0    branches=4
audit-reports            c9d170f   tags=0    branches=3
localnet                 0135bd0   tags=96   branches=116
standard-contracts       68f2dd9   tags=30   branches=12
app-contracts            66ad597   tags=17   branches=25
toolkit                  184af34   tags=127  branches=68
ethermint                32d27766  tags=0    branches=22
protocol-contracts-archive 4cde560 tags=28   branches=34
protocol-contracts       48ecdbc   tags=39   branches=19
example-contracts        0c5e0f7   tags=0    branches=61
zetacored-docker         7b2f53c   tags=4    branches=4
noderelease2proposal     a07fc00   tags=0    branches=7
network-athens3          b78630a   tags=0    branches=48
cosmos-sdk (v0.53.4, sparse x/auth/vesting)  → para verificar mensajes de vesting
```

**No clonados (declarado, no hay cobertura completa):** forks upstream de gran tamaño sin lógica
propia de valor — `viem` (374 MB), `cosmos-sdk` completo, `go-ethereum`/`-legacy`/`-legacy-2`,
`blockscout`, `bifrost`, `ethermint-fork`, `evm` upstream forks, `docs` (152 MB), `sourcify`,
`ethereum-lists-chains`, `contract-metadata`, `go-libp2p`, `gosec`, `semgrep-utilities`, `tmkms`,
`keystone`, `solana-go`, `go-bcs`, `github-exporter`, `cloudflare-exporter`, `gh-action-changed-files`,
`cosmprund*`, `ton-docker*`, `sui-docker`, `solana-docker`, `ci-testing-node`, `kyber`, `FluidUSDC`,
`cli`, `wallet`, `universalkit*`, `template`, `hackathon-*`, `vibecoding-nft`, `agent`,
`example-frontend`, `zeta-examples`, `zetachain-improvement-proposals`, `issues`,
`codeql-security-rules`, `smart-contract-vulns`, `copy-docker-images`, `dl-pipe`,
`node-localnet-bitcoin-sidecar`, `bitcoin-core-docker`, `noderelease2proposal` (sí clonado), `.github`.

**Repos privados/bloqueados:** ninguno: la API devolvió 76/76 públicos (no hay org de GitLab/Bitbucket
declarada en la documentación; `docs` referencia solo GitHub + HackenProof).

**Ramas que resultaron ser la pista principal:** `release/v36` (mainnet), `release/zetaclient/v37`,
`release/zetaclient/v38`, `sec/testnet-v37-revert-guard`, `fix/disable-arbitrary-call-v38`,
`chore/verify-zcnode228-attack-script`, `drain-build/mainnet-client-v37`, `drain-build/mainnet-server-main`,
`drain-build/run-1786582970`, `ci/build-drain-artifacts-main`; tags `drain-mainnet-20260826`,
`drain-testnet-20260824{,-v2}`, `drain-testnet-20260812`.

---

## 3. INVENTARIO AJENO Y QUIÉN PUEDE MOVERLO

| Inventario | Dónde vive | Quién lo mueve |
|---|---|---|
| **Nativo EVM** (ETH/BERA/POL/BNB/AVAX) de todos los depósitos | **cuenta TSS** `0x70e967acFcC17c3941E87562161406d41676FD83` (el `deposit()` del Gateway lo reenvía ahí) | umbral TSS vía `MsgVoteOutbound`/signer; o el *drain* (§6) |
| **BTC** de depósitos | UTXOs de la dirección TSS BTC | umbral TSS vía `SignWithdrawTx`; o el *drain* |
| **ERC20** puenteados | `ERC20Custody` en cada chain (`WITHDRAWER_ROLE` = TSS) | solo TSS |
| **ZETA** (connector non-native) | `ZetaConnector` | solo TSS |
| **Supply ZRC20** colateralizado | módulo `x/fungible` en ZEVM | solo módulo fungible (mint/burn por consenso) |
| Gas stability pool | cuenta módulo en ZEVM | keeper, no permissionless |

Todo lo anterior exige firma TSS (≥umbral) o consenso. **No hay clave de usuario que toque estos saldos.**

---

## 4. CANDIDATOS: POR QUÉ MUEREN (detalle con evidencia)

### 4.1 GHSA Aug-2026 statedb hardening — *no live*
`zeta-chain/evm` introduce en `a69d910` (*"port GHSA Aug-2026 statedb hardening"*) cuatro defensas:
(a) snapshot de `LockedCoins` en la cuenta del statedb, (b) guard de underflow en `SubBalance`,
(c) guard de overflow en `AddBalance`, (d) `Commit()` atómico, (e) rechazo de reconciliación hacia
direcciones bloqueadas, (f) `cachedCtx` en callbacks IBC. La nota del CHANGELOG lo describe como
primitivo de **mint/burn** ("that reconciliation is the mint/burn primitive the statedb underflow
turns into an exploit").

**Hecho que lo mata:** el pin de mainnet (`3e5f8e53`, el commit del que se construyó v36.0.6, según
`ea7aa719`) **ya contiene (a)-(d) y (f)**: `git diff 3e5f8e53 a69d910` sobre
`x/vm/statedb/state_object.go`, `x/vm/statedb/statedb.go`, `precompiles/common/utils.go`,
`x/ibc/callbacks/keeper/keeper.go`, `x/precisebank/keeper/keeper.go` = **vacío**; y
`3e5f8e53:x/vm/statedb/state_object.go` ya hace `panic("state balance underflow …")`.
Solo difiere `x/vm/keeper/statedb.go` (guard sobre `BlockedAddr` vs. cualquier module account), que
es exactamente lo que describe el commit `4639` al *re-pinear* v36 para no romper consenso.

Segundo hecho que lo mata: el vector natural (cuenta vesting con monedas bloqueadas → `delegate`
por el precompile de staking → `SubBalance` > spendable) requiere **crear** una cuenta vesting, y el
ante la rechaza en mempool y vía authz/group (`app/ante/vesting.go`, `app/app.go:DisabledAuthzMsgs`).
No hay `ClawbackVesting` en el msg‑server de `x/auth/vesting` usado por la app.

### 4.2 V2 arbitrary call (GatewayEVM como `msg.sender`) — *no drenable*
Cadena real (v14.0.1): usuario en ZEVM llama `GatewayZEVM.call(receiver,payload)` → CCTX con
`IsArbitraryCall=true` → zetaclient v36 firma `GatewayEVM.execute(MessageContext{sender:0x0}, destination, data)`
(`zetaclient/chains/evm/signer/outbound_data.go:164`) → `_executeArbitraryCall` hace
`destination.call{value: msg.value}(data)` con **`msg.sender = GatewayEVM`**.

Alcanzar el escrow requeriría que el Gateway pueda retirar. No puede:

* `ERC20Custody.withdraw/withdrawAndCall/withdrawAndRevert` → `onlyRole(WITHDRAWER_ROLE)`, y ese rol se
  otorga **solo a `tssAddress_`** en `initialize` (`ERC20Custody.sol:63`).
* `ZetaConnector*.withdraw*` → `onlyRole(WITHDRAWER_ROLE)` = `tssAddress_` (`ZetaConnectorBase.sol:77`).
* `GatewayEVM.deposit()` **no retiene** el nativo: lo reenvía con `tssAddress.call{value: msg.value}("")`
  (`GatewayEVM.sol:242,289`) ⇒ el Gateway no tiene saldo propio que robar.
* Todos los egresos de nativo del Gateway son `onlyRole(TSS_ROLE)` / `onlyRole(ASSET_HANDLER_ROLE)`
  (`execute`, `executeRevert`, `executeWithERC20`, `revertWithERC20`); `msg.sender` del call arbitrario
  es el propio Gateway, que **no** tiene `TSS_ROLE` sobre sí mismo.
* El único contrato que confía en el Gateway es `Registry` (`_grantRole(GATEWAY_ROLE, gatewayEVM_)`).
  El call arbitrario **sí** puede escribir el Registry (aporta `context.sender = coreRegistry`, que es
  un campo controlado por el atacante, y `msg.sender`=Gateway pasa `onlyRole(GATEWAY_ROLE)`;
  `onCall` hace self‑call con `onlyRegistry`). Pero **ningún contrato del protocolo lee Registry**
  (grep en `GatewayEVM`, `ERC20Custody`, `ZetaConnector*` = 0 referencias): solo afecta a integradores
  que voluntariamente lean el registro. Eso es *poisoning/phishing*, no drenaje de escrow.
* En paralelo, el patch de contratos #633 (`ArbitraryCallDisabled`) fue desplegado en mainnet: el
  broadcast de chain 1 registra la tx real `0x9ce3ab53…` (bloque `0x17d61c3`) creando el impl
  `0xb8afbcaf…` con el ABI sin arbitrary call, y el checksum mainnet se actualizó a `0x9D7aD582…`.

Conclusión: **no drena terceros**. Queda (i) spoofing hacia dApps que confíen en `msg.sender == gateway`,
(ii) poisoning del Registry. Nada de eso es "termina con más valor, sacado de inventario ajeno".

### 4.3 ZCNode-228 (Alpha-Rays / TSSHOCK) — *parcheado*
`9a516a34` (*tighten MtA proof bounds in tss-lib*, #4569) es ancestro de `main`; el repo fija
`github.com/bnb-chain/tss-lib => zeta-chain/tss-lib` (fork). El script de la rama
`chore/verify-zcnode228-attack-script` (`e2e/scripts/verify_zcnode228.go`) construye `betaPrm = q^7`
y exige `ProofBobWC.Verify == false`. Además el atacante de Alpha-Rays debe ser participante de
keygen: rol *bonded*, no permissionless.

### 4.4 Drain de la TSS — *falla cerrado en main/v36*
Ver §6 (es el hallazgo más relevante, pero no cumple criterio 2).

### 4.5 Otros descartes rápidos
* `b653f96f` *check grantee for IsSystemTx*: bypass de autorización para gas reducido/prioridad
  (griefing), no movimiento de valor.
* `#4542` fee de cointype ZETA en denominación incorrecta: solo el campo `UserGasFeePaid`; corregido
  feb‑2026, **dentro** de v36.
* Fixes presentes en `v36.0.6..main` (refunds #3734, multiple EVM calls #4157, NoAssetCall desde
  Bitcoin #4218, drain #4612) **no están en v36.0.6** ⇒ son *desarrollo, no live* y quedan fuera de scope.

---

## 5. ¿HAY ALGO EN EL CÓDIGO NUEVO (no live) QUE HAYA QUE VIGILAR?

Sí, dos cosas que **no** son críticas hoy porque no están desplegadas en mainnet:

1. `feat: refund a portion of remaining unused tokens to user (#3734)` y
   `feat: multiple evm calls in single tx (#4157)`: nuevas rutas de accounting de gas/refunds en
   `x/crosschain`. No auditadas como live (posteriores a v36.0.6).
2. `feat(zetaclient): emergency TSS native-fund drain (#4612)`: mueve el 100% del inventario nativo.
   Su diseño (receiver compilado + payload firmado + ventana de altura) es correcto **si** los anclajes
   son correctos — y en las ramas de build no lo son (§6).

---

## 6. RIESGO NO CALIFICABLE (cadena de suministro / insider) — el hallazgo más serio

Dos ramas de build **no mergeadas** configuran los anclajes de mainnet del subsistema de drain:

```
commit 231ca54b  "build(drain): set mainnet drain anchors — drain-build/mainnet-server-main"
  pkg/drain/receivers.go:  EVM: unset -> 0x0a538985123729f48D70DBCaE82a7f47f1CbA8f8
                           BTC: unset -> bc1qkl02lqffhmpf5hn3khnetc0ay9yyk4eajmlefy

commit f7b593ca  "build(drain): set mainnet drain anchors — drain-build/mainnet-client-v37"
  + OperatorPubKeyHex: 0x000…0 -> 0x03579d09c8a72ebf96e943c121926f3bfaf7600b9685eda7692786bf3cfca2c9fc
  + los mismos receivers mainnet
```

* `0x03579d09…` es, según el propio `pkg/drain/receivers.go` de `main`, **la clave de operador de
  TESTNET** ("This is the TESTNET operator key"); su privada se pasa en runtime al servidor de drain
  (`--signing-key`) y **no** está en el repo.
* Con ese build + `-tags drain` + `ZETACLIENT_DRAIN_URL`, el poller mueve **todo** el nativo de la TSS
  (EVM + BTC) a `0x0a538985…` / `bc1qkl02…` en cuanto reciba un payload `final: true` firmado por el
  dueño de esa clave, y el guard de receiver **valida contra esos mismos valores compilados**
  (`poller.go:executeEVM/executeBTC`), así que no hay segunda barrera.
* **Por qué no lo declaro crítico:** exige (i) que los operadores compilen y ejecuten un build que no
  es release, (ii) que **armen** con la env (acción de operador), y (iii) que el dueño de la clave
  testnet firme. Es un rol privilegiado ⇒ criterio 2 falla. Y en `main`/v36 el camino falla cerrado.
* **Acción recomendada (severidad alta de proceso, no de exploit):** borrar/rotar la clave de operador
  de testnet, invalidar esas ramas, y no permitir que el *receiver* mainnet y la pubkey de operador
  viajen en ramas de build sin firma/atestación; añadir a `ReceiverForNetwork` una allowlist de
  direcciones con checksum revisado en un PR de release, y un guard que rechace armar un mainnet build
  si `OperatorPubKeyHex == testnet key`.

---

## 7. GAPS: lo que NO pude verificar (y el comando exacto para cerrarlo)

El sandbox **no tiene egress RPC**, así que **no medí balances on-chain** (no invento TVL). Para cerrar
el informe en un entorno con RPC:

```bash
# (1) ¿El proxy del Gateway mainnet apunta al impl parcheado (arbitrary calls deshabilitado)?
#     EIP-1967 implementation slot: 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc
cast storage 0x48B9AACC350b20147001f88821d31731Ba4C30ed \
  0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc --rpc-url $ETH_RPC
#   = 0x9ef630aB803FE9a7F46214242731298EE7025794  => v14.0.1 virgen (arbitrary call VIVO)
#   = 0xb8afbcaf… / 0x9D7aD582…                  => parcheado (arbitrary call MUERTO)

# (2) Inventario nativo de la TSS (el "loot" real)
for R in $ETH_RPC $BNB_RPC $POL_RPC $BASE_RPC $ARB_RPC $AVAX_RPC; do
  cast balance 0x70e967acFcC17c3941E87562161406d41676FD83 --rpc-url $R; done

# (3) Inventario ERC20 en custody (por token whitelisteado)
cast call 0x0Bad40D9e9C369f2223c835E108f43a45fd223B5 "balanceOf(address)(uint256)" <token> --rpc-url $ETH_RPC

# (4) Confirmación de que el guard de vesting está en el binario live
zetacored q auth params --node $ZETA_RPC   # y probar MsgCreateVestingAccount (debe fallar)
```

Sin (1) no se puede afirmar ni negar que el primitivo arbitrary-call siga vivo en mainnet; **con o sin
él, no hay ruta a fondos de terceros** (§4.2), por eso el veredicto no cambia.

---

## 8. REPRODUCCIÓN (comandos exactos usados)

```bash
# enumeración de la org (76 repos)
curl -s "https://api.github.com/orgs/zeta-chain/repos?per_page=100&page=1..3"

# clones (todas las ramas y tags)
git clone --no-single-branch https://github.com/zeta-chain/node.git
git clone --no-single-branch https://github.com/zeta-chain/evm.git
git clone --no-single-branch https://github.com/zeta-chain/protocol-contracts-evm.git
# + 20 repos más (ver §2)

# verificación automatizada de TODAS las afirmaciones de este informe (30 checks)
CLONES=/home/user/repos ./security-audit/verify_claims.sh
#  => PASS: 30   FAIL: 0

# checks puntuales
git -C ../node log -1 --format='%H %T' 4de91237                 # 0e15bb65… (== main)
git -C ../node show v36.0.6:go.mod | grep 'cosmos/evm =>'       # 3e5f8e53 (mainnet)
git -C ../evm  diff --name-only 3e5f8e5337fa a69d910e9214 -- \
     x/vm/statedb/state_object.go x/vm/statedb/statedb.go      # vacío => ya parcheado
git -C ../node  grep -n IsArbitraryCall origin/release/v36 -- zetaclient/
git -C ../protocol-contracts-evm show v14.0.1:contracts/evm/ERC20Custody.sol | grep -n WITHDRAWER_ROLE
git -C ../node  show origin/drain-build/mainnet-server-main:pkg/drain/receivers.go | sed -n '50,60p'
```

No se ejecutó fork de mainnet (anvil/foundry) porque **no hay RPC alcanzable**; el fichero
`security-audit/verify_claims.sh` es el PoC reproducible a nivel de artefacto, y §7 lista el fork/PoC
pendiente en un entorno con RPC.

---

## 9. MAPA dirección / id → repo · commit · artefacto

| Dirección / id | Componente | Repo · commit · artefacto |
|---|---|---|
| `0x48B9AACC…30ed` (1/56/137/8453), `0x1C53e188…8549` (42161/43114) | GatewayEVM proxy mainnet | `protocol-contracts-evm@v14.0.1` (`dbd47a37`) · `data/checksum/mainnet.json` |
| `0x9ef630aB…5794` | GatewayEVM impl v14.0.1 (arbitrary call habilitado) | idem · `broadcast/DeployGatewayEVMImplementation.s.sol/<chain>` |
| `0xb8afbcaf…07c5` (chain 1, bloque `0x17d61c3`), `0x9D7aD582…fa52` | impl con `ArbitraryCallDisabled` | `protocol-contracts-evm@main` #633 (`de1acfe`) + checksum |
| `0x0Bad40D9…23B5` / `0xECe33274…6aA0` | ERC20Custody | `protocol-contracts-evm@v14.0.1` |
| `0x70e967acFcC17c3941E87562161406d41676FD83` | TSS mainnet (custodio de nativo) | `zeta-chain/node@v36.0.6`; derivado del TSS pubkey en `x/observer` |
| `0xfEDD7A6e3Ef1cC470fbfbF955a22D793dDC0F44E` / `0x735b14BB…26aB` | GatewayZEVM / FungibleModule (chain 7000) | `protocol-contracts-evm@v14.0.1` |
| ZetaCore/ZetaClient | binario mainnet | `zeta-chain/node@v36.0.6` (`ea7aa719`) |
| EVM de ZetaChain (statedb, precompiles) | runtime | `zeta-chain/evm@3e5f8e5337fa` (pin v36.0.6) |
| TSS threshold lib | firma | `zeta-chain/tss-lib` (pin `2e6b438bd901`) + `go-tss@a0868ab` |
| Solana / Sui / TON gateway | program/package ids | `protocol-contracts-{solana,sui,ton}@v5/v1/v2` (no profundizado) |

---

## 10. CONCLUSIÓN

En el estado **desplegado** (v36.0.6 + gateways v14 + TSS), no encontré ninguna vulnerabilidad que un
atacante **sin rol** pueda usar para terminar con más valor del que puso a costa de terceros. Los tres
"casi" (underflow del statedb, arbitrary call en el signer, drain de la TSS) están neutralizados por,
respectivamente, **el pin de mainnet ya endurecido**, **los roles `WITHDRAWER_ROLE`/`TSS_ROLE` en la TSS**
y **el fail-closed de los anclajes mainnet**. El riesgo residual más serio es de **proceso**: ramas de
build de drain con receivers de terceros y reutilización de la clave de operador de testnet (§6).
