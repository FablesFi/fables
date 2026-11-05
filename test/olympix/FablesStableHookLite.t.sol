// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {OlympixStableFixture} from "./OlympixStableFixture.sol";
import {OlympixUnitTest} from "./OlympixUnitTest.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

/// @notice Olympix skeleton: FablesStableHookLite (StablePair fee, open liquidity).
contract FablesStableHookLiteOlympixTest is OlympixStableFixture, OlympixUnitTest("FablesStableHookLite") {
    function setUp() public {
        _setUpStable();
    }

    function test_swapSucceedsAndTheFeeStaysCapped() public {
        (bool ok,) = swapper.swap(stableKey, true, -1e18, TickMath.MIN_SQRT_PRICE + 1);
        assertTrue(ok);
        (uint24 f0, uint24 f1) = stableHook.getFee(stableKey);
        assertLe(f0, FABLES_FEE_CAP);
        assertLe(f1, FABLES_FEE_CAP);
    }
}
