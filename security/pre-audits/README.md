# Pre-audits

| Date | Type | Commit scanned | Report |
|---|---|---|---|
| 2026-10-29 | Olympix BugPoCer (automated) | `0f59859` | [2026-10-29-olympix-bugpocer-0f59859.pdf](2026-10-29-olympix-bugpocer-0f59859.pdf) |

## 2026-10-29 Olympix BugPoCer: resolution

| Finding | Severity | Status | Change | Tests |
|---|---|---|---|---|
| 5.1.1 a: fee-window clamp suppresses the movement adjustment | Medium | Fixed | `FablesStableFee`: the formula reads and stores the real price, as StablePair; once the price ratio to the reference is below 0.9 only the decay target is floored, at its value at 0.9 (`_targetFee`) | `test/regression/StableWindowFloor.t.sol`, `test/differential/StableLiteDiffWords.t.sol`, `test/differential/StableLiteVsStablePair.t.sol`, `test/invariant/StableFeeEdgesFuzz.t.sol` |
| 5.1.1 b: fee-window clamp lowers the decay target | Low | Fixed | same change: the floor only ever raises the target | same |
| 5.1.2: manipulable spot anchor | Medium | Fixed | `FablesFeeEngine.setCFActive(poolId, on, minTick, maxTick, deadline)`: switching on requires the current tick inside `[minTick, maxTick]`, no later than `deadline` | `test/regression/CFSwitchOnBounds.t.sol` |
