// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {StableFeeCalculation} from "../../src/libraries/StableFeeCalculation.sol";
import {DiscountLib} from "../../src/libraries/DiscountLib.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

/// @notice Test-side model of the StablePair fee (start-of-block cache, in-band and decaying out-of-band fee), using
///         `StableFeeCalculation`.
library StableRefModel {
    uint256 internal constant UNDEF = StableFeeCalculation.UNDEFINED_DECAYING_FEE_E12;
    uint256 internal constant Q96 = 1 << 96;
    uint256 internal constant MIN_FEE_PRICE_RATIO_X96 = 71305346262837903834189555302;
    uint256 internal constant SQRT_MIN_FEE_PRICE_RATIO_X96 = 75162434512514379355924140470;

    function window(uint256 p, uint256 ref) internal pure returns (uint256) {
        if (StableFeeCalculation.calculatePriceRatioX96(p, ref) >= MIN_FEE_PRICE_RATIO_X96) return p;
        return p < ref ? ref * SQRT_MIN_FEE_PRICE_RATIO_X96 / Q96 : ref * Q96 / SQRT_MIN_FEE_PRICE_RATIO_X96;
    }

    function bookPrice(int24 outerLo, int24 outerHi, uint160 sqrtP, int24 tick) internal pure returns (uint256) {
        if (tick < outerLo) return TickMath.getSqrtPriceAtTick(outerLo);
        if (tick >= outerHi) return TickMath.getSqrtPriceAtTick(outerHi);
        return sqrtP;
    }

    struct Config {
        uint256 k;
        uint256 optimalFeeE6;
        uint256 targetMultiplier;
        uint256 ref;
    }

    struct State {
        uint256 decayingFeeE12;
        uint256 sqrtAmm;
        uint256 blockNumber;
    }

    struct Out {
        uint256 lpFeeE12;
        uint24 feeE6;
        bool isNewBlock;
        bool outside;
        bool adverse;
        State next;
    }

    function quote(Config memory c, State memory s, uint256 liveSqrtP, uint256 clock, bool zeroForOne)
        internal
        pure
        returns (Out memory o)
    {
        o.isNewBlock = clock > s.blockNumber || s.sqrtAmm == 0;
        uint256 amm = window(o.isNewBlock ? liveSqrtP : s.sqrtAmm, c.ref);
        uint256 ratio = StableFeeCalculation.calculatePriceRatioX96(amm, c.ref);
        int256 close = StableFeeCalculation.calculateCloseBoundaryFee(ratio, c.optimalFeeE6);
        bool below = amm < c.ref;
        uint256 decaying;
        if (close <= 0) {
            o.lpFeeE12 = StableFeeCalculation.calculateInsideOptimalRangeFee(ratio, c.optimalFeeE6, below, zeroForOne);
            decaying = UNDEF;
        } else {
            o.outside = true;
            decaying = o.isNewBlock ? _decay(c, s, amm, ratio, uint256(close), below, clock) : s.decayingFeeE12;
            o.adverse = below == zeroForOne;
            o.lpFeeE12 = o.adverse ? 0 : decaying;
        }
        o.feeE6 = StableFeeCalculation.toFeeE6(o.lpFeeE12);
        o.next = o.isNewBlock ? State(decaying, amm, clock) : s;
    }

    function _decay(
        Config memory c,
        State memory s,
        uint256 amm,
        uint256 ratio,
        uint256 close,
        bool below,
        uint256 clock
    ) private pure returns (uint256) {
        uint256 far = StableFeeCalculation.calculateFarBoundaryFee(ratio, c.optimalFeeE6);
        uint256 start;
        if (s.decayingFeeE12 == UNDEF || (s.sqrtAmm < c.ref) != below) {
            start = far;
        } else if (below == (amm < s.sqrtAmm)) {
            start = StableFeeCalculation.adjustPreviousFeeForPriceMovement(
                StableFeeCalculation.calculatePriceRatioX96(amm, s.sqrtAmm), s.decayingFeeE12
            );
        } else if (s.decayingFeeE12 > far) {
            start = far;
        } else {
            start = s.decayingFeeE12;
        }
        uint256 target = far - close * c.targetMultiplier / 100;
        if (start < target) start = target;
        uint256 blocks = clock > s.blockNumber ? clock - s.blockNumber : 0;
        return StableFeeCalculation.calculateDecayingFee(target, start, c.k, blocks);
    }

    function capped(uint24 feeE6, uint24 maxFee) internal pure returns (uint24) {
        return feeE6 > maxFee ? maxFee : feeE6;
    }

    function discounted(uint24 fee, uint32 bloom, uint8 seed, address sender, uint256 entry, bool z, uint256 nowTs)
        internal
        pure
        returns (uint24)
    {
        if (bloom == 0 || fee == 0 || !DiscountLib.hit32(bloom, sender, seed) || entry == 0) return fee;
        return uint24(DiscountLib.applyEntry(fee, 0, entry, z, nowTs));
    }
}
