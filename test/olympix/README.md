# olympix

Skeletons for Olympix unit-test generation. Each `<Contract>.t.sol` targets one contract (named in
`OlympixUnitTest("<Contract>")`) and has a `setUp()` that deploys it as the other suites do:

- `OlympixHookFixture`: a FablesHook build with a live pool, the ledger wired to a distributor and ballot gate, two LPs
  (one staked) and a swap each way. Used by the four FablesHook builds, `FablesLedgerV2` and `FablesFeeEngine`.
- `OlympixStableFixture`: a Stable Lite build with a stable pool at its reference and ledger liquidity. Used by both
  Stable Lite builds and `FablesStableFee`.

```
forge test --match-path "test/olympix/**"
```
