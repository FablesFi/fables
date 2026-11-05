// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import "../utils/StableTestBase.sol";
import {MockBallotGate} from "../utils/mocks/MockBallotGate.sol";
import {MockDistributor} from "../utils/mocks/MockDistributor.sol";

/// @notice One Stable Lite build (open by default; override `_exclusive()` for the Exclusive build) on the Robinhood
///         Chain PoolManager bytecode, with a stable pool at its reference price, ledger liquidity of 1e24 around it,
///         the ledger wired to a distributor and ballot gate, and a funded swapper. The test contract is the
///         AccessManager admin.
abstract contract OlympixStableFixture is StableTestBase {
    using PoolIdLibrary for PoolKey;

    int24 internal constant RANGE = 600;
    uint128 internal constant LIQ = 1e24;

    SeqSwapper internal swapper;
    FablesStableHookLite internal stableHook;
    MockBallotGate internal gate;
    PoolKey internal stableKey;
    PoolId internal poolId;

    function _setUpStable() internal {
        setUpChain();
        swapper = new SeqSwapper(pm);
        MockERC20(Currency.unwrap(c0)).mint(address(swapper), BIG);
        MockERC20(Currency.unwrap(c1)).mint(address(swapper), BIG);

        address h = _deployLite("olympix-stable");
        stableHook = FablesStableHookLite(payable(h));
        stableHook.setDistributor(new Currency[](0), address(new MockDistributor(makeAddr("olympix.fables"))));
        gate = new MockBallotGate();
        stableHook.setBallotGate(address(gate));

        stableKey = PoolKey(c0, c1, DYN, 1, IHooks(h));
        (StableFeeConfig memory c, uint160 sqrtP) = _cfgIn();
        _createPool(h, stableKey, sqrtP, c);
        poolId = stableKey.toId();
        _addLiq(h, stableKey, INIT_TICK - RANGE, INIT_TICK + RANGE, LIQ);
    }
}
