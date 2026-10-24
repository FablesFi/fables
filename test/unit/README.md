# unit

Unit and property tests per component.

- `core/`: FablesHookCore and the ledger mixins wiring.
- `builds/`: the four FablesHook builds (flag words, Exclusive gate, native ETH gate).
- `engine/`: FablesFeeEngine, FeeRef, PoolWordLib, DiscountLib.
- `full/`: the assembly swap entry (swaps on the Robinhood Chain bytecode, properties, branch coverage).
- `ledger/`: FablesLedgerV2 / LedgerLibV2 edges, dust, module isolation and the JIT seam.
- `stable/`: FablesStableFee and both Stable Lite builds (flags, liquidity gate, outside LPs next to the ledger, parked
  prices).

```
forge test --match-path "test/unit/**"
```
