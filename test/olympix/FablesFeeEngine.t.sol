// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {PoolId} from "v4-core/src/types/PoolId.sol";

import {FablesHook} from "../../src/FablesHook.sol";
import {DiscountLib} from "../../src/libraries/DiscountLib.sol";
import {FeeRef} from "../../src/libraries/FeeRef.sol";
import {OlympixHookFixture} from "./OlympixHookFixture.sol";
import {OlympixUnitTest} from "./OlympixUnitTest.sol";

/// @notice Olympix skeleton: FablesFeeEngine (categories, pool config, pokes, discounts, continuation fee), on the
///         FablesHook build. `engine` is the configured hook; quotes come from `FablesHook.currentFee` / `feeFor`.
contract FablesFeeEngineOlympixTest is OlympixHookFixture, OlympixUnitTest("FablesFeeEngine") {
    function setUp() public {
        _setUpBuild(0);
    }

    function test_quotesTheBaseFeeBothWays() public view {
        FablesHook h = FablesHook(payable(hookAddr));
        assertEq(h.currentFee(poolId, true), BASE_FEE);
        assertEq(h.currentFee(poolId, false), BASE_FEE);
        assertEq(h.feeFor(poolId, true, address(swapRouter)), BASE_FEE);
    }

    /// @dev Price 100 ticks below the anchor: continuation mode charges the swap that pushes it further down
    ///      (zeroForOne), reverse mode the swap that brings it back, by the same amount.
    function test_cfModeChargesTheContinuationOrTheReversal() public pure {
        uint256 cont = FeeRef.packCF(_cfWord(FeeRef.CF_MODE_CONTINUATION));
        uint256 rev = FeeRef.packCF(_cfWord(FeeRef.CF_MODE_REVERSE));
        (uint256 contDown,) = FeeRef.cfStep(cont, 0, true, 1000);
        (uint256 contUp,) = FeeRef.cfStep(cont, 0, false, 1000);
        (uint256 revDown,) = FeeRef.cfStep(rev, 0, true, 1000);
        (uint256 revUp,) = FeeRef.cfStep(rev, 0, false, 1000);
        assertGt(contDown, 0);
        assertEq(contUp, 0);
        assertEq(revDown, 0);
        assertEq(revUp, contDown);
    }

    /// @dev The direction constants are the entry's direction bits: a zeroForOne-only discount cuts only that side's
    ///      fee, a oneForZero-only discount only the other, and both cuts both (10% off 3000 = 2700).
    function test_discountDirectionConstantsSelectTheSide() public {
        FablesHook h = FablesHook(payable(hookAddr));
        address zfo = makeAddr("olympix.deskZeroForOne");
        address ofz = makeAddr("olympix.deskOneForZero");
        address both = makeAddr("olympix.deskBoth");
        uint40 expiry = uint40(block.timestamp + 1 days);
        assertEq(DiscountLib.DIR_BOTH, DiscountLib.DIR_ZERO_FOR_ONE | DiscountLib.DIR_ONE_FOR_ZERO);
        engine.setDiscount(_ids(), zfo, 1000, 0, uint8(DiscountLib.DIR_ZERO_FOR_ONE), expiry);
        engine.setDiscount(_ids(), ofz, 1000, 0, uint8(DiscountLib.DIR_ONE_FOR_ZERO), expiry);
        engine.setDiscount(_ids(), both, 1000, 0, uint8(DiscountLib.DIR_BOTH), expiry);

        assertEq(h.feeFor(poolId, true, zfo), 2700);
        assertEq(h.feeFor(poolId, false, zfo), BASE_FEE);
        assertEq(h.feeFor(poolId, true, ofz), BASE_FEE);
        assertEq(h.feeFor(poolId, false, ofz), 2700);
        assertEq(h.feeFor(poolId, true, both), 2700);
        assertEq(h.feeFor(poolId, false, both), 2700);
    }

    /// @dev Two accounts hold a discount but the rebuilt filter lists only one: the other is quoted and charged the
    ///      full fee on a swap, as the Bloom filter gates the entry read. The seed is picked so it is not a false
    ///      positive.
    function test_anAccountLeftOutOfARebuiltFilterPaysTheFullFee() public {
        FablesHook h = FablesHook(payable(hookAddr));
        address desk = makeAddr("olympix.desk");
        address router = address(swapRouter); // the swap's sender as the hook sees it
        uint40 expiry = uint40(block.timestamp + 1 days);
        engine.setDiscount(_ids(), desk, 1000, 0, uint8(DiscountLib.DIR_BOTH), expiry);
        engine.setDiscount(_ids(), router, 1000, 0, uint8(DiscountLib.DIR_BOTH), expiry);
        assertEq(h.feeFor(poolId, true, router), 2700, "listed by setDiscount: discounted");

        uint8 seed;
        while (DiscountLib.hit64(DiscountLib.mask64(desk, seed), router, seed)) ++seed;
        address[] memory listed = new address[](1);
        listed[0] = desk;
        engine.setDiscountFilter(poolId, seed, listed);

        assertEq(engine.discountOf(poolId, router).bps, 1000, "the left-out account keeps its entry");
        assertEq(h.feeFor(poolId, true, desk), 2700);
        assertEq(h.feeFor(poolId, true, router), BASE_FEE);
        vm.recordLogs();
        swap(key, true, -1e15, ZERO_BYTES);
        assertEq(_lastSwapFee(), BASE_FEE);
    }

    function _ids() internal view returns (PoolId[] memory ids) {
        ids = new PoolId[](1);
        ids[0] = poolId;
    }

    /// @dev Anchored at tick 100 at t = 1000, k = 1, no dead band; period 1 so a read at t = 1000 keeps the anchor.
    function _cfWord(uint8 mode) internal pure returns (FeeRef.CFWord memory c) {
        c.tLast = 1000;
        c.anchor = 100 * 256;
        c.decay1 = FeeRef.decay1Q32(60);
        c.kQ8 = 256;
        c.cfCap = 1_000_000;
        c.maxAge = 255;
        c.period = 1;
        c.tau = 60;
        c.mode = mode;
    }
}
