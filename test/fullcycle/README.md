# fullcycle

End-to-end lifecycles on the Robinhood Chain v4 bytecode with AccessManager role bindings and an ADMIN behind a
1-day delay: configure, initialize, deposits, swaps, pokes, discounts, continuation fee, staking, claims, sweeps,
pause and exits, with fee conservation checked at the end. One run per build; FablesStableHookLite runs next to an
outside LP.

```
forge test --match-path "test/fullcycle/**"
```
