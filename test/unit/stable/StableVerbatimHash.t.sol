// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

/// @notice `StableFeeCalculation` and Solady's `FixedPointMathLib` are byte-identical to their upstream sources.
contract StableVerbatimHashTest is Test {
    bytes32 constant STABLE_FEE_CALCULATION_SHA256 = 0x29b974c991305167940567f403dbef0749be52373e2910423ac195862bde5624;
    bytes32 constant SOLADY_FIXED_POINT_MATH_LIB_SHA256 =
        0xbb0c06fe117d69df9bff7baf442255aa114e1c01d1ebe077213e2eb4e06ae2d6;

    function test_stableFeeCalculationIsVerbatim() public view {
        bytes memory src = bytes(vm.readFile("src/libraries/StableFeeCalculation.sol"));
        assertEq(
            sha256(src),
            STABLE_FEE_CALCULATION_SHA256,
            "StableFeeCalculation.sol differs from v4-hooks-public @ e4eabe5"
        );
        assertEq(src.length, 12119, "length");
        assertEq(bytes32(_head(src, 32)), bytes32(bytes("// SPDX-License-Identifier: MIT\n")));
    }

    function test_soladyFixedPointMathLibIsVerbatim() public view {
        bytes memory src = bytes(vm.readFile("src/vendor/solady/utils/FixedPointMathLib.sol"));
        assertEq(sha256(src), SOLADY_FIXED_POINT_MATH_LIB_SHA256, "FixedPointMathLib.sol differs from Solady v0.1.26");
        assertEq(bytes32(_head(src, 32)), bytes32(bytes("// SPDX-License-Identifier: MIT\n")));
    }

    function _head(bytes memory b, uint256 n) internal pure returns (bytes memory h) {
        h = new bytes(n);
        for (uint256 i; i < n; i++) {
            h[i] = b[i];
        }
    }
}
