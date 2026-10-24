# Fables

Fables is a market-aware ve(3,3) decentralized exchange built on Uniswap v4, live on Robinhood Chain (chain id 4663).

This repository holds its Uniswap v4 hooks. Each hook prices swaps with a dynamic fee and holds an LP ledger: LPs deposit
through the hook, receive ERC-6909 receipts 1:1 with liquidity, and can stake them for gauge emissions. One hook serves many
pools.

## Contracts

| Build | Hook flags | What it does |
|---|---|---|
| `FablesHook` | `beforeInitialize`, `beforeSwap` (0x2080) | Fee per swap direction, set within admin bounds; optional sender discounts and continuation fee. ERC-20 pools. |
| `FablesHookETH` | 0x2080 | `FablesHook` that also serves pools whose currency0 is native ETH. |
| `FablesHookExclusive` | + `beforeAddLiquidity` (0x2880) | `FablesHook` where liquidity can only be added through the ledger. |
| `FablesHookETHExclusive` | 0x2880 | Both of the above. |
| `FablesStableHookLite` | 0x2080 | Uniswap StablePair fee around a reference price. |
| `FablesStableHookLiteExclusive` | 0x2880 | `FablesStableHookLite` where liquidity can only be added through the ledger. |

No hook uses return-delta flags, remove-liquidity or donate callbacks, or `hookData`.

`FF` in function and event names (`setFFFeeSink`, `ffFeeSink`, `distributorFF`, `FFFeeSinkSet`) refers to the FABLES token.

```
src/
  FablesHook*.sol, FablesStableHookLite*.sol  deployable builds
  base/FablesHookCore.sol                     PoolManager handle, configured-pool marker
  base/FablesFeeEngine.sol                    fee categories, pool config, pokes, discounts, continuation fee
  base/FablesFeeFull.sol                      assembly beforeSwap entry
  base/FablesStableFee.sol                    StablePair fee state and config
  base/FablesLedgerV2.sol, LedgerTypesV2.sol  LP ledger (ERC-6909 receipts, staking, fee accounting, claim fee)
  base/FablesNativeETHV2.sol                  native-ETH support
  base/FablesExclusiveLiquidityV2.sol         ledger-only liquidity gate
  libraries/PoolWordLib.sol, FeeRef.sol       packed pool word; reference fee resolution (the assembly must match it)
  libraries/DiscountLib.sol                   discount entries and Bloom pre-filter
  libraries/LedgerLibV2.sol                   ledger accounting and unlock callbacks
  libraries/StableFeeCalculation.sol          Uniswap StablePair fee math (verbatim, MIT)
  vendor/solady/                              Solady FixedPointMathLib (verbatim, MIT)
```

## Roles

Access control is an OpenZeppelin `AccessManager`. Hooks are immutable (no proxy, no upgrade).

| Role | Can | Cannot |
|---|---|---|
| ADMIN | configure pools and fee bands, set sinks and the claim fee, grant roles | move LP principal, set a fee above 10%, un-configure a pool |
| FEE_POKER | move each side's fee within [max(floor, 50% of base), min(pool cap, category cap)] for at most 72 h, raising at most one step per 60 s; turn the continuation fee on or off | leave those bounds |
| PAUSER | pause deposits, claims, stakes, transfers and revenue sweeps for up to 7 days per call; clear pokes; switch off the continuation fee; revoke discounts | pause `withdraw` or `unstake` |
| DISCOUNT_ADMIN | list senders for a discount that never raises a fee or goes below the floor | raise any fee |
| REVENUE_OPS | set the claim fee, at most 20% of LP fees | touch principal |
| SEEDER | initialize a pool the admin has configured (FablesHook builds), at the price it passes | configure pools or change existing ones |

Role-to-function bindings are AccessManager configuration set at deployment; ADMIN can change them.

## Properties

- The LP fee is never above the pool cap and never above 10% (100,000 pips) on any build.
- The fee a swap pays equals what the fee views quote for the same state.
- `withdraw` cannot be blocked by any role, pause or configuration.
- The ledger never owes more than it holds; fees earned before a deposit, stake or transfer cannot be taken by the newcomer.
- Only the hook can initialize its pools; on the Exclusive builds only the ledger can add liquidity.

## Assumptions and known behaviours

- **Trusted:** the Uniswap v4 PoolManager, which holds all funds, and its behaviour as-is (for example its per-tick liquidity
  limits); OpenZeppelin; Robinhood Chain; the chain's protocol-fee controller, which may add up to 0.1% per side on top of the LP fee.
- **Token issuers:** a withdrawal or claim pays both tokens of a pool in one transaction. While an issuer pauses a token, exits
  that move a non-zero amount of it wait until it is unpaused.
- **Unsupported tokens:** fee-on-transfer, rebasing, and tokens whose supply can exceed 2^127 units.
- **Unlocks:** every ledger function opens its own PoolManager unlock; call it directly, not from inside another unlock.
- **Direct liquidity** (`FablesHook`, `FablesHookETH`, `FablesStableHookLite`): anyone can also add liquidity directly through the
  PoolManager. Those positions share swap fees pro rata (including just-in-time liquidity), get no receipts, pay no claim fee and
  are not stopped by a pause.
- **Continuation fee:** a soft surcharge that a trader can avoid by first trading back. Its memory ends after 255 s, so a fade
  time above 51 s stops abruptly instead of fading out.
- **Discounts** are keyed on the PoolManager caller (the router) and are not visible to quoters.
- **Claim fee:** charged at the lowest rate in force since a range's last sync.
- **Stable fee** (Uniswap's StablePair design): each pool has a fixed reference price, and swaps that move the price away from it
  pay less than swaps that move it back. Inside the pool's optimal band both pay a small fee. Outside it, swaps away pay 0 and
  swaps back pay a fee that starts high and falls every block. Our changes: the fee is capped at 10%, and a price more than 10%
  from the reference is treated as exactly 10% away.
- **LP receipts (ERC-6909):** a transfer of 0 reverts; staked receipts must be unstaked before they move (transferable =
  `balanceOf - userPosition(...).staked`); transfers stop during a pause and during any ledger call (for example inside a native-ETH refund), approvals do
  not; a transfer to `address(0)` succeeds and those shares can no longer be withdrawn.

## Build and test

Tests live in `test/` (one README per folder): `unit`, `invariant`, `differential` (assembly entry vs its Solidity twin;
stable fee vs Uniswap's StablePair), `regression`, `fullcycle`, `gas`, `fork` (Robinhood Chain), `halmos` (run with halmos) and `external` (OpenZeppelin
uniswap-hooks invariants and an ERC-6909 conformance suite, adapted).

```bash
git submodule update --init --recursive
forge build
forge test
# Robinhood Chain fork tests (skipped unless set; the pinned block needs an archive node,
# otherwise add RC_FORK_BLOCK=<recent block>):
RC_RPC_URL=<url> forge test --match-path "test/fork/**" --isolate -vv
```

Compiler: solc 0.8.26, EVM cancun, optimizer 200 runs, `bytecode_hash = "none"`.

## License

BUSL-1.1 (see `LICENSE`), converting to GPL-2.0-or-later on 2028-10-24. Code derived from third-party MIT sources stays MIT:
`src/libraries/StableFeeCalculation.sol` and `src/base/FablesStableFee.sol` (Uniswap StablePair), `src/vendor/` (Solady), and test
files marked MIT (see `licenses/MIT_LICENSE`).

## Status and security

Not yet externally audited. Report security issues privately to security@fables.fi.
