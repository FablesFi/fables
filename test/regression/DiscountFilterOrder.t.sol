// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {FablesFeeEngine} from "../../src/base/FablesFeeEngine.sol";
import {StableFeeConfig} from "../../src/base/FablesStableFee.sol";
import {FablesStableHookLite} from "../../src/FablesStableHookLite.sol";
import {DiscountLib} from "../../src/libraries/DiscountLib.sol";
import {BuildsFixture} from "../utils/BuildsFixture.sol";
import {StableBuild} from "../utils/Artifacts.sol";

/// @notice Stable `discountFilter` return shape.
interface IStableDiscountFilter {
    function discountFilter(PoolId poolId) external view returns (uint8 seed, uint32 bloom);
}

/// @notice `discountFilter` returns (seed, bloom) on FablesHook and on both Stable Lite builds.
contract DiscountFilterOrderTest is BuildsFixture {
    using PoolIdLibrary for PoolKey;

    address internal desk = makeAddr("desk");

    function setUp() public {
        _setUpStack();
    }

    function _full(uint8 seed) internal returns (address h, PoolId id) {
        h = _deploy(_builds()[0], 0xF1A1);
        PoolKey memory k = _erc20Key(h, 60);
        _configureFlat(h, k, 3_000);
        _initPool(k, SQRT_PRICE_1_1);
        id = k.toId();
        FablesFeeEngine(h).setDiscount(_ids(id), desk, 100, 0, 3, uint40(block.timestamp + 1 days));
        FablesFeeEngine(h).setDiscountFilter(id, seed, _accounts());
    }

    function _stableLite(uint8 seed, bool exclusive) internal returns (address h, PoolId id) {
        h = address((uint160(exclusive ? 0xF1A3 : 0xF1A2) << 144) | StableBuild.flags(exclusive));
        deployCodeTo(StableBuild.artifact(exclusive), abi.encode(manager, address(authority)), h);
        IERC20(Currency.unwrap(currency0)).approve(h, type(uint256).max);
        IERC20(Currency.unwrap(currency1)).approve(h, type(uint256).max);
        PoolKey memory k = _erc20Key(h, 60);
        FablesStableHookLite(h)
            .configureStablePool(k, SQRT_PRICE_1_1, StableFeeConfig(11_744_051, 50, 100, SQRT_PRICE_1_1));
        id = k.toId();
        FablesStableHookLite(h).setDiscount(_ids(id), desk, 100, 0, 3, uint40(block.timestamp + 1 days));
        FablesStableHookLite(h).setDiscountFilter(id, seed, _accounts());
    }

    function _read(address h, PoolId id) internal view returns (uint8 seed, uint64 bloom) {
        (bool ok, bytes memory ret) = h.staticcall(abi.encodeWithSignature("discountFilter(bytes32)", id));
        assertTrue(ok, "discountFilter reverted");
        assertEq(ret.length, 64, "two words");
        (seed, bloom) = abi.decode(ret, (uint8, uint64));
    }

    function testFuzz_seedThenBloom_onFullAndStableLite(uint8 seed) public {
        seed = uint8(bound(seed, 0, 127));

        (address full, PoolId fid) = _full(seed);
        (uint8 fSeed, uint64 fBloom) = FablesFeeEngine(full).discountFilter(fid);
        assertEq(fSeed, seed, "FablesHook seed first");
        assertEq(fBloom, DiscountLib.mask64(desk, seed), "FablesHook bloom second");
        (uint8 s, uint64 b) = _read(full, fid);
        assertEq(abi.encode(s, b), abi.encode(fSeed, fBloom), "FablesHook via the shared tuple");

        for (uint256 e; e < 2; e++) {
            (address lite, PoolId sid) = _stableLite(seed, e == 1);
            (uint8 sSeed, uint32 sBloom) = IStableDiscountFilter(lite).discountFilter(sid);
            assertEq(sSeed, seed, "stable seed first");
            assertEq(sBloom, DiscountLib.mask32(desk, seed), "stable bloom second");
            (s, b) = _read(lite, sid);
            assertEq(s, sSeed, "stable seed via the shared tuple");
            assertEq(b, uint64(sBloom), "a uint32 bloom fits the uint64 slot");
        }
    }

    function _ids(PoolId id) internal pure returns (PoolId[] memory a) {
        a = new PoolId[](1);
        a[0] = id;
    }

    function _accounts() internal view returns (address[] memory a) {
        a = new address[](1);
        a[0] = desk;
    }
}
