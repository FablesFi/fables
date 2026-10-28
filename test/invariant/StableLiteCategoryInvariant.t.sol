// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {console} from "forge-std/console.sol";
import {Deployers} from "v4-core/test/utils/Deployers.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolDonateTest} from "v4-core/src/test/PoolDonateTest.sol";
import {Pool} from "v4-core/src/libraries/Pool.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";

import {FablesStableFee, StableFeeConfig} from "../../src/base/FablesStableFee.sol";
import {FablesLedgerV2} from "../../src/base/FablesLedgerV2.sol";
import {FablesExclusiveLiquidityV2} from "../../src/base/FablesExclusiveLiquidityV2.sol";
import {RangeState, UserPosition} from "../../src/base/LedgerTypesV2.sol";
import {StableFeeCalculation} from "../../src/libraries/StableFeeCalculation.sol";
import {DiscountLib} from "../../src/libraries/DiscountLib.sol";
import {StableRefModel} from "../utils/StableRefModel.sol";
import {FablesStableHookLite} from "../../src/FablesStableHookLite.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {EtchDeploy, StableBuild, Depth} from "../utils/Artifacts.sol";

/// @notice Stable Lite views and admin used by the walk.
interface IStableLite {
    function configureStablePool(PoolKey calldata key, uint160 sqrtPriceX96, StableFeeConfig calldata config)
        external
        returns (int24);
    function updateFeeConfig(PoolKey calldata key, uint24 k, uint24 optimalFeeE6, uint8 targetMultiplier) external;
    function feeConfig(PoolId poolId) external view returns (uint24, uint24, uint8, uint160);
    function feeState(PoolId poolId) external view returns (uint40, uint160, uint40);
    function feeFor(PoolKey calldata key, bool zeroForOne, address sender) external view returns (uint24);
    function currentFee(PoolId poolId, bool zeroForOne) external view returns (uint24);
    function discountFilter(PoolId poolId) external view returns (uint8 seed, uint32 bloom);
    function discountOf(PoolId poolId, address account) external view returns (uint16, uint24, uint8, uint40);
    function setDiscount(PoolId[] calldata ids, address account, uint16 bps, uint24 minFee, uint8 dirs, uint40 expiry)
        external;
    function revokeDiscount(PoolId[] calldata ids, address[] calldata accounts) external;
    function setDiscountFilter(PoolId poolId, uint8 seed, address[] calldata accounts) external;
    function updateReferencePrice(PoolKey calldata key, uint160 referenceSqrtPriceX96) external;
    function setMinimumFee(PoolKey calldata key, uint16 minimumFee) external;
    function minimumFee(PoolId poolId) external view returns (uint16);
    function referenceUpdatedAt(PoolId poolId) external view returns (uint256);
}

/// @notice Random walk over Stable Lite pools with fuzzed configs, reference moves and minimum fees, checking
///         every swap fee against the StablePair model plus the minimum. An outside LP adds and removes liquidity directly at random ranges and donates; the Exclusive build
///         must refuse its adds.
contract StableLiteCategoryHandler is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    bytes32 internal constant SWAP_TOPIC =
        keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");
    bytes4 internal constant PRICE_LIMIT_EXCEEDED = bytes4(keccak256("PriceLimitAlreadyExceeded(uint160,uint160)"));
    uint256 internal constant MAX_POOLS = 4;
    uint256 internal constant NRANGES = 2;

    IPoolManager public immutable manager;
    IStableLite public immutable hook;
    Currency public immutable c0;
    Currency public immutable c1;
    bool public immutable exclusive;
    PoolSwapTest[3] public routers;
    PoolModifyLiquidityTest public immutable lpRouter;
    PoolDonateTest public immutable donateRouter;
    address[3] public actors;
    PoolKey[] internal keys;
    int24[4] internal spacings = [int24(1), int24(5), int24(10), int24(60)];
    int24[NRANGES] public lowers = [int24(-2400), int24(-60)];
    int24[NRANGES] public uppers = [int24(2400), int24(60)];

    uint256 public violations;
    string public firstViolation;
    mapping(bytes32 => uint256) public landed;
    mapping(bytes32 => uint256) public refused;
    uint256 public swapsOutside;
    uint256 public swapsAdverse;
    uint256 public swapsCached;
    uint256 public swapsDiscounted;
    uint256 public swapsRaised;
    uint256 public maxFee;

    struct Outside {
        uint256 pool;
        int24 lower;
        int24 upper;
        uint128 liquidity;
        bytes32 salt;
    }

    /// @notice Open positions of the outside LP (owned by `lpRouter`, one salt each).
    Outside[] internal outside;
    uint256 internal outsideSalt;

    constructor(
        IPoolManager manager_,
        address hook_,
        Currency c0_,
        Currency c1_,
        address[3] memory actors_,
        bool exclusive_
    ) {
        manager = manager_;
        hook = IStableLite(hook_);
        c0 = c0_;
        c1 = c1_;
        actors = actors_;
        exclusive = exclusive_;
        for (uint256 i = 0; i < 3; ++i) {
            routers[i] = new PoolSwapTest(manager_);
        }
        lpRouter = new PoolModifyLiquidityTest(manager_);
        donateRouter = new PoolDonateTest(manager_);
    }

    function wire() external {
        for (uint256 j = 0; j < 2; ++j) {
            IERC20 t = IERC20(Currency.unwrap(j == 0 ? c0 : c1));
            for (uint256 i = 0; i < 3; ++i) {
                t.approve(address(routers[i]), type(uint256).max);
                vm.prank(actors[i]);
                t.approve(address(hook), type(uint256).max);
            }
            t.approve(address(lpRouter), type(uint256).max);
            t.approve(address(donateRouter), type(uint256).max);
        }
    }

    function fuzzSelectors() external pure returns (bytes4[] memory s) {
        s = new bytes4[](18);
        s[0] = this.createPool.selector;
        s[1] = this.updateConfig.selector;
        s[2] = this.swap.selector;
        s[3] = this.swapLarge.selector;
        s[4] = this.deposit.selector;
        s[5] = this.withdraw.selector;
        s[6] = this.claim.selector;
        s[7] = this.discountGrant.selector;
        s[8] = this.discountRevoke.selector;
        s[9] = this.discountFilter.selector;
        s[10] = this.roll.selector;
        s[11] = this.warp.selector;
        s[12] = this.swap.selector;
        s[13] = this.outsideAdd.selector;
        s[14] = this.outsideRemove.selector;
        s[15] = this.donate.selector;
        s[16] = this.setMinimum.selector;
        s[17] = this.moveReference.selector;
    }

    uint256 public budget = type(uint256).max;
    uint256 public stepsDone;
    bool public noop;

    modifier budgeted() {
        if (stepsDone >= budget) {
            noop = true;
            return;
        }
        noop = false;
        ++stepsDone;
        _;
    }

    function setBudget(uint256 b) external {
        budget = b;
        stepsDone = 0;
        noop = false;
    }

    function poolCount() external view returns (uint256) {
        return keys.length;
    }

    function keyAt(uint256 i) external view returns (PoolKey memory) {
        return keys[i];
    }

    function _violate(string memory why) internal {
        if (violations == 0) firstViolation = why;
        violations++;
        emit log_named_string("VIOLATION", why);
    }

    function _sel(bytes memory err) internal pure returns (bytes4 s) {
        if (err.length >= 4) {
            assembly ("memory-safe") {
                s := mload(add(err, 0x20))
            }
        }
    }

    function _outcome(bytes32 name, bool predicted, bool ok, bytes memory err, bytes4 expected) internal {
        if (ok) landed[name]++;
        else refused[name]++;
        if (ok && !predicted) _violate(string.concat(_s(name), ": landed but the design refuses it"));
        if (!ok && predicted) {
            _violate(string.concat(_s(name), ": refused but the design accepts it: ", vm.toString(err)));
        }
        if (!ok && !predicted && expected != bytes4(0) && _sel(err) != expected) {
            _violate(string.concat(_s(name), ": refused with an unexpected error: ", vm.toString(err)));
        }
    }

    function _s(bytes32 b) internal pure returns (string memory) {
        uint256 n;
        while (n < 32 && b[n] != 0) n++;
        bytes memory out = new bytes(n);
        for (uint256 i = 0; i < n; ++i) {
            out[i] = b[i];
        }
        return string(out);
    }

    struct Cfg {
        uint24 k;
        uint24 opt;
        uint8 tm;
        int24 refTick;
        int24 priceTick;
    }

    function _shape(Cfg memory c, uint8 mode) internal pure {
        if (mode % 4 != 0) {
            c.k = uint24(bound(c.k, 1, type(uint24).max));
            c.opt = uint24(bound(c.opt, 0, 10_000));
            c.tm = uint8(bound(c.tm, 1, 100));
        } else {
            c.opt = uint24(bound(c.opt, 0, 12_000));
            c.tm = uint8(bound(c.tm, 0, 120));
            c.k = uint24(bound(c.k, 0, 3));
        }
    }

    function _validatorError(Cfg memory c) internal pure returns (bytes4) {
        if (c.k == 0) return FablesStableFee.InvalidK.selector;
        if (c.opt > 10_000) return FablesStableFee.InvalidOptimalFeeE6.selector;
        if (c.tm == 0 || c.tm > 100) return FablesStableFee.InvalidTargetMultiplier.selector;
        return bytes4(0);
    }

    function createPool(Cfg memory c, uint8 mode) external budgeted {
        if (keys.length >= MAX_POOLS) return;
        _shape(c, mode);
        c.refTick = int24(bound(c.refTick, -200, 200));
        c.priceTick = int24(bound(c.priceTick, -300, 300)) + c.refTick;
        PoolKey memory key =
            PoolKey(c0, c1, LPFeeLibrary.DYNAMIC_FEE_FLAG, spacings[keys.length], IHooks(address(hook)));
        uint160 ref = TickMath.getSqrtPriceAtTick(c.refTick);
        bytes4 expected = _validatorError(c);
        bytes memory cd = abi.encodeCall(
            IStableLite.configureStablePool,
            (key, TickMath.getSqrtPriceAtTick(c.priceTick), StableFeeConfig(c.k, c.opt, c.tm, ref))
        );
        (bool ok, bytes memory err) = address(hook).call(cd);
        _outcome("createPool", expected == bytes4(0), ok, err, expected);
        if (!ok) return;
        keys.push(key);
        _checkFreshState(keys.length - 1, "createPool");
        for (uint256 a = 0; a < 3; ++a) {
            _deposit(keys.length - 1, a, 0, 1e22);
        }
        _deposit(keys.length - 1, 0, 1, 1e22);
    }

    function updateConfig(uint256 p, Cfg memory c, uint8 mode) external budgeted {
        if (keys.length == 0) return;
        p %= keys.length;
        _shape(c, mode);
        PoolId id = keys[p].toId();
        (,,, uint160 refBefore) = hook.feeConfig(id);
        bytes4 expected = _validatorError(c);
        (bool ok, bytes memory err) =
            address(hook).call(abi.encodeCall(IStableLite.updateFeeConfig, (keys[p], c.k, c.opt, c.tm)));
        _outcome("updateConfig", expected == bytes4(0), ok, err, expected);
        if (!ok) return;
        (uint24 k, uint24 opt, uint8 tm, uint160 ref) = hook.feeConfig(id);
        if (k != c.k || opt != c.opt || tm != c.tm || ref != refBefore) _violate("updateConfig: config not stored");
        _checkFreshState(p, "updateConfig");
    }

    /// @notice Sets a pool's minimum fee: mostly 0 or small, sometimes up to the uint16 range.
    function setMinimum(uint256 p, uint16 m, uint8 mode) external budgeted {
        if (keys.length == 0) return;
        p %= keys.length;
        if (mode % 3 == 0) m = 0;
        else if (mode % 3 == 1) m = uint16(bound(m, 1, 200));
        PoolId id = keys[p].toId();
        uint16 before = hook.minimumFee(id);
        bytes32 st = _stateHash(id);
        (bool ok, bytes memory err) = address(hook).call(abi.encodeCall(IStableLite.setMinimumFee, (keys[p], m)));
        _outcome("setMinimum", true, ok, err, bytes4(0));
        if (!ok) return;
        if (hook.minimumFee(id) != m) _violate("setMinimum: not stored");
        if (m < before) _checkFreshState(p, "setMinimum");
        else if (_stateHash(id) != st) _violate("setMinimum: a raise reset the fee state");
    }

    function _stateHash(PoolId id) internal view returns (bytes32) {
        (uint40 d, uint160 sp, uint40 bn) = hook.feeState(id);
        return keccak256(abi.encode(d, sp, bn));
    }

    /// @notice Moves a pool's reference by `ppm` of its price: inside or outside the 0.1% step, sooner or later than
    ///         a minute after the last move.
    function moveReference(uint256 p, uint256 ppm, uint8 mode) external budgeted {
        if (keys.length == 0) return;
        p %= keys.length;
        if (mode % 2 == 0) vm.warp(block.timestamp + 60);
        _moveReference(p, mode % 5 == 4 ? bound(ppm, 995_000, 1_005_000) : bound(ppm, 999_100, 1_000_900));
    }

    function _moveReference(uint256 p, uint256 ppm) internal {
        PoolId id = keys[p].toId();
        uint160 next = _scaledRef(id, ppm);
        bytes32 kept = _keptHash(id);
        bool soon = block.timestamp < hook.referenceUpdatedAt(id) + 60;
        (bool ok, bytes memory err) =
            address(hook).call(abi.encodeCall(IStableLite.updateReferencePrice, (keys[p], next)));
        _moveOutcome(ppm, soon, ok, err);
        if (!ok) return;
        (,,, uint160 ref) = hook.feeConfig(id);
        if (ref != next) _violate("moveReference: reference not stored");
        if (_keptHash(id) != kept) _violate("moveReference: k, band, multiplier or minimum fee changed");
        if (hook.referenceUpdatedAt(id) != block.timestamp) _violate("moveReference: time not stored");
        _checkFreshState(p, "moveReference");
    }

    function _scaledRef(PoolId id, uint256 ppm) internal view returns (uint160) {
        (,,, uint160 ref) = hook.feeConfig(id);
        return uint160(FixedPointMathLib.sqrt(FixedPointMathLib.fullMulDiv(uint256(ref) * ref, ppm, 1e6)));
    }

    function _keptHash(PoolId id) internal view returns (bytes32) {
        (uint24 k, uint24 opt, uint8 tm,) = hook.feeConfig(id);
        return keccak256(abi.encode(k, opt, tm, hook.minimumFee(id)));
    }

    /// @dev Within a guard band of the 0.1% bound either outcome is fine (two sqrt roundings), but only for that error.
    function _moveOutcome(uint256 ppm, bool soon, bool ok, bytes memory err) internal {
        bytes4 tooLarge = FablesStableHookLite.ReferenceStepTooLarge.selector;
        bool edge = (ppm >= 998_999 && ppm <= 999_001) || (ppm >= 1_000_999 && ppm <= 1_001_002);
        if (edge && !soon) {
            if (ok) landed["moveReference"]++;
            else refused["moveReference"]++;
            if (!ok && _sel(err) != tooLarge) _violate("moveReference: refused at the edge with an unexpected error");
            return;
        }
        bool tooFar = ppm < 999_001 || ppm > 1_000_999;
        bytes4 expected = soon ? FablesStableHookLite.ReferenceUpdateTooSoon.selector : tooLarge;
        _outcome("moveReference", !soon && !tooFar, ok, err, expected);
    }

    function _checkFreshState(uint256 p, string memory where) internal {
        (uint40 d, uint160 sp, uint40 bn) = hook.feeState(keys[p].toId());
        if (d != StableRefModel.UNDEF || sp != 0 || bn != block.number) {
            _violate(string.concat(where, ": the fee state was not reset"));
        }
    }

    function swap(uint256 p, uint256 r, bool z, uint256 amt, bool exactOut) external budgeted {
        _swap(p, r, z, bound(amt, 1e6, 1e21), exactOut);
    }

    function swapLarge(uint256 p, uint256 r, bool z, uint256 amt, bool exactOut) external budgeted {
        _swap(p, r, z, bound(amt, 1e21, 5e22), exactOut);
    }

    struct Ctx {
        PoolKey key;
        address desk;
        bool z;
        StableRefModel.Out o;
        uint24 expected;
        uint256 minFee;
    }

    function _swap(uint256 p, uint256 r, bool z, uint256 amt, bool exactOut) internal {
        if (keys.length == 0) return;
        Ctx memory x;
        x.key = keys[p % keys.length];
        x.desk = address(routers[r % 3]);
        x.z = z;
        _model(x);
        if (hook.feeFor(x.key, z, x.desk) != x.expected) _violate("stable: feeFor != model before the swap");
        bytes memory cd = _swapCalldata(x.key, z, exactOut ? int256(amt) : -int256(amt));
        vm.recordLogs();
        (bool ok, bytes memory err) = address(routers[r % 3]).call(cd);
        if (!ok) {
            refused["swap"]++;
            if (_sel(err) != PRICE_LIMIT_EXCEEDED) {
                _violate(string.concat("stable swap: unexpected revert ", vm.toString(err)));
            }
            return;
        }
        landed["swap"]++;
        _checkSwap(x);
    }

    function _swapCalldata(PoolKey memory key, bool z, int256 spec) internal pure returns (bytes memory) {
        return abi.encodeCall(
            PoolSwapTest.swap,
            (
                key,
                IPoolManager.SwapParams({
                    zeroForOne: z,
                    amountSpecified: spec,
                    sqrtPriceLimitX96: z ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
                }),
                PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
                bytes("")
            )
        );
    }

    function _model(Ctx memory x) internal view {
        PoolId id = x.key.toId();
        StableRefModel.Config memory c;
        {
            (uint24 k, uint24 opt, uint8 tm, uint160 ref) = hook.feeConfig(id);
            c = StableRefModel.Config(k, opt, tm, ref);
        }
        StableRefModel.State memory s;
        {
            (uint40 d, uint160 sp, uint40 bn) = hook.feeState(id);
            s = StableRefModel.State(d, sp, bn);
        }
        (uint160 live,,,) = manager.getSlot0(id);
        x.o = StableRefModel.quote(c, s, live, block.number, x.z);
        x.o.feeE6 = StableRefModel.capped(x.o.feeE6, FablesLedgerV2(payable(address(hook))).maxFee(id));
        x.minFee = hook.minimumFee(id);
        x.expected = StableRefModel.withMin(_discounted(id, x), x.minFee);
    }

    function _discounted(PoolId id, Ctx memory x) internal view returns (uint24) {
        (uint8 seed, uint32 bloom) = hook.discountFilter(id);
        uint256 entry;
        {
            (uint16 bps, uint24 minFee, uint8 dirs, uint40 expiry) = hook.discountOf(id, x.desk);
            entry = DiscountLib.pack(bps, minFee, dirs, expiry);
        }
        return StableRefModel.discounted(x.o.feeE6, bloom, seed, x.desk, entry, x.z, block.timestamp);
    }

    function _checkSwap(Ctx memory x) internal {
        uint256 fee;
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(manager) && logs[i].topics[0] == SWAP_TOPIC) {
                (,,,,, uint24 f) = abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
                fee = f;
            }
        }
        if (fee > maxFee) maxFee = fee;
        if (fee != x.expected) {
            _violate(
                string.concat("stable swap: charged != model: ", vm.toString(fee), " vs ", vm.toString(x.expected))
            );
        }
        uint24 floored = StableRefModel.withMin(x.o.feeE6, x.minFee);
        if (fee > floored) _violate("stable swap: the whitelist raised the fee");
        if (2 * fee < x.o.feeE6) _violate("stable swap: the whitelist cut more than 50%");
        if (fee < x.minFee) _violate("stable swap: a swap paid below the minimum");
        if (fee > 100_000) _violate("stable swap: fee above the 10% cap");
        if (x.o.outside) swapsOutside++;
        if (!x.o.isNewBlock) swapsCached++;
        if (fee < x.o.feeE6) swapsDiscounted++;
        if (fee > x.o.feeE6) swapsRaised++;
        if (x.o.adverse) {
            swapsAdverse++;
            if (fee != x.minFee) {
                _violate("stable swap: the side moving away from the reference outside the band paid != the minimum");
            }
        }
        (uint40 d, uint160 sp, uint40 bn) = hook.feeState(x.key.toId());
        if (d != x.o.next.decayingFeeE12 || sp != x.o.next.sqrtAmm || bn != x.o.next.blockNumber) {
            _violate("stable swap: the state word written != the model's");
        }
    }

    struct DiscIn {
        uint16 bps;
        uint24 minFee;
        uint8 dirs;
        uint40 term;
        uint8 mode;
    }

    function discountGrant(uint256 p, uint256 r, DiscIn memory d) external budgeted {
        if (keys.length == 0) return;
        PoolId[] memory one = new PoolId[](1);
        one[0] = keys[p % keys.length].toId();
        uint40 expiry = _shapeDisc(d);
        bool ok = d.bps <= 5_000
            && (d.bps == 0
                || (d.dirs >= 1 && d.dirs <= 3 && expiry > block.timestamp && expiry <= block.timestamp + 90 days));
        bytes memory cd =
            abi.encodeCall(IStableLite.setDiscount, (one, address(routers[r % 3]), d.bps, d.minFee, d.dirs, expiry));
        (bool landed_, bytes memory err) = address(hook).call(cd);
        _outcome("discountGrant", ok, landed_, err, FablesStableFee.InvalidDiscount.selector);
    }

    function _shapeDisc(DiscIn memory d) internal view returns (uint40 expiry) {
        if (d.mode % 4 != 0) {
            d.bps = uint16(bound(d.bps, 1, 5_000));
            d.dirs = uint8(bound(d.dirs, 1, 3));
            d.minFee = uint24(bound(d.minFee, 0, 5_000));
            expiry = uint40(block.timestamp + bound(d.term, 1, 90 days));
        } else {
            d.bps = uint16(bound(d.bps, 0, 6_000));
            d.dirs = uint8(bound(d.dirs, 0, 4));
            expiry = uint40(bound(d.term, 0, block.timestamp + 100 days));
        }
    }

    function discountRevoke(uint256 p, uint256 r) external budgeted {
        if (keys.length == 0) return;
        PoolId[] memory one = new PoolId[](1);
        one[0] = keys[p % keys.length].toId();
        address[] memory who = new address[](1);
        who[0] = address(routers[r % 3]);
        (bool ok, bytes memory err) = address(hook).call(abi.encodeCall(IStableLite.revokeDiscount, (one, who)));
        _outcome("discountRevoke", true, ok, err, bytes4(0));
    }

    function discountFilter(uint256 p, uint8 seed, uint8 subset) external budgeted {
        if (keys.length == 0) return;
        address[] memory list = new address[](3);
        uint256 n;
        for (uint256 i = 0; i < 3; ++i) {
            if ((subset >> i) & 1 == 1) list[n++] = address(routers[i]);
        }
        assembly ("memory-safe") {
            mstore(list, n)
        }
        (bool ok, bytes memory err) = address(hook)
            .call(abi.encodeCall(IStableLite.setDiscountFilter, (keys[p % keys.length].toId(), seed, list)));
        _outcome("discountFilter", true, ok, err, bytes4(0));
    }

    function deposit(uint256 p, uint256 a, uint256 rg, uint256 liq) external budgeted {
        if (keys.length == 0) return;
        _deposit(p % keys.length, a % 3, rg % NRANGES, bound(liq, 1e6, 1e22));
    }

    function _deposit(uint256 p, uint256 a, uint256 k, uint256 liq) internal {
        bytes memory cd = abi.encodeCall(
            FablesLedgerV2.deposit,
            (keys[p], lowers[k], uppers[k], uint128(liq), type(uint128).max, type(uint128).max, block.timestamp)
        );
        vm.prank(actors[a]);
        (bool ok, bytes memory err) = address(hook).call(cd);
        _outcome("deposit", true, ok, err, bytes4(0));
    }

    function withdraw(uint256 p, uint256 a, uint256 rg, uint256 frac) external budgeted {
        if (keys.length == 0) return;
        p %= keys.length;
        address who = actors[a % 3];
        uint256 k = rg % NRANGES;
        uint256 bal = FablesLedgerV2(payable(address(hook))).balanceOf(who, rangeIdAt(p, k));
        if (bal == 0) return;
        bytes memory cd = abi.encodeCall(
            FablesLedgerV2.withdraw,
            (keys[p], lowers[k], uppers[k], uint128(bound(frac, 1, bal)), who, 0, 0, block.timestamp)
        );
        vm.prank(who);
        (bool ok, bytes memory err) = address(hook).call(cd);
        _outcome("withdraw", true, ok, err, bytes4(0));
    }

    function claim(uint256 p, uint256 a, uint256 rg) external budgeted {
        if (keys.length == 0) return;
        p %= keys.length;
        address who = actors[a % 3];
        uint256 k = rg % NRANGES;
        bytes memory cd = abi.encodeCall(FablesLedgerV2.claimFees, (keys[p], lowers[k], uppers[k], who, uint16(0)));
        vm.prank(who);
        (bool ok, bytes memory err) = address(hook).call(cd);
        if (!ok && _sel(err) == FablesLedgerV2.NothingToClaim.selector) return;
        _outcome("claim", true, ok, err, bytes4(0));
    }

    /// @notice The outside LP adds at a random range through the v4 modify-liquidity router.
    function outsideAdd(uint256 p, int24 lower, uint256 width, uint256 liq) external budgeted {
        if (keys.length == 0) return;
        p %= keys.length;
        PoolKey memory key = keys[p];
        int24 ts = key.tickSpacing;
        lower = int24(bound(lower, -3000, 3000)) / ts * ts;
        int24 upper = lower + int24(int256(bound(width, 1, 120))) * ts;
        uint128 l = uint128(bound(liq, 1e6, 1e22));
        bytes32 salt = bytes32(++outsideSalt);
        try lpRouter.modifyLiquidity(
            key, IPoolManager.ModifyLiquidityParams(lower, upper, int256(uint256(l)), salt), ""
        ) {
            landed["outsideAdd"]++;
            if (exclusive) _violate("outsideAdd: the Exclusive build let a direct add through");
            outside.push(Outside(p, lower, upper, l, salt));
        } catch (bytes memory err) {
            refused["outsideAdd"]++;
            if (!exclusive) _violate(string.concat("outsideAdd: refused on the open build: ", vm.toString(err)));
            else if (keccak256(err) != keccak256(_gateRevert())) _violate("outsideAdd: refused without the gate error");
        }
    }

    /// @notice The outside LP removes part or all of one of its positions; removals are open on both builds.
    /// @dev Positions stay at 0 or at least 1e6, so a removal always pays out (the test router asserts it does).
    function outsideRemove(uint256 i, uint256 frac) external budgeted {
        uint256 n = outside.length;
        if (n == 0) return;
        i %= n;
        Outside memory o = outside[i];
        uint128 cut = uint128(bound(frac, 1e6, o.liquidity));
        if (o.liquidity - cut < 1e6) cut = o.liquidity;
        IPoolManager.ModifyLiquidityParams memory params =
            IPoolManager.ModifyLiquidityParams(o.lower, o.upper, -int256(uint256(cut)), o.salt);
        try lpRouter.modifyLiquidity(keys[o.pool], params, "") {
            landed["outsideRemove"]++;
        } catch (bytes memory err) {
            refused["outsideRemove"]++;
            _violate(string.concat("outsideRemove: refused: ", vm.toString(err)));
            return;
        }
        if (cut == o.liquidity) {
            outside[i] = outside[n - 1];
            outside.pop();
        } else {
            outside[i].liquidity = o.liquidity - cut;
        }
    }

    /// @notice A donation to the in-range liquidity; v4 refuses it only when no liquidity is in range.
    function donate(uint256 p, uint256 amount0, uint256 amount1) external budgeted {
        if (keys.length == 0) return;
        PoolKey memory key = keys[p % keys.length];
        bool accepted = manager.getLiquidity(key.toId()) != 0;
        try donateRouter.donate(key, bound(amount0, 0, 1e20), bound(amount1, 0, 1e20), "") {
            landed["donate"]++;
            if (!accepted) _violate("donate: landed with no liquidity in range");
        } catch (bytes memory err) {
            refused["donate"]++;
            if (accepted || _sel(err) != Pool.NoLiquidityToReceiveFees.selector) {
                _violate(string.concat("donate: unexpected revert ", vm.toString(err)));
            }
        }
    }

    function _gateRevert() internal view returns (bytes memory) {
        return abi.encodeWithSelector(
            CustomRevert.WrappedError.selector,
            address(hook),
            IHooks.beforeAddLiquidity.selector,
            abi.encodeWithSelector(FablesExclusiveLiquidityV2.LiquidityOnlyViaLedger.selector),
            abi.encodeWithSelector(Hooks.HookCallFailed.selector)
        );
    }

    function outsideCount() external view returns (uint256) {
        return outside.length;
    }

    function roll(uint256 blocks) external budgeted {
        vm.roll(block.number + bound(blocks, 1, 50));
        vm.warp(block.timestamp + 1);
    }

    function warp(uint256 secs, uint256 blocks) external budgeted {
        vm.warp(block.timestamp + bound(secs, 1, 30 days));
        vm.roll(block.number + bound(blocks, 0, 100_000));
    }

    function rangeIdAt(uint256 p, uint256 k) public view returns (uint256) {
        return FablesLedgerV2(payable(address(hook))).rangeId(keys[p].toId(), lowers[k], uppers[k]);
    }

    function counts(bytes32 name) external view returns (uint256, uint256) {
        return (landed[name], refused[name]);
    }
}

/// @notice Stable Lite fee model plus ledger conservation and share accounting under a fuzzed walk, with an outside LP
///         next to the ledger.
abstract contract StableLiteCategoryInvariantBase is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using CurrencyLibrary for Currency;

    uint256 internal constant Q128 = 1 << 128;
    StableLiteCategoryHandler internal handler;
    address internal hookAddr;
    address[3] internal actors;

    /// @notice The build under test: false = FablesStableHookLite, true = FablesStableHookLiteExclusive.
    function _exclusive() internal pure virtual returns (bool) {
        return false;
    }

    function setUp() public {
        vm.warp(1_800_000_000);
        vm.roll(1_000_000);
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();
        AccessManager authority = new AccessManager(address(this));
        hookAddr = address(uint160(0x57AB << 144) | StableBuild.flags(_exclusive()));
        EtchDeploy.to(StableBuild.creationCode(_exclusive()), abi.encode(manager, address(authority)), hookAddr);
        actors = [makeAddr("slpA"), makeAddr("slpB"), makeAddr("slpC")];
        handler = new StableLiteCategoryHandler(manager, hookAddr, currency0, currency1, actors, _exclusive());
        authority.grantRole(0, address(handler), 0);
        MockERC20(Currency.unwrap(currency0)).transfer(address(handler), 1 << 250);
        MockERC20(Currency.unwrap(currency1)).transfer(address(handler), 1 << 250);
        for (uint256 a = 0; a < 3; ++a) {
            MockERC20(Currency.unwrap(currency0)).transfer(actors[a], 1e32);
            MockERC20(Currency.unwrap(currency1)).transfer(actors[a], 1e32);
        }
        handler.wire();
        handler.createPool(StableLiteCategoryHandler.Cfg(11_744_051, 50, 100, 0, 0), 1);
        require(handler.poolCount() == 1, "seed pool");
        handler.setBudget(Depth.budget(Depth.PR_STEPS));
        targetContract(address(handler));
        targetSelector(StdInvariant.FuzzSelector({addr: address(handler), selectors: handler.fuzzSelectors()}));
    }

    function invariant_stableLiteProperties() public view {
        if (handler.noop()) return;
        _checkHandlerSawNoViolation();
        _checkViewsAgreeWithTheModel();
        _checkLedgerConservation();
    }

    function _checkHandlerSawNoViolation() internal view {
        assertEq(handler.violations(), 0, handler.firstViolation());
    }

    function _checkViewsAgreeWithTheModel() internal view {
        for (uint256 i = 0; i < handler.poolCount(); ++i) {
            PoolKey memory key = handler.keyAt(i);
            PoolId id = key.toId();
            (uint24 k, uint24 opt, uint8 tm, uint160 ref) = IStableLite(hookAddr).feeConfig(id);
            assertGt(k, 0, "k == 0 stored");
            assertLe(opt, 10_000, "optimalFeeE6 above 1%");
            assertTrue(tm >= 1 && tm <= 100, "targetMultiplier outside 1..100");
            (uint40 d, uint160 sp, uint40 bn) = IStableLite(hookAddr).feeState(id);
            (uint160 live,,,) = manager.getSlot0(id);
            for (uint256 s = 0; s < 2; ++s) {
                StableRefModel.Out memory o = StableRefModel.quote(
                    StableRefModel.Config(k, opt, tm, ref), StableRefModel.State(d, sp, bn), live, block.number, s == 0
                );
                uint24 capped = StableRefModel.capped(o.feeE6, FablesLedgerV2(payable(hookAddr)).maxFee(id));
                capped = StableRefModel.withMin(capped, IStableLite(hookAddr).minimumFee(id));
                assertEq(IStableLite(hookAddr).currentFee(id, s == 0), capped, "currentFee != StablePair model + min");
                if (o.adverse) assertEq(o.feeE6, 0, "adverse side priced above 0");
            }
        }
    }

    function _checkLedgerConservation() internal view {
        FablesLedgerV2 l = FablesLedgerV2(payable(hookAddr));
        uint256 q0 = (l.distributorOwed(currency0) + l.claimFeeOwed(currency0)) * Q128;
        uint256 q1 = (l.distributorOwed(currency1) + l.claimFeeOwed(currency1)) * Q128;
        for (uint256 i = 0; i < handler.poolCount(); ++i) {
            for (uint256 k = 0; k < 2; ++k) {
                uint256 rid = handler.rangeIdAt(i, k);
                RangeState memory r = l.rangeState(rid);
                for (uint256 a = 0; a < 3; ++a) {
                    UserPosition memory u = l.userPosition(rid, actors[a]);
                    uint256 unstaked = l.balanceOf(actors[a], rid) - u.staked;
                    q0 += uint256(u.owed0) * Q128 + unstaked * (r.accFee0X128 - u.checkpoint0X128);
                    q1 += uint256(u.owed1) * Q128 + unstaked * (r.accFee1X128 - u.checkpoint1X128);
                }
                (uint128 liq,,) = manager.getPositionInfo(
                    handler.keyAt(i).toId(), hookAddr, handler.lowers(k), handler.uppers(k), bytes32(0)
                );
                assertEq(uint256(r.totalShares), uint256(liq), "range shares != PoolManager liquidity");
            }
        }
        assertLe(q0, manager.balanceOf(hookAddr, currency0.toId()) * Q128, "currency0 over-promised");
        assertLe(q1, manager.balanceOf(hookAddr, currency1.toId()) * Q128, "currency1 over-promised");
    }

    function afterInvariant() public view {
        string[14] memory names = [
            "createPool",
            "updateConfig",
            "swap",
            "deposit",
            "withdraw",
            "claim",
            "discountGrant",
            "discountRevoke",
            "discountFilter",
            "outsideAdd",
            "outsideRemove",
            "donate",
            "setMinimum",
            "moveReference"
        ];
        for (uint256 i = 0; i < names.length; ++i) {
            (uint256 l, uint256 r) = handler.counts(bytes32(bytes(names[i])));
            if (l + r != 0) console.log(string.concat(names[i], " landed/refused"), l, r);
        }
        console.log("pools", handler.poolCount(), "max fee", handler.maxFee());
        console.log("swaps outside / adverse", handler.swapsOutside(), handler.swapsAdverse());
        console.log("swaps cached-price / discounted", handler.swapsCached(), handler.swapsDiscounted());
        console.log("swaps raised to the minimum fee", handler.swapsRaised());
    }

    function test_scriptedWalkReachesEveryRegime() public {
        handler.setBudget(type(uint256).max);
        handler.createPool(StableLiteCategoryHandler.Cfg(8_000_000, 10, 50, 100, 150), 1);
        handler.createPool(StableLiteCategoryHandler.Cfg(16_000_000, 10_000, 1, -50, 40), 1);
        for (uint256 p = 0; p < 3; ++p) {
            handler.swap(p, 0, true, 1e20, false);
            handler.swap(p, 1, true, 1e20, false);
            handler.swap(p, 2, false, 1e20, true);
            handler.roll(3);
            handler.swapLarge(p, 0, p % 2 == 0, 3e22, false);
            handler.roll(10);
            handler.discountGrant(p, 0, StableLiteCategoryHandler.DiscIn(5_000, 0, 3, 1 days, 1));
            handler.swap(p, 0, false, 1e20, false);
            handler.swap(p, 0, true, 1e20, false);
            handler.updateConfig(p, StableLiteCategoryHandler.Cfg(1, 0, 100, 0, 0), 1);
            handler.swap(p, 1, true, 1e20, false);
            handler.setMinimum(p, 150, 1);
            handler.swap(p, 1, true, 1e20, false);
            handler.swap(p, 2, false, 1e20, false);
            handler.moveReference(p, 999_500, 0);
            handler.moveReference(p, 1_000_400, 1);
            handler.moveReference(p, 1_004_000, 4);
            handler.swap(p, 0, p % 2 == 0, 1e20, false);
            handler.setMinimum(p, 0, 0);
            handler.deposit(p, 1, 1, 1e21);
            handler.withdraw(p, 2, 0, 1e20);
            handler.claim(p, 0, 0);
            handler.discountFilter(p, 9, 3);
            handler.discountRevoke(p, 0);
            handler.outsideAdd(p, -600, 20, 1e21);
            handler.swap(p, 2, p % 2 == 1, 1e20, false);
            handler.donate(p, 1e18, 1e18);
            handler.outsideRemove(0, 5e20);
            handler.warp(1 days, 1_000);
        }
        handler.createPool(StableLiteCategoryHandler.Cfg(0, 20_000, 0, 0, 0), 0);
        assertGt(handler.swapsOutside(), 0, "never outside the band");
        assertGt(handler.swapsAdverse(), 0, "no adverse-side swap");
        assertGt(handler.swapsCached(), 0, "no same-block swap");
        assertGt(handler.swapsDiscounted(), 0, "no discounted swap");
        assertGt(handler.swapsRaised(), 0, "no swap raised to the minimum fee");
        (uint256 movesLanded, uint256 movesRefused) = handler.counts("moveReference");
        assertGt(movesLanded, 0, "no reference move landed");
        assertGt(movesRefused, 0, "no reference move refused");
        (uint256 addsLanded, uint256 addsRefused) = handler.counts("outsideAdd");
        if (_exclusive()) assertEq(addsLanded, 0, "a direct add landed on the Exclusive build");
        else assertGt(handler.outsideCount(), 0, "no outside position left open");
        assertEq(addsLanded + addsRefused, 3, "every outside add ran");
        (uint256 donated, uint256 notDonated) = handler.counts("donate");
        assertEq(donated + notDonated, 3, "every donation ran");
        _checkHandlerSawNoViolation();
        _checkViewsAgreeWithTheModel();
        _checkLedgerConservation();
    }
}

/// @notice On FablesStableHookLite.
contract StableLiteCategoryInvariantTest is StableLiteCategoryInvariantBase {}

/// @notice On FablesStableHookLiteExclusive.
contract StableLiteCategoryInvariantExclusiveTest is StableLiteCategoryInvariantBase {
    function _exclusive() internal pure override returns (bool) {
        return true;
    }
}
