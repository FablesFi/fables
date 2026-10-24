# utils

Shared fixtures and mocks for the suites. No tests here.

- `RCBytecodeHarness.sol`, `RCBytecode.sol`: the Robinhood Chain (4663) PoolManager, Universal Router and Permit2
  runtime bytecode etched at their chain addresses, with pool, liquidity, swap and gas helpers. Each blob's keccak is
  checked on every etch.
- `ForkHelpers.sol`: read-only fork fixture. Reads `RC_RPC_URL`; suites skip when it is unset.
- `BuildsFixture.sol`, `LedgerFixture.sol`, `EngineHarness.sol`, `FullHarness.sol`, `FullTestBase.sol`,
  `StableTestBase.sol`, `TestHookV2.sol`, `TestJitHookV2.sol`: deployment fixtures and test-only concretes.
- `StablePairBytecode.sol`: Uniswap's StablePair hook (Sourcify creation code + proxy runtime), the reference for the
  Stable Lite differential tests.
- `StableRefModel.sol`, `CategoryTable.sol`, `Artifacts.sol`, `Roles.sol`: models, sample data and small helpers.
- `mocks/`: ERC20, WETH9, ArbSys, distributor, ballot gate and a fixed-fee hook.
