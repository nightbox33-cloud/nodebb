# Auditoría ofensiva ZetaChain — informe final

**Fecha:** 2026-11-07
**Alcance:** todas las capas en alcance (nodo/consenso/p2p/mempool/VM/precompiles, contratos de sistema y de pasarela, puentes EVM/Solana/Sui/TON, DeFi en zEVM)
**Rama de trabajo:** `arena/834da711-nodebb` (clon persistente `/home/user/nodebb`, HEAD `4de91237f68c007a7d21a97f336910ff0b633828`)

---

## 0. Resultado

# **NO CRÍTICO LIVE**

Ningún hallazgo supera los cuatro criterios exigidos simultáneamente. Se encontró **un candidato de severidad alta** (bypass de firma de *arbitrary call*), real en código y alcanzable sin permisos, que **falla el criterio 4** (no se demuestra drenaje de fondos de terceros con la relación coste/beneficio requerida) y, además, **probablemente falla el criterio 3** en el estado desplegado actual (ver §4.3). El detalle del kill se da explícito, según lo pedido.

---

## 1. Prerrequisito — inventario de repositorios

### 1.1 Enumeración y clonado

```bash
gh api 'orgs/zeta-chain/repos?per_page=100' --paginate \
  -q '.[] | "\(.name)\t\(.private)\t\(.archived)\t\(.pushed_at)"'   # 76 repos
```

**Los 76 repositorios públicos de `zeta-chain` fueron clonados** (`git clone --no-single-branch`, todas las ramas y todas las etiquetas). Cero fallos. Cero repositorios privados/inaccesibles detectados vía API (todos `private=false`).

- Inventario con hash exacto y fecha de commit por repo: **`audit/repro/CLONE_INVENTORY.tsv`** (76 líneas: `repo \t HEAD_sha \t commit_date`)
- Script reproducible: **`audit/repro/01_clone_inventory.sh`**
- Repos con más volumen de historia (ramas / etiquetas / commits): `node` 86/515/2834, `protocol-contracts-evm` 21/44/325, `protocol-contracts-solana` 52/14/121, `evm` (fork cosmos/evm de ZetaChain) 31/17/330, `tss-lib` 28/9/466, `go-tss` 36/10/568.

### 1.2 HEADs de los repos que sostienen el veredicto

| repo | HEAD | fecha |
|---|---|---|
| `node` | `4de91237f68c007a7d21a97f336910ff0b633828` | 2026-11-04 |
| `protocol-contracts-evm` | `eeb2c85a2408` | 2026-11-04 |
| `protocol-contracts-solana` | `0ee7e4382729` (tag `v7.0.1`) | 2026-07-01 |
| `protocol-contracts-sui` | `421b94e8ac4f` (tag `v3.0.1`) | 2026-07-01 |
| `protocol-contracts-ton` | `19cac2e7b324` (tag `v2.0.0` = `d1cfd69a057c`) | 2025-10-20 |
| `evm` (fork cosmos/evm) | `fed5d3256589` | 2025-10-22 |
| `tss-lib` | `637906ded5ac` | 2026-04-22 |
| `go-tss` | `a0868abcf0b0` | 2025-10-17 |
| `network-config` | `34efb4b30cb0` | 2026-09-17 |
| `contract-addresses` | `b96bd82eed8c` | 2025-10-23 |

(El listado completo, los 76, está en `CLONE_INVENTORY.tsv`.)

### 1.3 Repositorios bloqueados / no cubiertos

**Ninguno bloqueado por permisos.** Limitaciones reales de cobertura, declaradas:

1. **Estado on-chain en vivo: BLOQUEADO.** No hay salida de red a RPC/explorer (todos los `curl` a blockpi, blockscout, allthatnode, `rpc.zetachain.com`, `eth.llamarpc` y al propio nodo de `network-config` `http://35.224.53.42:26657` devuelven HTTP `000`). Solo `api.github.com` responde. ⇒ **no se pudo leer el slot EIP-1967 de ninguna proxy, ni bytecode desplegado, ni saldos.** Todo el mapeo dirección→commit se hizo contra los artefactos de despliegue (`broadcast/*/run-latest.json`) y los ficheros `data/checksum/*.json` del repo, no contra la cadena.
2. **`network-mainnet`** está deprecado y solo apunta a `network-config` (clonado aparte).
3. **Repos de terceros** (OpenZeppelin, cosmos-sdk upstream, librerías Rust de Solana) son dependencias, no código de la fundación; se auditó el fork propio (`evm`) y las versiones pinneadas en cada `go.mod`.

### 1.4 Cómo se ancla cada dirección viva a un commit

El repo publica la dirección de implementación por cadena en `data/checksum/mainnet.json` / `testnet.json`, y el *run* de Foundry que la produjo en `broadcast/Deploy*Implementation.s.sol/<chainId>/run-latest.json` (incluye el `input` de la tx CREATE2 = bytecode de creación completo, y el campo `commit`). Verificación usada: buscar en ese bytecode los selectores `PUSH4` de las funciones/errores relevantes, calculados con keccak (no “a ojo”).

```
ArbitraryCallDisabled()      = 69b675aa
ArbitraryCallNotSupported()  = 35bb6796
depositPaused()              = 02befd24
execute((address),address,bytes)                        = 38e22527
executeWithERC20((address),address,address,uint256,bytes)= 7bbe9afa
call(bytes,address,bytes,(uint256,bool),(...))          = 06cb8983   [GatewayZEVM v14]
withdrawAndCall(...)                                    = 7b15118b   [GatewayZEVM v14]
deposit(address,uint256,address)                        = f45346dc
```

**Cadena reproducida (mainnet, eth chainId 1):**

| artefacto | dirección | commit del run | ¿en el repo? |
|---|---|---|---|
| GatewayEVM impl (2025-01) | `0x6dac3343…ef0d` | `42211e0` | **no** (squash) |
| GatewayEVM impl (2025-07) | `0x8bb9ec4a…3AE0` | `3179071` | sí |
| **GatewayEVM impl (2025-08-26)** | **`0x9ef630ab803fe9a7f46214242731298ee7025794`** | **`55c1146`** | **sí** |
| GatewayEVM impl (2025-11) | `0x1fff55cc…572e` | `e2108b4` | sí |
| GatewayEVM impl (2026-04-30) | `0xb8afbcaf…07c5` | `619af80` | **no** |
| GatewayEVM impl (checksum actual) | `0x9D7aD582…fa52` | — | **sin broadcast** |
| **GatewayZEVM impl (mainnet)** | **`0xef195bf421658ea31dba4cbf598af7f9d8791202`** | **`55c1146`** | **sí** |
| GatewayZEVM impl (checksum actual) | `0x38Bfe581…220d` | `619af80` | **no** |

Selectores verificados por bytecode:

- `0x9ef630ab…` → `execute()` ✓, `executeWithERC20()` ✓, **`ArbitraryCallDisabled` ✗** ⇒ **conserva la rama de llamada arbitraria**.
- `0xef195bf4…` (GatewayZEVM vivo) → `call()` ✓, `withdrawAndCall()` ✓, `ArbitraryCallNotSupported` ✗ ⇒ **expone el disparador público `call()`**.
- `0x38bfe581…` (checksum actual) → `call()` ✗, `withdrawAndCall()` ✓ ⇒ ya sin `call()`.

Direcciones de sistema en zEVM (chain 7000), consistentes entre `contract-addresses`, `protocol-contracts-evm` y el nodo: `GatewayZEVM 0xfEDD7A6e…0F44E`, `FungibleModule 0x735b14BB…26aB` (= `PROTOCOL_ADDRESS` en `GatewayZEVM.sol:36`), `SystemContract 0x91d18e54…3921`, `CoreRegistry 0x7cce3eb0…0394`, `ZETA 0x5F0b1a82…a8bf`. 25 cadenas, 62 ZRC20 listados.

---

## 2. Superficie revisada (resumen)

- **Consenso/mempool/ante:** `app/ante/ante.go` (`IsSystemTx`, `unwrapMsgExec`, `CheckSystemTxAuthorization`), `x/observer/keeper/voting.go`, autorización por mensaje de todos los `msg_server_*.go` de `x/crosschain`, `x/fungible`, `x/observer`, `x/emissions`.
- **Puente / hooks EVM:** `x/crosschain/keeper/{evm_hooks,v2_zevm_inbound,cctx_orchestrator_validate_inbound,msg_server_vote_outbound,msg_server_refund_aborted_tx,abort,gas_payment}.go`, `x/crosschain/types/{inbound_parsing,cctx,message_vote_inbound}.go`, `pkg/coin`.
- **Fungible/ZRC20:** `x/fungible/keeper/{deposit,abort,revert,zrc20_methods,zrc20_cosmos_coins_mapping,gas_stability_pool}.go` (caps de liquidez, pausas, `LockZRC20`/`UnlockZRC20`).
- **VM/stateDB:** fork `zeta-chain/evm`, cadena de hardening `515bbca4` → `a8c9422` → `016633d` → `38f0c61` → `3e5f8e5` → `198da04`/`a69d910` → `237ce27` → `51190f0`; `x/vm/keeper/statedb.go`, `x/vm/statedb/{state_object,statedb}.go`, `precompiles/common/balance_handler.go`.
- **Contratos:** `GatewayEVM`, `GatewayZEVM`, `ZetaConnector{Base,Native,NonNative}`, `ERC20Custody`, `Registry`/`CoreRegistry`, `ZRC20`, `SystemContract`, `GatewayZEVMValidations` en `v14.0.0`, `v14.0.1`, `v14.1.0`, `v15.0.0`, `develop`, `origin/main`.
- **Solana/TON/Sui:** `programs/gateway/src/{lib,contexts,instructions/*,utils/*}.rs` (`v5.0.0`→`v7.0.1`), `contracts/gateway.fc` (`v2.0.0`), `contracts/gateway/sources/gateway.move` (`v1`→`v3.0.1`).
- **Drain/infra:** `pkg/draintx`, `cmd/zetaclientd/drain_on.go`, `zetaclient/drain/*`, `docs/rfc/002_tss_emergency_drain.md`.

---

## 3. Candidato fuerte (no crítico): bypass de firma de *arbitrary call*

### 3.1 El mecanismo, en tres piezas verificadas

**(1) Disparador sin permisos, en zEVM.** `GatewayZEVM.call(receiver, zrc20, message, callOptions, revertOptions)` es `external whenNotPaused` — sin roles (`v14.0.1:contracts/zevm/GatewayZEVM.sol:333`). Cobra la fee de gas en ZRC20 (`_burnProtocolFees`) y emite `Called(msg.sender, zrc20, receiver, message, callOptions, revertOptions)` con el `callOptions` que el usuario eligió.

**(2) El nodo propaga el flag al CCTX.** `x/crosschain/keeper/evm_hooks.go:ProcessLogs → ProcessZEVMInboundV2` parsea `Called` como `coin.CoinType_NoAssetCall` (`v2_zevm_inbound.go:79`) y `types.NewCallInbound` copia `event.CallOptions.IsArbitraryCall` a `MsgVoteInbound` (`inbound_parsing.go:192`), que acaba en `OutboundParams.CallOptions.IsArbitraryCall` (`cctx.go:327`). No hay ninguna validación que lo prohíba en `validateOutbound` (`evm_hooks.go:341`), que solo comprueba dust BTC / rent-exempt Solana / formato de dirección Sui.

**(3) El firmante borra el remitente.** `zetaclient/chains/evm/signer/outbound_data.go:164`:

```go
if o.callOptions.IsArbitraryCall {
    messageContext.Sender = ethcommon.Address{}
}
```

`v2_signer.go` enruta `OutboundTypeCall` y `OutboundTypeGasWithdrawAndCall` a `signGatewayExecute`, que empaqueta `gatewayABI.Pack("execute", messageContext, txData.to, txData.message)` y lo firma con la clave TSS.

**(4) El contrato obedece.** `GatewayEVM.execute` (`v14.0.1:131`) con `messageContext.sender == address(0)` va a `_executeArbitraryCall(destination, data)` → `destination.call{value: msg.value}(data)`, es decir: **`msg.sender` = dirección del Gateway**. El bytecode desplegado `0x9ef630ab…` contiene `execute()` y **no** contiene `ArbitraryCallDisabled()`, confirmando que esa rama está viva en la implementación mainnet de 2025-08-26.

Resultado: un atacante sin permisos consigue que **contratos de terceros vean al GatewayEVM como `msg.sender`**, con datos arbitrarios, gastando solo gas + la fee de protocolo.

### 3.2 Estado de los parches (frontera exacta)

- **Contratos:** la eliminación vive en `de1acfe` ("refactor: disable arbitrary calls", PR #633, **mergeado a `main` 2026-05-18**, deploy `0xb8afbcaf…` **el 2026-04-30 en Ethereum** según el `receipt` del broadcast). `b184c3b` (#636, 2026-05-22) añade además pausa de depósitos con allowlist. **Pero:** el repo de contratos usa `develop` como rama por defecto y `de1acfe`/`b184c3b` **no son ancestros de `develop`**; `develop` sigue con `sender==0x0 → _executeArbitraryCall`. Y **la implementación que el propio repo declara como desplegada hoy (`0x9D7aD582…`) no tiene broadcast** → su procedencia no es verificable offline.
- **Cliente:** el guard (cancelar con `SignCancel`, auto-transferencia TSS de valor 0) existe **solo** en `v38.0.3+`, `v37.0.11+` y `zetaclient_v37.0.12+` (commits `890662c1` #4576 backport v37, `10cd8b47` #4580 v38). **No existe** en: `main` (`4de91237`), `origin/release/v36`, `v36.0.0…v36.1.5`, `v37.0.9`, `v38.0.1`, `v38.0.2`, `zetaclient_v37.0.10`. `VERSIONS.md` declara **mainnet = ZetaClient v36** ⇒ el firmante vivo no cancela.
- **Rama no mergeada** `origin/fix/disable-arbitrary-call-v38` (base `9f861643`) sigue abierta; en `main` no hay ningún commit de corrección desde 2026-06-01 salvo `6c180ccd`.

Verificación ejecutable: **`audit/repro/02_arbitrary_call_lever.sh`** (imprime las tablas de §1.4 y §3.2 desde los clones).

### 3.3 **Por qué NO es crítico** (el hecho que lo mata)

**(a) Criterio 4 — no se obtiene valor de terceros.** `GatewayEVM` **no custodia fondos ni mantiene allowances** (`GatewayEVM.sol:28`: *"The contract doesn't hold any funds and should never have active allowances"*), y la llamada arbitraria viaja con `msg.value = 0` en el caso `NoAssetCall`, o con el importe que el propio atacante acaba de retirar (quemando sus ZRC20) en `WithdrawAndCall`. La `approve` transitoria de `executeWithERC20` se concede a `to` y el propio Gateway es quien la consume: no hay allowance extra que robar. Para monetizar el bypass hace falta un **contrato de terceros que confíe en `msg.sender == gateway` y custodie valor**; sin RPC ni explorer no se pudo enumerar ni verificar ninguno, y **no se presenta un objetivo concreto con saldo** ⇒ no hay PnL ≥ 0 demostrable, y el enunciado prohíbe explícitamente el escenario hipotético.

**(b) Criterio 3 — el eslabón on-chain puede estar cerrado hoy.** La implementación de GatewayEVM que el repo declara activa (`0x9D7aD582…`, linaje `de1acfe`/`b184c3b`) **revierta con `ArbitraryCallDisabled()`**. Si es la desplegada, el `CCTX` aborta y los fondos se devuelven: la llamada arbitraria nunca se ejecuta. No se pudo leer el slot EIP-1967 en vivo para confirmarlo (red bloqueada), y el bytecode de `0x9D7aD582…` no está en ningún `broadcast` del repo. Las direcciones reproducibles (`0x9ef630ab…` sin guard, `0xb8afbcaf…` con guard) apuntan a que la ventana existió entre 2025-08-26 y el 2026-04-30, no necesariamente ahora.

**(c)** El patrón ya es conocido y está tratado por la fundación (PRs #633/#636/#4576/#4580, rama de fix abierta, e2e `test_eth_withdraw_and_arbitrary_call.go`); no se aporta explotación nueva, lo que la regla del encargo excluye.

**Severidad asignada:** Alta (defensa en profundidad incompleta: el cliente mainnet v36 no tiene el guard, `develop` de contratos conserva la rama, y la procedencia de la implementación viva no es verificable desde el repo). **No crítico.**

---

## 4bis. Segunda pasada (ronda de búsqueda intensiva)

Tras el primer informe se re-auditaron vectores no cubiertos. **Todo descartado**, con el motivo concreto:

| Vector nuevo revisado | Dónde | Por qué no es crítico |
|---|---|---|
| **Falsificación de depósitos EVM** (¿el observador confía en la dirección del emisor?) | `zetaclient/chains/evm/observer/inbound.go:257-272`, `v2_inbound.go:136` | `fetchLogs` filtra por `Addresses: {gateway, erc20Custody, connector}` **y** cada parser llama `common.ValidateEvmTxLog(&log, addrEsperada, "", topic)` (comprueba `log.Address` + topic0). Un evento `Deposited` de un contrato impostor se descarta. **Cerrado.** |
| **Acuñación vía `ZRC20.deposit()`** (la única función que acuña, llamable por `SYSTEM_CONTRACT_ADDRESS` y `gatewayAddress`) | `ZRC20.sol:249-256`, `SystemContract.sol:76-92`, `GatewayZEVM.sol:473-495` | `SystemContract.depositAndCall` es `onlyFungible`; `GatewayZEVM.deposit/depositAndCall` son `onlyProtocol` y `validateTarget` prohíbe `PROTOCOL_ADDRESS` y el propio Gateway. El módulo fungible sólo los invoca desde `HandleEVMDeposit` con `amount` = importe observado. **No hay acuñación sin depósito.** |
| **Contabilidad ZETA (`AbortedZetaAmount`)** | `x/crosschain/keeper/{cctx,zeta_accounting,msg_server_refund_aborted_tx}.go` | `updateZetaAccounting` es **acumulador puro**: no se consulta como invariante en ningún punto que bloquee movimientos, y `RemoveZetaAbortedAmount` sólo lo decrementa en el refund autorizado. No habilita acuñación ni doble gasto. **Inerte.** |
| **Bug del rate limiter TSS** (`be79663d`, "ratelimiting race condition vuln", 2025-08-08) — **no está en `v36.0.6`** | `zetaclient/tss/ratelimit/ratelimit.go` | Es un contador de concurrencia local del zetaclient (`pending`/semáforo) para limitar claves TSS en paralelo; el propio PR admite que los tests pasan sin el fix ("improving robustness rather than fixing vulnerabilities"). No da acceso a firmas ni a fondos. **No explotable como robo.** |
| **`ZCNode-228` / Alpha-Rays / TSSHOCK** (rama `chore/verify-zcnode228-attack-script`, script `e2e/scripts/verify_zcnode228.go`) | `tss-lib` `crypto/mta/proofs.go`, commit `a4af30e`/`9a516a34` | Atacar MtA exige **ser participante del keygen/firma TSS** (nodo de la red o colusión con nodos) ⇒ camino privilegiado, excluido por el encargo. Nota de estado: mainnet v36.0.5 y anteriores pinnean `tss-lib 2e6b438bd901` (2024-09, **sin** el endurecimiento); `v36.0.6` y `zetaclient_v37.0.12+` sí lo llevan. |
| **Replay de firmas TSS en el Gateway de Solana** (hash de mensaje sin campos) | `protocol-contracts-solana` `v5.0.0` `validate_message_hash.rs`, `instructions/execute.rs` | El hash **sí** incluye `program_id || instruction_id || chain_id || nonce || amount || destination_program || destination_program_pda || sender || data`, y `verify_and_update_nonce` incrementa el nonce on-chain ⇒ no hay replay. `v7` añade `remaining_accounts` al hash (endurecimiento, no agujero vivo). |
| **`refundStrandedFunds` en `ERC20Custody`** (commit más reciente de main, 2026-11-03) | `68e25bf` | `onlyRole(DEFAULT_ADMIN_ROLE)` ⇒ privilegiado. Descartado por regla explícita. |
| **Validación de eventos ZRC20/V1 en el nodo** | `x/crosschain/keeper/evm_hooks.go:76-240`, `ParseZRC20WithdrawalEvent` | El nombre de ZRC20 está whitelisteado, pero `ParseZRC20WithdrawalEvent` **no comprueba `log.Address` contra la dirección del ZRC20**; se apoya en `ProcessLogs`, que sí filtra por emisor (`onlyEmitBySystemContract`/`emittingAddress` del SystemContract). Defensa en un solo punto, no hallazgo explotable por sí mismo. |
| **Refund/abort y logs anidados** (`ProcessLogs` dentro de `HandleEVMDeposit`/`ProcessAbort`) | `evm_deposit.go:145-160`, `abort.go:63-100` | Los CCTX anidados se crean en `tmpCtx` y sólo se confirman si todo el camino tiene éxito; un fallo revierte y no persiste. Sin acumulación de saldo a favor del atacante. |
| **Buffer de eventos (`prevEventsLen`) en precompiles** | `precompiles/common/balance_handler.go` | Los cambios de saldo se derivan de eventos bancarios reales del mismo `ctx`; falsificar un evento exigiría ejecutar transferencias reales. |

## 4. Otras líneas revisadas y descartadas (con el motivo)

| Línea | Estado | Motivo de descarte |
|---|---|---|
| **GHSA Aug-2026 stateDB** (underflow en `stateObject.SubBalance` → `SetBalance` reconcilia y **acuña** vía `bankWrapper.MintAmountToAccount`) | Real en `515bbca4` / `f0addce1` (sin comprobación); corregido en `3e5f8e5` (panic por underflow/overflow) y en `016633d`/`198da04` | **Ya parcheado en v36.0.6** (`go.mod` pin `3e5f8e5337fa`), que es la release v36 más reciente (2026-09-03, no prerelease). Problema conocido + sin exploit nuevo. Hito relevante: `ea7aa719`/`dd94ab2f` re-anclan el pin al commit **desplegado** (`3e5f8e5`) en vez del tip mergeado, precisamente porque `51190f0` cambia la rama de decisión para cuentas de módulo no bloqueadas ⇒ riesgo de divergencia de consenso, no de robo. |
| **Acuñación vía cuentas de módulo** (`x/fungible` `0x735b…26aB` no está en el set blockeado) | Gate en `SetBalanceWithLocked` desde `3e5f8e5` | Con el pin desplegado el gate existe (delta ≠ 0 + módulo ⇒ `ErrUnauthorized`). En `3e5f8e5` la comprobación es “módulo”, en `51190f0` es “blocked-receive”: divergencia de consenso, no de valor. |
| **`GatewayZEVM.call()` en zEVM mainnet (`0xef195bf4…`)** | Presente | Es el disparador del candidato §3; por sí solo no mueve fondos. |
| **`withdraw`/`withdrawAndCall` con `isArbitraryCall: true` fijado por el contrato** | Presente en `v14`/`v15` | En `withdraw` sin mensaje, `IsCrossChainCall=false` ⇒ outbound `GasWithdraw` (transferencia simple del importe quemado), no `execute`. En `withdrawAndCall` el valor es el del propio atacante. Sin ganancia de terceros. |
| **`MsgUpdateParams` de `x/emissions`** (`msg.Authority != k.authority`, sin `CheckAuthorization`) | Real, pero el firmante requerido es la authority (`GetSigners()` devuelve `m.Authority`) | Camino privilegiado (gov); `ante` exige firma de esa cuenta. Prohibido como crítico por el encargo. |
| **Authz/`MsgExec` para `IsSystemTx`** | Corregido en `b653f96f` (#4548): comprueba que `MsgExec.Grantee` sea el hotkey del observer y rechaza anidamiento | El bypass previo exigía ser observer autorizado ⇒ privilegiado. |
| **Refunds / abort** | `MsgRefundAbortedCCTX` exige autoridad + `Status_Aborted` + `!IsAbortRefunded`; `getAndCheckZRC20` aplica `Paused` y `LiquidityCap`; refund de gas 95 % | Sin camino sin permisos hacia fondos ajenos. |
| **Solana Gateway** | `verify_authority` compara el firmante con `pda.authority`; `validate_message` encadena nonce+hash+firma TSS (secp256k1 recover contra `pda.tss_address`); `prepare_account_metas` excluye al signer; `handle_spl` verifica ATA y `transfer_checked` con seeds del PDA | Todos los caminos de retirada/refund son `authority`-only. Sin hallazgo. |
| **Sui Gateway** | `withdraw_impl<T>` exige `WithdrawCap` activo + `nonce == gateway.nonce` (anti-replay) + vault whitelisted; `refund_impl` exige `AdminCap` | Capabilities, no direcciones. Sin hallazgo. |
| **TON Gateway (FunC)** | `op::external::withdraw/increase_seqno` sólo desde el `tss_address`; ops de autoridad con `guard_authority_sender`; `handle_call` sólo cobra fee | Sin hallazgo. |
| **Registry/CoreRegistry** | `onCall` = `onlyRole(GATEWAY_ROLE)` **+** `context.sender == coreRegistry`; el resto de escrituras son `onlyRegistry` (auto-llamada) y `_revertIfOnCallOrOnRevert` bloquea los selectores `onCall`/`onRevert` desde el camino arbitrario | Corta el encadenado del §3 hacia el registro. |
| **ERC20Custody** | `withdraw*` = `WITHDRAWER_ROLE` (TSS); `refundStrandedFunds` = `DEFAULT_ADMIN_ROLE`; `deposit` legacy exige `supportsLegacy` y token whitelisted | Todo privilegiado. |

---

## 5. Reproducción

```bash
# 1) prerrequisito (enumera + clona los 76 repos y registra HEADs)
./audit/repro/01_clone_inventory.sh /tmp/zeta

# 2) verificación del candidato §3 (contratos + cliente + pines del fork evm)
./audit/repro/02_arbitrary_call_lever.sh /tmp/zeta

# 3) comprobaciones sueltas usadas en el informe
cd /tmp/zeta/protocol-contracts-evm
git show 55c1146:broadcast/DeployGatewayZEVMImplementation.s.sol/7000/run-latest.json \
  | python3 -c 'import sys,json;d=json.load(sys.stdin);i=d["transactions"][0]["transaction"]["input"].lower();print("call():",i.count("63"+ "06cb8983"))'
git show 55c1146:broadcast/DeployGatewayEVMImplementation.s.sol/1/run-latest.json \
  | python3 -c 'import sys,json;d=json.load(sys.stdin);i=d["transactions"][0]["transaction"]["input"].lower();print("execute:",i.count("6338e22527"),"ArbCallDisabled:",i.count("6369b675aa"))'

cd /tmp/zeta/node
for t in v36.0.6 v38.0.2 v38.0.3 zetaclient_v37.0.12; do
  echo -n "$t guard="; git show $t:zetaclient/chains/evm/signer/v2_signer.go | grep -c 'IsArbitraryCallCancellable'
done
for t in v36.0.4 v36.0.6; do
  echo -n "$t evm-pin="; git show $t:go.mod | grep 'zeta-chain/evm ' | awk '{print $NF}'; done
```

**Estado on-chain:** no reproducible en este entorno (§1.3). Para cerrar el criterio 3 bastaría, con acceso a RPC, `eth_getStorageAt(GatewayEVM, 0x360894…bbc)` en Ethereum/BNB/Polygon/Base/Arbitrum/Avalanche y comparar con `0x9D7aD582…` (con guard) vs `0x9ef630ab…` (sin guard).

---

## 6. Conclusión

**No crítico live (confirmado en dos rondas).** El único bypass de autorización real y sin permisos encontrado —la ruta `GatewayZEVM.call()` → CCTX `NoAssetCall` con `IsArbitraryCall` → `MessageContext{Sender: 0x0}` firmado por zetaclient v36 → `GatewayEVM._executeArbitraryCall`— está confirmado en código y en bytecode desplegado, pero **no permite apropiarse de fondos de terceros** (el Gateway no custodia ni mantiene allowances, y el importe de la llamada es del atacante) y, además, el contrato que el repo declara activo hoy revierte esa ruta. Queda como **hallazgo de severidad alta por defensa en profundidad** con tres deudas abiertas verificables: (i) ZetaClient mainnet v36 sin el guard de cancelación; (ii) `develop` de `protocol-contracts-evm` conservando la rama arbitraria mientras `main` la elimina; (iii) implementaciones vivas (`0x9D7aD582…`, `0x38Bfe581…`, `0xb8afbcaf…`) sin artefacto de despliegue reproducible en el repo, lo que impide atribuirlas a un commit.


---

## 7. Nota sobre la segunda ronda

La búsqueda se amplió con los vectores de §4bis: origen de logs del observador (EVM, BTC, Solana, Sui, TON), acuñación vía `ZRC20.deposit`/`SystemContract`, contabilidad `AbortedZetaAmount`, rate limiter TSS (`be79663d`, ausente en v36.0.6), MtA/TSSHOCK, replay de firmas en Solana, `refundStrandedFunds` y los logs anidados de abort/refund. **Ninguno produce fondos de terceros sin privilegios.** El veredicto se mantiene: **no crítico live**, con el bypass de arbitrary-call como el hallazgo real de mayor severidad (alta, defensa en profundidad).
