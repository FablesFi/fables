// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import "../utils/StableTestBase.sol";

uint24 constant LITE_CAP = 100_000;

/// @notice Stable Lite views and swap entry return min(StablePair fee, 10%).
abstract contract StableFeeCapBase is StableTestBase {
    using PoolIdLibrary for PoolKey;

    function test_liteCapsViewsAndSwapEntry() public {
        setUpChain();
        address sp = _deploySP("cap-sp");
        address lite = _deployLite("cap-lite");
        (StableFeeConfig memory c,) = _cfgIn();
        uint160 sqrtP = uint160(uint256(c.referenceSqrtPriceX96) * 894_427 / 1_000_000);
        PoolKey memory kSp = _key(c0, c1, DYN, sp);
        PoolKey memory kLite = _key(c0, c1, DYN, lite);
        _createPool(sp, kSp, sqrtP, c);
        _createPool(lite, kLite, sqrtP, c);
        (uint24 r0, uint24 r1) = _getFee(sp, kSp);
        (uint24 f0, uint24 f1) = _getFee(lite, kLite);
        assertGt(r1, LITE_CAP, "reference above 10%");
        assertEq(f0, r0, "below the cap: identical");
        assertEq(f1, LITE_CAP, "min(reference, 100_000)");
        assertEq(FablesStableHookLite(lite).maxFee(kLite.toId()), LITE_CAP);
        (bool ok, bytes memory ret) = _beforeSwapCall(lite, kLite, false, address(this));
        assertTrue(ok);
        (,, uint24 fee) = abi.decode(ret, (bytes4, int256, uint24));
        assertEq(fee, LITE_CAP | 0x400000);
    }
}

/// @notice On FablesStableHookLite.
contract StableFeeCapTest is StableFeeCapBase {}

/// @notice On FablesStableHookLiteExclusive.
contract StableFeeCapExclusiveTest is StableFeeCapBase {
    function _exclusive() internal pure override returns (bool) {
        return true;
    }
}
