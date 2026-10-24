# external

Third-party test sets, adapted to these hooks. Files with derived code are MIT and name their source.

## oz

From OpenZeppelin Uniswap Hooks v1.3.0 (`test/invariant`, `test/utils/HookTest.sol`, `test/fee/BaseOverrideFee.t.sol`,
`test/base/BaseHook.t.sol`). Run on all six builds.

- `OzHookInvariants`: one campaign per build, one hook carrying two pools that share a currency. The hook never rejects
  a swap or donation the pool accepted; each swap pays the hook's quoted fee (composed with the protocol fee) and the
  stored LP fee stays 0; receipts equal shares equal the ledger's PoolManager position; the hook's claims cover what
  the ledger owes, within rounding, and no token rests in the hook; on Exclusive builds no router adds liquidity. In
  the handler: every ledger sync turns the position's PoolManager fees into hook claims exactly, and swap and
  deposit/withdraw round trips never pay out more than they took.
- `OzOverrideFee`: override fee and protocol share, `updateDynamicLPFee` only by the hook, static-fee keys refused,
  callbacks refuse other callers, only the documented callbacks are live.

Not ported: return deltas and after-swap fees, custom accounting, async swaps, oracles, and the anti-sandwich,
limit-order and hook-fee properties.

## erc6909

ERC-6909 conformance of the LP receipts of a deployed `FablesHook` (minted by `deposit`, burned by `withdraw`), from
Solady v0.1.26 `test/ERC6909.t.sol` and the EIP-6909 MUST rules. Metadata and overflow tests do not apply.
Expected reverts: a transfer of 0, staked receipts, transfers while paused or during a ledger call.

```
forge test --match-path "test/external/**"
```
