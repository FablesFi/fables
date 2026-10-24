// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {RCBytecode} from "./RCBytecode.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @notice Universal Router surface used here; command 0x10 is V4_SWAP.
interface IUniversalRouter {
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable;
}

interface IPermit2 {
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
}

struct ExactInputSingleParams {
    PoolKey poolKey;
    bool zeroForOne;
    uint128 amountIn;
    uint128 amountOutMinimum;
    uint256 minHopPriceX36;
    bytes hookData;
}

struct PathKey {
    Currency intermediateCurrency;
    uint24 fee;
    int24 tickSpacing;
    IHooks hooks;
    bytes hookData;
}

struct ExactInputParams {
    Currency currencyIn;
    PathKey[] path;
    uint256[] minHopPriceX36;
    uint128 amountIn;
    uint128 amountOutMinimum;
}

/// @notice Liquidity provider with its own unlock callback, paying with plain ERC20 transfers.
contract LiqHelper is IUnlockCallback {
    IPoolManager internal immutable pm;

    constructor(IPoolManager _pm) {
        pm = _pm;
    }

    function modify(PoolKey memory key, int24 lo, int24 hi, int256 liquidityDelta, bytes32 salt)
        external
        returns (BalanceDelta)
    {
        return abi.decode(pm.unlock(abi.encode(key, lo, hi, liquidityDelta, salt)), (BalanceDelta));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(pm), "LiqHelper: not pm");
        (PoolKey memory key, int24 lo, int24 hi, int256 liq, bytes32 salt) =
            abi.decode(data, (PoolKey, int24, int24, int256, bytes32));
        (BalanceDelta d,) = pm.modifyLiquidity(
            key, IPoolManager.ModifyLiquidityParams({tickLower: lo, tickUpper: hi, liquidityDelta: liq, salt: salt}), ""
        );
        _settle(key.currency0, d.amount0());
        _settle(key.currency1, d.amount1());
        return abi.encode(d);
    }

    function _settle(Currency c, int128 amt) internal {
        if (amt < 0) {
            pm.sync(c);
            IERC20(Currency.unwrap(c)).transfer(address(pm), uint128(-amt));
            pm.settle();
        } else if (amt > 0) {
            pm.take(c, address(this), uint128(amt));
        }
    }
}

/// @notice Cheap state-changing call used to detect `forge test --isolate`.
contract IsolateProbe {
    event Pinged();

    function ping() external {
        emit Pinged();
    }
}

/// @notice Robinhood Chain PoolManager, Universal Router and Permit2 runtime bytecode etched at their chain addresses,
///         with pool, liquidity, swap and gas helpers.
abstract contract RCBytecodeHarness is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    address internal constant PM_ADDR = RCBytecode.POOLMANAGER_ADDR;
    address internal constant UR_ADDR = RCBytecode.UNIVERSALROUTER_ADDR;
    address internal constant PERMIT2_ADDR = RCBytecode.PERMIT2_ADDR;
    uint256 internal constant RC_CHAIN_ID = RCBytecode.CHAIN_ID;

    uint24 internal constant DYNAMIC_FEE = LPFeeLibrary.DYNAMIC_FEE_FLAG;
    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    int24 internal constant MID_WORD_TICK = 7710;
    uint256 internal constant TX_INTRINSIC = 21_000;

    uint160 internal constant FLAGS_FEE_FULL = 0x2080;
    uint160 internal constant FLAGS_FEE_FULL_EXCLUSIVE = 0x2880;
    uint160 internal constant FLAGS_STABLE_LITE = 0x2080;
    uint160 internal constant FLAGS_STABLE_LITE_EXCLUSIVE = 0x2880;

    IPoolManager internal pm = IPoolManager(PM_ADDR);
    IUniversalRouter internal ur = IUniversalRouter(UR_ADDR);
    PoolSwapTest internal swapRouter;
    PoolModifyLiquidityTest internal lpRouter;
    LiqHelper internal liq;
    IsolateProbe internal probe;

    MockERC20 internal tokA;
    MockERC20 internal tokB;
    MockERC20 internal tokC;
    Currency internal c0;
    Currency internal c1;
    Currency internal c2;

    address internal trader = address(uint160(uint256(keccak256("harness.trader"))));
    uint256 internal constant MINT = 1e38;

    struct GasSample {
        uint256 txGas;
        uint256 calldataGas;
        uint256 execGas;
        bool isolated;
    }

    function setUpRC() internal {
        setUpRC(18, 18, 18);
    }

    function setUpRC(uint8 dA, uint8 dB, uint8 dC) internal {
        etchRC();
        probe = new IsolateProbe();
        liq = new LiqHelper(pm);
        swapRouter = new PoolSwapTest(pm);
        lpRouter = new PoolModifyLiquidityTest(pm);

        MockERC20[3] memory t;
        t[0] = new MockERC20("Token A", "TKA", dA);
        t[1] = new MockERC20("Token B", "TKB", dB);
        t[2] = new MockERC20("Token C", "TKC", dC);
        for (uint256 i; i < 3; i++) {
            for (uint256 j = i + 1; j < 3; j++) {
                if (address(t[j]) < address(t[i])) (t[i], t[j]) = (t[j], t[i]);
            }
        }
        (tokA, tokB, tokC) = (t[0], t[1], t[2]);
        c0 = Currency.wrap(address(tokA));
        c1 = Currency.wrap(address(tokB));
        c2 = Currency.wrap(address(tokC));
        vm.label(address(tokA), "c0");
        vm.label(address(tokB), "c1");
        vm.label(address(tokC), "c2");
        for (uint256 i; i < 3; i++) {
            fundAndApprove(address(t[i]), trader);
            t[i].mint(address(liq), MINT);
            t[i].mint(address(this), MINT);
            t[i].approve(address(swapRouter), type(uint256).max);
            t[i].approve(address(lpRouter), type(uint256).max);
        }
    }

    function etchRC() internal {
        vm.chainId(RC_CHAIN_ID);
        if (block.timestamp < 1_790_000_000) vm.warp(1_790_000_000);
        if (block.number < 78_000_000) vm.roll(78_000_000);
        _etchChecked(PM_ADDR, RCBytecode.poolManager(), RCBytecode.PM_CODEHASH, "PoolManager(RC)");
        _etchChecked(UR_ADDR, RCBytecode.universalRouter(), RCBytecode.UR_CODEHASH, "UniversalRouter(RC)");
        _etchChecked(PERMIT2_ADDR, RCBytecode.permit2(), RCBytecode.PERMIT2_CODEHASH, "Permit2(RC)");
    }

    function _etchChecked(address at, bytes memory code, bytes32 expectedHash, string memory label) private {
        require(keccak256(code) == expectedHash, string.concat("RCBytecode: corrupted blob ", label));
        vm.etch(at, code);
        vm.label(at, label);
    }

    function fundAndApprove(address token, address who) internal {
        MockERC20(token).mint(who, MINT);
        approvePermit2ForUR(token, who);
    }

    function approvePermit2ForUR(address token, address who) internal {
        vm.startPrank(who);
        IERC20(token).approve(PERMIT2_ADDR, type(uint256).max);
        IPermit2(PERMIT2_ADDR).approve(token, UR_ADDR, type(uint160).max, type(uint48).max);
        vm.stopPrank();
    }

    function flagged(string memory tag, uint160 flags) internal pure returns (address) {
        return address((uint160(uint256(keccak256(bytes(tag)))) & ~uint160(Hooks.ALL_HOOK_MASK)) | flags);
    }

    function poolKey(Currency a, Currency b, uint24 fee, int24 tickSpacing, address hook)
        internal
        pure
        returns (PoolKey memory)
    {
        return PoolKey(a, b, fee, tickSpacing, IHooks(hook));
    }

    function dynamicKey(Currency a, Currency b, int24 tickSpacing, address hook)
        internal
        pure
        returns (PoolKey memory)
    {
        return PoolKey(a, b, DYNAMIC_FEE, tickSpacing, IHooks(hook));
    }

    function createPool(PoolKey memory key, uint160 sqrtPriceX96) internal returns (PoolId) {
        pm.initialize(key, sqrtPriceX96);
        return key.toId();
    }

    function createPoolIfNeeded(PoolKey memory key, uint160 sqrtPriceX96)
        internal
        returns (PoolId id, uint160 sqrtPriceNow, int24 tickNow)
    {
        id = key.toId();
        (sqrtPriceNow, tickNow,,) = pm.getSlot0(id);
        if (sqrtPriceNow == 0) {
            pm.initialize(key, sqrtPriceX96);
            (sqrtPriceNow, tickNow,,) = pm.getSlot0(id);
        }
    }

    function addLiquidity(PoolKey memory key, int24 lo, int24 hi, int256 liquidityDelta)
        internal
        returns (BalanceDelta)
    {
        return liq.modify(key, lo, hi, liquidityDelta, bytes32(0));
    }

    function addFullRange(PoolKey memory key, int256 liquidityDelta) internal returns (BalanceDelta) {
        int24 ts = key.tickSpacing;
        int24 lo = (TickMath.MIN_TICK / ts) * ts;
        int24 hi = (TickMath.MAX_TICK / ts) * ts;
        return addLiquidity(key, lo, hi, liquidityDelta);
    }

    function addLiquidityViaRouter(PoolKey memory key, int24 lo, int24 hi, int256 liquidityDelta, bytes32 salt)
        internal
        returns (BalanceDelta)
    {
        return lpRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: lo, tickUpper: hi, liquidityDelta: liquidityDelta, salt: salt
            }),
            ""
        );
    }

    function seedAndWarm(PoolKey memory key, uint160 sqrtPriceX96, int256 liquidity, uint128 warmAmount)
        internal
        returns (PoolId id)
    {
        id = createPool(key, sqrtPriceX96);
        addFullRange(key, liquidity);
        warm(key, warmAmount);
    }

    function warm(PoolKey memory key, uint128 amount) internal {
        warm(key, amount, amount);
    }

    function warm(PoolKey memory key, uint128 amount0In, uint128 amount1In) internal {
        swapUR(key, true, amount0In);
        swapUR(key, false, amount1In);
    }

    function swapUR(PoolKey memory key, bool zeroForOne, uint128 amountIn) internal returns (GasSample memory) {
        return execUR(urSingleInput(key, zeroForOne, amountIn, 0));
    }

    function swapURDouble(PoolKey memory key, bool zeroForOne, uint128 amountIn) internal returns (GasSample memory) {
        return execUR(urDoubleInput(key, zeroForOne, amountIn));
    }

    function swapURTwoHop(
        Currency cin,
        PoolKey memory k1,
        Currency mid,
        PoolKey memory k2,
        Currency out,
        uint128 amountIn
    ) internal returns (GasSample memory) {
        return execUR(urTwoHopInput(cin, k1, mid, k2, out, amountIn));
    }

    function execUR(bytes memory input) internal returns (GasSample memory s) {
        return execURFrom(trader, input);
    }

    function execURFrom(address from, bytes memory input) internal returns (GasSample memory s) {
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = input;
        bytes memory cd = abi.encodeCall(IUniversalRouter.execute, (hex"10", inputs, block.timestamp + 1000));
        vm.prank(from);
        (bool ok, bytes memory ret) = UR_ADDR.call(cd);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(ret, 0x20), mload(ret))
            }
        }
        s = _sample(vm.lastCallGas(), cd);
    }

    function urSingleInput(PoolKey memory key, bool zeroForOne, uint128 amountIn, uint128 amountOutMinimum)
        internal
        pure
        returns (bytes memory)
    {
        bytes memory actions = abi.encodePacked(uint8(0x06), uint8(0x0c), uint8(0x0f));
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            ExactInputSingleParams({
                poolKey: key,
                zeroForOne: zeroForOne,
                amountIn: amountIn,
                amountOutMinimum: amountOutMinimum,
                minHopPriceX36: 0,
                hookData: ""
            })
        );
        (Currency cin, Currency cout) = zeroForOne ? (key.currency0, key.currency1) : (key.currency1, key.currency0);
        params[1] = abi.encode(cin, uint256(type(uint128).max));
        params[2] = abi.encode(cout, uint256(0));
        return abi.encode(actions, params);
    }

    function urDoubleInput(PoolKey memory key, bool zeroForOne, uint128 amountIn) internal pure returns (bytes memory) {
        bytes memory actions = abi.encodePacked(uint8(0x06), uint8(0x06), uint8(0x0c), uint8(0x0f));
        bytes[] memory params = new bytes[](4);
        params[0] = abi.encode(
            ExactInputSingleParams({
                poolKey: key,
                zeroForOne: zeroForOne,
                amountIn: amountIn,
                amountOutMinimum: 0,
                minHopPriceX36: 0,
                hookData: ""
            })
        );
        params[1] = params[0];
        (Currency cin, Currency cout) = zeroForOne ? (key.currency0, key.currency1) : (key.currency1, key.currency0);
        params[2] = abi.encode(cin, uint256(type(uint128).max));
        params[3] = abi.encode(cout, uint256(0));
        return abi.encode(actions, params);
    }

    function urTwoHopInput(
        Currency cin,
        PoolKey memory k1,
        Currency mid,
        PoolKey memory k2,
        Currency out,
        uint128 amountIn
    ) internal pure returns (bytes memory) {
        bytes memory actions = abi.encodePacked(uint8(0x07), uint8(0x0c), uint8(0x0f));
        bytes[] memory params = new bytes[](3);
        PathKey[] memory path = new PathKey[](2);
        path[0] = PathKey(mid, k1.fee, k1.tickSpacing, k1.hooks, "");
        path[1] = PathKey(out, k2.fee, k2.tickSpacing, k2.hooks, "");
        params[0] = abi.encode(
            ExactInputParams({
                currencyIn: cin, path: path, minHopPriceX36: new uint256[](2), amountIn: amountIn, amountOutMinimum: 0
            })
        );
        params[1] = abi.encode(cin, uint256(type(uint128).max));
        params[2] = abi.encode(out, uint256(0));
        return abi.encode(actions, params);
    }

    function swapPST(PoolKey memory key, bool zeroForOne, int256 amountSpecified)
        internal
        returns (BalanceDelta delta, GasSample memory s)
    {
        return swapPST(key, zeroForOne, amountSpecified, "");
    }

    function swapPST(PoolKey memory key, bool zeroForOne, int256 amountSpecified, bytes memory hookData)
        internal
        returns (BalanceDelta delta, GasSample memory s)
    {
        IPoolManager.SwapParams memory p = IPoolManager.SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: amountSpecified,
            sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });
        PoolSwapTest.TestSettings memory ts = PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
        bytes memory cd = abi.encodeCall(PoolSwapTest.swap, (key, p, ts, hookData));
        (bool ok, bytes memory ret) = address(swapRouter).call(cd);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(ret, 0x20), mload(ret))
            }
        }
        delta = abi.decode(ret, (BalanceDelta));
        s = _sample(vm.lastCallGas(), cd);
    }

    function hookOnlyGas(address hook, PoolKey memory key, bool zeroForOne, int256 amountSpecified)
        internal
        returns (uint256 gas, bytes memory ret)
    {
        bytes memory cd = abi.encodeCall(
            IHooks.beforeSwap,
            (
                UR_ADDR,
                key,
                IPoolManager.SwapParams({
                    zeroForOne: zeroForOne,
                    amountSpecified: amountSpecified,
                    sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
                }),
                bytes("")
            )
        );
        vm.prank(PM_ADDR);
        bool ok;
        (ok, ret) = hook.call(cd);
        if (!ok) return (0, ret);
        VmSafe.Gas memory g = vm.lastCallGas();
        gas = isolated() ? g.gasTotalUsed - TX_INTRINSIC - calldataGas(cd) : g.gasTotalUsed;
    }

    function feeFromBeforeSwapReturn(bytes memory ret) internal pure returns (uint24) {
        if (ret.length != 96) return 0;
        uint256[3] memory words = abi.decode(ret, (uint256[3]));
        return uint24(words[2] & 0x3fffff);
    }

    function isolated() internal returns (bool) {
        if (_isolatedCache == 0) {
            if (address(probe) == address(0)) probe = new IsolateProbe();
            probe.ping();
            _isolatedCache = vm.lastCallGas().gasTotalUsed >= TX_INTRINSIC ? 1 : 2;
        }
        return _isolatedCache == 1;
    }

    uint8 private _isolatedCache;

    function calldataGas(bytes memory cd) internal pure returns (uint256 g) {
        for (uint256 i; i < cd.length; i++) {
            g += cd[i] == 0 ? 4 : 16;
        }
    }

    function _sample(VmSafe.Gas memory g, bytes memory cd) internal returns (GasSample memory s) {
        s.txGas = g.gasTotalUsed;
        s.calldataGas = calldataGas(cd);
        s.isolated = isolated();
        s.execGas = s.isolated ? s.txGas - TX_INTRINSIC - s.calldataGas : s.txGas;
    }

    function execDelta(GasSample memory hooked, GasSample memory base) internal pure returns (int256) {
        return int256(hooked.execGas) - int256(base.execGas);
    }

    function logRow(string memory name, string memory scenario, GasSample memory s) internal pure {
        console.log(
            string.concat(
                "ROW|",
                name,
                "|",
                scenario,
                "|",
                vm.toString(s.txGas),
                "|",
                vm.toString(s.calldataGas),
                "|",
                vm.toString(s.execGas)
            )
        );
    }

    function slot0(PoolId id)
        internal
        view
        returns (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee)
    {
        return pm.getSlot0(id);
    }

    function liquidityOf(PoolId id) internal view returns (uint128) {
        return pm.getLiquidity(id);
    }
}

/// @notice Hookless static-fee pools of the same shape as the pool under test, measured through the same paths so tests
///         assert gas deltas.
abstract contract HooklessBaseline is RCBytecodeHarness {
    struct Shape {
        uint24 fee;
        int24 tickSpacing;
        uint160 sqrtPriceX96;
        int256 liquidity;
        uint128 amountIn;
    }

    struct Baseline {
        GasSample single0for1;
        GasSample single1for0;
        GasSample doubleSamePool;
        GasSample twoHop;
        GasSample pst0for1;
        GasSample pst1for0;
        PoolKey k1;
        PoolKey k2;
    }

    function defaultShape() internal pure returns (Shape memory) {
        return Shape({
            fee: 3000,
            tickSpacing: 60,
            sqrtPriceX96: TickMath.getSqrtPriceAtTick(MID_WORD_TICK),
            liquidity: 1e24,
            amountIn: 1e18
        });
    }

    function hooklessBaseline(Shape memory s) internal returns (Baseline memory b) {
        b.k1 = poolKey(c0, c1, s.fee, s.tickSpacing, address(0));
        b.k2 = poolKey(c1, c2, s.fee, s.tickSpacing, address(0));
        seedAndWarm(b.k1, s.sqrtPriceX96, s.liquidity, s.amountIn);
        seedAndWarm(b.k2, s.sqrtPriceX96, s.liquidity, s.amountIn);
        b.single0for1 = swapUR(b.k1, true, s.amountIn);
        b.single1for0 = swapUR(b.k1, false, s.amountIn);
        b.doubleSamePool = swapURDouble(b.k1, true, s.amountIn);
        b.twoHop = swapURTwoHop(c0, b.k1, c1, b.k2, c2, s.amountIn);
        (, b.pst0for1) = swapPST(b.k1, true, -int256(uint256(s.amountIn)));
        (, b.pst1for0) = swapPST(b.k1, false, -int256(uint256(s.amountIn)));
    }

    function measureHooked(PoolKey memory k1, PoolKey memory k2, uint128 amountIn)
        internal
        returns (Baseline memory h)
    {
        h.k1 = k1;
        h.k2 = k2;
        h.single0for1 = swapUR(k1, true, amountIn);
        h.single1for0 = swapUR(k1, false, amountIn);
        h.doubleSamePool = swapURDouble(k1, true, amountIn);
        h.twoHop = swapURTwoHop(c0, k1, c1, k2, c2, amountIn);
        (, h.pst0for1) = swapPST(k1, true, -int256(uint256(amountIn)));
        (, h.pst1for0) = swapPST(k1, false, -int256(uint256(amountIn)));
    }

    function logBaseline(string memory name, Baseline memory b) internal pure {
        logRow(name, "single_0for1", b.single0for1);
        logRow(name, "single_1for0", b.single1for0);
        logRow(name, "double_same_pool", b.doubleSamePool);
        logRow(name, "twohop", b.twoHop);
        logRow(name, "pst_0for1", b.pst0for1);
        logRow(name, "pst_1for0", b.pst1for0);
    }
}
