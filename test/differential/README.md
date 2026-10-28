# differential

- `FullDifferential`: the assembly swap entry against its Solidity twin (`FeeRef`) on any stored words.
- `StableLiteVsStablePair`, `StableLiteDiffWords`: both Stable Lite builds and the typed twin (a Solidity entry on the open
  build) against the deployed Uniswap StablePair bytecode, through real swaps and over arbitrary stored state. On FablesStableHookLite
  part of the liquidity is added directly, in every pool. Reference moves run on both sides (Fables' bounded
  `updateReferencePrice`, StablePair's `updateFeeConfig`); the any-state run expects max(StablePair's fee, minimum fee).
- `StableLiteOpenVsExclusive`: along one price path, FablesStableHookLite with and without outside liquidity and
  FablesStableHookLiteExclusive charge the same fee.

```
forge test --match-path "test/differential/**"
```

`STABLE_DIFF_STATS=true` prints coverage counters for the StablePair differential.
