// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "v4-core/test/utils/Deployers.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {PoolWordLib} from "../../src/libraries/PoolWordLib.sol";
import {FeeRef} from "../../src/libraries/FeeRef.sol";
import {FullHarness} from "./FullHarness.sol";

/// @notice Fixture that calls the assembly swap entry directly as the PoolManager over arbitrary stored words.
abstract contract FullTestBase is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using PoolWordLib for uint256;

    uint256 internal constant NOW = 1_800_000_000;
    uint256 internal constant ABSOLUTE_MAX_FEE = 100_000;
    uint256 internal constant OVERRIDE = 0x400000;

    FullHarness internal hook;
    address internal hookAddr;
    AccessManager internal authority;

    function _deployFull() internal {
        deployFreshManagerAndRouters();
        authority = new AccessManager(address(this));
        hookAddr = address(uint160(0x2222 << 144) | uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG));
        deployCodeTo("FullHarness.sol:FullHarness", abi.encode(manager, address(authority)), hookAddr);
        hook = FullHarness(hookAddr);
        vm.label(hookAddr, "FullHarness");
        vm.warp(NOW);
    }

    function _key(uint256 salt) internal view returns (PoolKey memory) {
        address a = address(uint160(uint256(keccak256(abi.encode("c0", salt)))));
        address b = address(uint160(uint256(keccak256(abi.encode("c1", salt)))));
        if (a > b) (a, b) = (b, a);
        return PoolKey(Currency.wrap(a), Currency.wrap(b), LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(hookAddr));
    }

    function _slot0Slot(PoolId id) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(PoolId.unwrap(id), StateLibrary.POOLS_SLOT));
    }

    function _setSlot0(PoolId id, uint256 slot0) internal {
        vm.store(address(manager), _slot0Slot(id), bytes32(slot0));
    }

    function _setTick(PoolId id, int24 tick) internal {
        _setSlot0(id, (uint256(uint24(tick)) << 160) | uint256(TickMath.getSqrtPriceAtTick(tick)));
    }

    function _tickOf(uint256 slot0) internal pure returns (int24) {
        return int24(uint24(slot0 >> 160));
    }

    function _configuredWord(uint256 raw, uint24 base0, uint24 base1, uint24 floor_, uint24 cap)
        internal
        pure
        returns (uint256)
    {
        cap = uint24(bound(cap, 1, ABSOLUTE_MAX_FEE));
        floor_ = uint24(bound(floor_, 0, cap));
        base0 = uint24(bound(base0, floor_, cap));
        base1 = uint24(bound(base1, floor_, cap));
        return raw.withBases(base0, base1).withBounds(floor_, cap);
    }

    struct CFParams {
        uint8 mode;
        uint16 k;
        uint24 cfCap;
        uint16 band16;
        uint16 tau;
        uint8 period;
        uint40 tLast;
        int32 anchor;
    }

    function _legalCF(CFParams memory p) internal pure returns (uint256) {
        p.mode = uint8(bound(p.mode, 0, 1));
        p.k = uint16(bound(p.k, 1, 256));
        p.cfCap = uint24(bound(p.cfCap, 1, 2_500));
        p.band16 = uint16(bound(p.band16, 0, 800));
        p.tau = uint16(bound(p.tau, 5, 300));
        p.period = uint8(bound(p.period, 1, 60));
        uint256 maxAge = 5 * uint256(p.tau);
        if (maxAge > 255) maxAge = 255;
        return FeeRef.packCF(
            FeeRef.CFWord({
                tLast: p.tLast,
                anchor: p.anchor,
                decay1: FeeRef.decay1Q32(p.tau),
                kQ8: p.k,
                cfCap: p.cfCap,
                band16: p.band16,
                maxAge: uint8(maxAge),
                period: p.period,
                tau: p.tau,
                mode: p.mode
            })
        );
    }

    function _beforeSwapCalldata(
        PoolKey memory key,
        address sender,
        bool zeroForOne,
        int256 amount,
        bytes memory hookData
    ) internal pure returns (bytes memory) {
        return abi.encodeCall(
            IHooks.beforeSwap,
            (
                sender,
                key,
                IPoolManager.SwapParams({
                    zeroForOne: zeroForOne,
                    amountSpecified: amount,
                    sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
                }),
                hookData
            )
        );
    }

    function _callAsPoolManager(bytes memory cd) internal returns (bool ok, bytes memory ret) {
        vm.prank(address(manager));
        (ok, ret) = hookAddr.call(cd);
    }

    function _feeWord(bytes memory ret) internal pure returns (uint256 feeWord) {
        assertEq(ret.length, 96, "return length");
        bytes32 sel;
        int256 delta;
        (sel, delta, feeWord) = abi.decode(ret, (bytes32, int256, uint256));
        assertEq(bytes4(sel), IHooks.beforeSwap.selector, "selector");
        assertEq(delta, 0, "delta");
        assertEq(feeWord & OVERRIDE, OVERRIDE, "override flag");
        assertEq(feeWord >> 24, 0, "a 24-bit fee");
    }

    function _decodeFee(bytes memory ret) internal pure returns (uint256 fee) {
        fee = _feeWord(ret) ^ OVERRIDE;
        assertLt(fee, OVERRIDE, "fee has no bit 22 (configured pools cap at 100_000)");
    }

    function _swapFee(PoolKey memory key, address sender, bool zeroForOne) internal returns (uint256 fee) {
        (bool ok, bytes memory ret) = _callAsPoolManager(_beforeSwapCalldata(key, sender, zeroForOne, -1e18, ""));
        assertTrue(ok, "beforeSwap reverted");
        return _decodeFee(ret);
    }
}
