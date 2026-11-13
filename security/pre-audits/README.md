# Pre-audits

| Date | Type | Commit scanned | Report |
|---|---|---|---|
| 2026-10-29 | Olympix BugPoCer (automated) | `0f59859` | [2026-10-29-olympix-bugpocer-0f59859.pdf](2026-10-29-olympix-bugpocer-0f59859.pdf) |
| 2026-11-02 | Olympix BugPoCer (automated), diff scan after the fixes above | `b430a02` | [2026-11-02-olympix-bugpocer-b430a02.pdf](2026-11-02-olympix-bugpocer-b430a02.pdf) |
| 2026-11-11 | Olympix invariant prover (halmos, automated) | `8595947` (branch `olympix`; `src/` = `161769a`) | [2026-11-11-olympix-invariant-prover-8595947.pdf](2026-11-11-olympix-invariant-prover-8595947.pdf) |
| 2026-11-11 | Olympix BugScout (automated) | `8595947` (branch `olympix`; `src/` = `161769a`) | [2026-11-11-olympix-bugscout-8595947.pdf](2026-11-11-olympix-bugscout-8595947.pdf) |

## 2026-10-29 Olympix BugPoCer: resolution

| Finding | Severity | Status | Change | Tests |
|---|---|---|---|---|
| 5.1.1 a: fee-window clamp suppresses the movement adjustment | Medium | Fixed | `FablesStableFee`: the formula reads and stores the real price, as StablePair; once the price ratio to the reference is below 0.9 only the decay target is floored, at its value at 0.9 (`_targetFee`) | `test/regression/StableWindowFloor.t.sol`, `test/differential/StableLiteDiffWords.t.sol`, `test/differential/StableLiteVsStablePair.t.sol`, `test/invariant/StableFeeEdgesFuzz.t.sol` |
| 5.1.1 b: fee-window clamp lowers the decay target | Low | Fixed | same change: the floor only ever raises the target | same |
| 5.1.2: manipulable spot anchor | Medium | Fixed | `FablesFeeEngine.setCFActive(poolId, on, minTick, maxTick, deadline)`: switching on requires the current tick inside `[minTick, maxTick]`, no later than `deadline` | `test/regression/CFSwitchOnBounds.t.sol` |

## 2026-11-02 Olympix BugPoCer: resolution

Six Low findings, all "Needs Further Review" (none with a proof of concept). No code change; one comment reworded.

| Finding | Severity | Status | Why | Tests |
|---|---|---|---|---|
| 5.1.1: anchor update samples a held tick | Low | By design | The continuation fee only adds to the fee (at most `cfCap`, 25 bp, and the pool cap). Its anchor fades toward the tick with time `tau`, so moving it means holding a price that anyone can trade back | `test/halmos/HalmosFeeLibs.t.sol` (`cfStep` <= `cfCap`, decay <= 1) |
| 5.1.2: per-block cached price | Low | By design (StablePair) | The fee and the price it reads are set at a block's first swap, as in Uniswap's StablePair; the fee is never below StablePair's (capped at 10%) | `test/differential/StableLiteVsStablePair.t.sol` (same-block swaps against the StablePair bytecode) |
| 5.1.3: sandwich around a swap back | Low | By design (StablePair) | Swaps away from the reference pay 0, as in StablePair. Robinhood Chain has no public mempool, and swappers set their own price limits | `test/differential/StableLiteVsStablePair.t.sol` |
| 5.1.4: unbounded initial price | Low | Not an issue | `deposit` caps the principal paid (`amount0Max`, `amount1Max`) and takes a deadline. A swap through an empty pool moves its price at no cost, so a bound on the initial price would protect no one | `test/unit/ledger/LedgerEdges.t.sol` |
| 5.1.5: claim-fee cut and a forced sync | Low | By design; comment reworded | A backlog pays the lowest rate in force since its last sync, which anyone can trigger, so it never pays more than the rate in force while its fees were earned. The `claimFeeFor` comment now says a cut lowers backlogs still unsynced when it lands | `test/unit/ledger/LedgerEdges.t.sol` |
| 5.1.6: sink change and unsynced fees | Low | By design | README, Sinks: fees not yet synced go to the sinks set when they are swept; sinks are rotated after the ranges are synced | |

## 2026-11-11 Olympix invariant prover and BugScout: resolution

BugScout: 0 exploits in 985 generated test cases (reentrancy, unauthorized state writes) on `FablesStableHookLite` and
`FablesStableHookLiteTyped`. No change.

Invariant prover: 78 invariants, 62 passed, 10 passed with low sensitivity, 1 inconclusive, 1 not translated and 4
reported as violated. No change. The 4 "violated" checks are address probes, not checks of the contract: a Uniswap v4
hook must be deployed at an address whose low bits match its permissions, so the generated harness could not deploy
`FablesFeeEngine`, and the probe assertions the tool used to learn its deploy address fail by construction.

| Invariant | Status | Why | Tests |
|---|---|---|---|
| inv_004: only the hook initializes its pools | Not an issue (harness) | The harness did not deploy, so the check ran only its address probe (counterexample `flagbits = 0x04`) | `test/regression/InitializeOnlyFromHook.t.sol` |
| inv_005: the LP fee never exceeds the pool cap or 10% | Not an issue (harness) | The generated test deploys a placeholder contract and asserts its address is 0 | `test/invariant/EngineInvariant.t.sol`, `test/invariant/CategoryInvariant.t.sol`, `test/halmos/HalmosFeeLibs.t.sol` |
| inv_008: continuation fee switch-on only inside the signed tick range and by its deadline | Not an issue (harness) | The generated test asserts a free symbolic value differs from a constant | `test/regression/CFSwitchOnBounds.t.sol` |
| inv_036: category bounds | Not an issue (harness) | The generated test asserts 14 address bits equal 123456 | `test/unit/engine/FablesFeeEngine.t.sol`, `test/invariant/CategoryInvariant.t.sol` |
| inv_033 (inconclusive): stable decay target below the 0.9 window | Covered | Solver budget | `test/regression/StableWindowFloor.t.sol`, `test/differential/StableLiteVsStablePair.t.sol`, `test/invariant/StableFeeEdgesFuzz.t.sol` |
| inv_010 (not translated): continuation fee switch-on bounds | Covered | | `test/regression/CFSwitchOnBounds.t.sol` |
