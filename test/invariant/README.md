# invariant

Stateful invariant suites and stateless property fuzzers.

- Engine bounds (`EngineInvariant`), ledger accounting and conservation (`LedgerInvariant`,
  `LedgerConservationInvariant`, `LedgerSequenceFuzz`, `LedgerLevelsFuzz`), per-pool isolation.
- Category fuzz: one FablesHook / FablesHookETH carrying five fee-category pools (`CategoryInvariant`), and both
  Stable Lite builds against the StablePair fee model, with an outside LP next to the ledger
  (`StableLiteCategoryInvariant`).
- `FeeRefModelFuzz`, `StableFeeEdgesFuzz`: fee code against independent models.

```
forge test --match-path "test/invariant/**"
FOUNDRY_PROFILE=deep forge test --match-path "test/invariant/**"   # longer runs
```
