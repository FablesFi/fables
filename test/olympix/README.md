# olympix

Skeletons for Olympix unit-test generation. Each `<Contract>.t.sol` targets one contract (named in
`OlympixUnitTest("<Contract>")`) and has a `setUp()` that deploys it as the other suites do:

- `OlympixHookFixture`: a FablesHook build with a live pool, the ledger wired to a distributor and ballot gate, two LPs
  (one staked) and a swap each way. Used by the four FablesHook builds, `FablesLedgerV2` and `FablesFeeEngine`.
- `OlympixStableFixture`: a Stable Lite build with a stable pool at its reference and ledger liquidity. Used by both
  Stable Lite builds and `FablesStableFee`.

`FablesLedgerV2.t.sol` also holds the tests added after Olympix mutation testing: admin-only setters, pause bounds,
sweeps (while paused, paid and reported, silent with nothing owed), one-sided fee payouts, the ledger's events, and
reentry from a native payout (`FablesLedgerV2ReentryOlympixTest`, on FablesHookETH). `LedgerLibV2.t.sol` drives the
ledger library on its own storage (`AccWrapHarness`): fees on a range without shares, per-token staked remainders,
one-sided claim fees and forgone fees. `FablesFeeEngine.t.sol` pins the continuation-fee modes.

```
forge test --match-path "test/olympix/**"
```
