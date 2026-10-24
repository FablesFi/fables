// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import "../utils/StableTestBase.sol";
import {DiscountLib} from "../../src/libraries/DiscountLib.sol";

/// @notice Stable Lite swap gas over a hookless static-fee pool, in band and out of band, first and same block.
abstract contract StableLiteGasBase is StableTestBase {
    using PoolIdLibrary for PoolKey;

    uint256 constant LITE_IN_FIRST_BOUND = 14_600;

    Baseline base;

    function setUp() public {
        setUpChain();
        Shape memory sh = defaultShape();
        base = hooklessBaseline(sh);
        logRow("vanilla", "single_0for1", base.single0for1);
        logRow("vanilla", "single_1for0", base.single1for0);
    }

    function _pool(address h, bool outOfBand) internal returns (PoolKey memory k) {
        (StableFeeConfig memory c, uint160 sqrtP) = outOfBand ? _cfgOut() : _cfgIn();
        k = _key(c0, c1, DYN, h);
        _createPool(h, k, sqrtP, c);
        _addLiq(h, k, -887220, 887220, 1e24);
        warm(k, AMT);
    }

    /// @dev Row names of the Exclusive run start with "Excl".
    function _tag(string memory name) internal pure returns (string memory) {
        return _exclusive() ? string.concat("Excl", name) : name;
    }

    function _rows(string memory label, PoolKey memory k)
        internal
        returns (GasSample memory same0, GasSample memory first0)
    {
        string memory name = _tag(label);
        same0 = swapUR(k, true, AMT);
        logRow(name, "same_0for1", same0);
        logRow(name, "same_1for0", swapUR(k, false, AMT));
        _rollClock(1);
        first0 = swapUR(k, true, AMT);
        logRow(name, "first_0for1", first0);
        _rollClock(1);
        logRow(name, "first_1for0", swapUR(k, false, AMT));
        _rollClock(1);
        logRow(name, "double_same_pool_first", swapURDouble(k, true, AMT));
    }

    function _delta(string memory what, GasSample memory s) internal view returns (int256 d) {
        d = execDelta(s, base.single0for1);
        console.log(string.concat("DELTA|", _tag(what), "|", vm.toString(d)));
    }

    function test_gas_liteInBandFirstOfBlock_withinBound() public {
        PoolKey memory k = _pool(_deployLite("g-lite-in"), false);
        (GasSample memory same0, GasSample memory first0) = _rows("Lite_in", k);
        int256 dSame = _delta("Lite_in_same_over_vanilla", same0);
        int256 dFirst = _delta("Lite_in_first_over_vanilla", first0);
        if (first0.isolated) {
            assertLe(dFirst, int256(LITE_IN_FIRST_BOUND), "StableHookLite in-band first-of-block over hookless");
            assertLe(dSame, int256(LITE_IN_FIRST_BOUND), "StableHookLite in-band same-block over hookless");
        }
    }

    function test_gas_liteInBandFirstOfBlock_arbSysClock() public {
        PoolKey memory kBn = _pool(_deployLite("g-lite-in-bn"), false);
        (, GasSample memory firstBn) = _rows("Lite_in_bn", kBn);
        _etchArbSysNumber();
        PoolKey memory k = _pool(_deployLite("g-lite-in-arb"), false);
        (GasSample memory same0, GasSample memory first0) = _rows("LiteArb_in", k);
        _delta("LiteArb_in_same_over_vanilla", same0);
        _delta("LiteArb_in_first_over_vanilla", first0);
        uint256 mockCost = _mockClockCost();
        console.log(string.concat("DELTA|MockArbSys_cold_clock_read_cost|", vm.toString(mockCost)));
        if (first0.isolated) {
            assertLe(
                first0.execGas, firstBn.execGas + mockCost + 300, "ArbSys row == block.number row + the stand-in's cost"
            );
        }
    }

    function _mockClockCost() internal returns (uint256) {
        bytes memory cd = abi.encodeWithSignature("arbBlockNumber()");
        (bool ok,) = address(0x64).call(cd);
        require(ok, "mock");
        uint256 g = vm.lastCallGas().gasTotalUsed;
        return (isolated() ? g - TX_INTRINSIC - calldataGas(cd) : g) + 2_600;
    }

    function test_gas_liteOutOfBand_rows() public {
        PoolKey memory k = _pool(_deployLite("g-lite-out"), true);
        (GasSample memory same0, GasSample memory first0) = _rows("Lite_out", k);
        _delta("Lite_out_same_over_vanilla", same0);
        _delta("Lite_out_first_over_vanilla", first0);
        uint256[4] memory gaps = [uint256(1), 3, 10, 100];
        for (uint256 i; i < 4; i++) {
            _rollClock(gaps[i]);
            logRow(_tag("Lite_out"), string.concat("after", vm.toString(gaps[i]), "_0for1"), swapUR(k, true, AMT));
        }
    }

    function test_gas_stablePairReference_rows() public {
        PoolKey memory k = _pool(_deploySP("g-sp-in"), false);
        (GasSample memory same0, GasSample memory first0) = _rows("SP_in", k);
        _delta("SP_in_same_over_vanilla", same0);
        _delta("SP_in_first_over_vanilla", first0);
    }

    function test_gas_whitelist_rows() public {
        address h = _deployLite("g-lite-wl");
        PoolKey memory k = _pool(h, false);
        PoolId[] memory ids = new PoolId[](1);
        ids[0] = k.toId();
        address[] memory desks = new address[](4);
        for (uint256 i; i < 4; i++) {
            desks[i] = address(uint160(uint256(keccak256(abi.encode("desk", i)))));
            FablesStableHookLite(h).setDiscount(ids, desks[i], 3000, 0, 3, uint40(block.timestamp + 30 days));
        }
        for (uint8 seed; seed < 255; seed++) {
            FablesStableHookLite(h).setDiscountFilter(k.toId(), seed, desks);
            (, uint32 bloom) = FablesStableHookLite(h).discountFilter(k.toId());
            uint32 m = DiscountLib.mask32(UR_ADDR, seed);
            if (bloom & m != m) break;
        }
        GasSample memory miss = swapUR(k, true, AMT);
        logRow(_tag("Lite_wl_notListed"), "same_0for1", miss);
        _delta("Lite_wl_notListed_same_over_vanilla", miss);
        FablesStableHookLite(h).setDiscount(ids, UR_ADDR, 3000, 0, 3, uint40(block.timestamp + 30 days));
        GasSample memory hit = swapUR(k, true, AMT);
        logRow(_tag("Lite_wl_listed"), "same_0for1", hit);
        _delta("Lite_wl_listed_same_over_vanilla", hit);
        (uint24 g0,) = _getFee(h, k);
        assertEq(FablesStableHookLite(h).feeFor(k, true, UR_ADDR), (uint256(g0) * 7000 + 9999) / 10000, "30% off");
    }
}

/// @notice On FablesStableHookLite.
contract StableLiteGasTest is StableLiteGasBase {}

/// @notice On FablesStableHookLiteExclusive.
contract StableLiteGasExclusiveTest is StableLiteGasBase {
    function _exclusive() internal pure override returns (bool) {
        return true;
    }
}
