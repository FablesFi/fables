// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {FablesHookCore} from "../../src/base/FablesHookCore.sol";
import {FeeRef} from "../../src/libraries/FeeRef.sol";
import {PoolWordLib} from "../../src/libraries/PoolWordLib.sol";
import {DiscountLib} from "../../src/libraries/DiscountLib.sol";
import {FullTestBase} from "../utils/FullTestBase.sol";

/// @notice The assembly swap entry equals its Solidity twin on any stored words and never reverts after the caller
///         gate.
contract FullDifferentialTest is FullTestBase {
    using PoolIdLibrary for PoolKey;
    using PoolWordLib for uint256;

    function setUp() public {
        _deployFull();
    }

    struct Case {
        PoolKey key;
        uint256 word;
        uint256 entry;
        uint256 cf;
        uint256 slot0;
        uint40 time;
        address sender;
        bool zeroForOne;
        int256 amount;
        bytes hookData;
    }

    function _run(Case memory c) internal {
        PoolId id = c.key.toId();
        hook.__setWord(id, c.word);
        hook.__setCF(id, c.cf);
        hook.__setEntry(id, c.sender, c.entry);
        _setSlot0(id, c.slot0);
        vm.warp(c.time);

        (uint256 expFee, uint256 expCf) =
            FeeRef.resolve(c.word, c.zeroForOne, c.sender, c.entry, c.cf, _tickOf(c.slot0), c.time);
        (uint256 twinFee, uint256 twinCf) = hook.resolveFeeRef(id, c.zeroForOne, c.sender);
        assertEq(twinFee, expFee, "twin fee != FeeRef");
        assertEq(twinCf, c.word.cfOn() ? expCf : 0, "twin cfNew != FeeRef (0 while the CF is off: never read)");
        assertEq(uint256(hook.feeFor(id, c.zeroForOne, c.sender)), expFee, "feeFor != FeeRef");
        if (c.sender == address(0)) assertEq(uint256(hook.currentFee(id, c.zeroForOne)), expFee, "currentFee");

        (bool ok, bytes memory ret) =
            _callAsPoolManager(_beforeSwapCalldata(c.key, c.sender, c.zeroForOne, c.amount, c.hookData));
        assertTrue(ok, "reverted after the gate");
        assertEq(_feeWord(ret), expFee | OVERRIDE, "fee");
        assertEq(hook.cfWord(id), expCf, "CF word written");
        assertEq(hook.poolWord(id), c.word, "pool word never written");
        assertEq(hook.entryWord(id, c.sender), c.entry, "entry never written");
    }

    struct AnyIn {
        address currency0;
        address currency1;
        uint24 fee;
        int24 tickSpacing;
        address hooks;
        uint256 word;
        uint256 entry;
        uint256 cf;
        uint256 slot0;
        uint40 time;
        address sender;
        bool zeroForOne;
        int256 amountSpecified;
        bytes hookData;
    }

    function _anyCase(AnyIn memory i) internal pure returns (Case memory c) {
        c.key = PoolKey(Currency.wrap(i.currency0), Currency.wrap(i.currency1), i.fee, i.tickSpacing, IHooks(i.hooks));
        c.word = i.word;
        c.entry = i.entry;
        c.cf = i.cf;
        c.slot0 = i.slot0;
        c.time = i.time;
        c.sender = i.sender;
        c.zeroForOne = i.zeroForOne;
        c.amount = i.amountSpecified;
        c.hookData = i.hookData;
    }

    function testFuzz_anyWords(AnyIn memory i) public {
        _run(_anyCase(i));
    }

    function testFuzz_anyWordsSenderZero(AnyIn memory i) public {
        i.sender = address(0);
        _run(_anyCase(i));
    }

    struct ShapedIn {
        uint256 raw;
        uint24 base0;
        uint24 base1;
        uint24 floor_;
        uint24 cap;
        uint24 poke0;
        uint24 poke1;
        uint32 pokeTtl;
        bool pokeLive;
        uint16 bps;
        uint24 minFee;
        uint8 dirs;
        uint32 discountTtl;
        bool discountLive;
        uint8 seed;
        bool listed;
        CFParams cf;
        bool cfOn;
        int24 tick;
        int16 anchorOffset16;
        uint16 dt;
        uint256 slot0Noise;
        address sender;
        bool zeroForOne;
        uint256 salt;
    }

    function _shapedCase(ShapedIn memory i) internal view returns (Case memory c) {
        uint40 time = uint40(NOW + bound(i.dt, 0, 1000));
        uint256 w = _configuredWord(i.raw, i.base0, i.base1, i.floor_, i.cap);
        {
            uint40 expiry =
                i.pokeLive ? uint40(time + bound(i.pokeTtl, 1, 72 hours)) : uint40(bound(i.pokeTtl, 0, time));
            w = w.withPokes(i.poke0, i.poke1, expiry);
        }
        uint8 seed = i.seed & 0x7f;
        w = w.withSeed(seed);
        if (i.listed) w = w.withBloom(w.bloom() | DiscountLib.mask64(i.sender, seed));
        w = w.withCfOn(i.cfOn);
        c.word = w;
        {
            uint40 dExpiry = i.discountLive
                ? uint40(time + bound(i.discountTtl, 1, 90 days))
                : uint40(bound(i.discountTtl, 0, time));
            c.entry = DiscountLib.pack(uint16(bound(i.bps, 0, 6_000)), i.minFee, uint8(bound(i.dirs, 0, 3)), dExpiry);
        }
        int24 tick = int24(bound(i.tick, TickMath.MIN_TICK, TickMath.MAX_TICK));
        i.cf.tLast = uint40(NOW);
        i.cf.anchor = int32(int256(tick) * 256 + int256(i.anchorOffset16) * 16);
        c.cf = _legalCF(i.cf);
        c.slot0 = (i.slot0Noise & ~(uint256(0xffffff) << 160)) | (uint256(uint24(tick)) << 160);
        c.time = time;
        c.key = _key(i.salt);
        c.sender = i.sender;
        c.zeroForOne = i.zeroForOne;
        c.amount = -1e18;
    }

    function testFuzz_shapedWords(ShapedIn memory i) public {
        _run(_shapedCase(i));
    }

    function test_shapedGeneratorReachesTheHotBranches() public {
        ShapedIn memory i;
        i.cap = 10_000;
        i.base0 = 5_000;
        i.base1 = 5_000;
        i.bps = 2_000;
        i.dirs = 3;
        i.discountLive = true;
        i.discountTtl = 1 days;
        i.listed = true;
        i.sender = address(0xBEEF);
        i.cfOn = true;
        i.cf.k = 256;
        i.cf.cfCap = 2_500;
        i.cf.tau = 60;
        i.cf.period = 1;
        i.tick = 1000;
        i.anchorOffset16 = 100 * 16;
        i.dt = 5;
        i.zeroForOne = true;
        Case memory c = _shapedCase(i);
        _run(c);
        PoolId id = c.key.toId();
        assertEq(_swapFee(c.key, i.sender, true), 6_500);
        assertEq(uint256(hook.currentFee(id, true)), 7_500, "sender-free: 5000 + 2500");
        assertEq(hook.cfWord(id) & 0xffffffffff, c.time, "CF word written (tLast = now)");
    }

    function testFuzz_neverRevertsAfterTheGate(AnyIn memory i) public {
        Case memory c = _anyCase(i);
        PoolId id = c.key.toId();
        hook.__setWord(id, c.word);
        hook.__setCF(id, c.cf);
        hook.__setEntry(id, c.sender, c.entry);
        _setSlot0(id, c.slot0);
        vm.warp(c.time);
        (bool ok, bytes memory ret) =
            _callAsPoolManager(_beforeSwapCalldata(c.key, c.sender, c.zeroForOne, c.amount, c.hookData));
        assertTrue(ok, "reverted");
        assertLe(_feeWord(ret) & ~OVERRIDE, c.word.cap(), "fee <= cap on any word");
    }

    function testFuzz_garbageCalldataNeverReverts(bytes memory tail) public {
        (bool ok, bytes memory ret) = _callAsPoolManager(abi.encodePacked(IHooks.beforeSwap.selector, tail));
        assertTrue(ok, "reverted");
        _feeWord(ret);
    }

    function test_extsloadFailureAddsNoCFAndWritesNothing() public {
        PoolKey memory key = _key(1);
        PoolId id = key.toId();
        uint256 w = _configuredWord(0, 3_000, 3_000, 0, 50_000).withCfOn(true);
        hook.__setWord(id, w);
        CFParams memory p = CFParams(0, 256, 2_500, 0, 60, 1, uint40(NOW), int32(200 * 256));
        uint256 cf = _legalCF(p);
        hook.__setCF(id, cf);
        _setTick(id, 100);
        vm.warp(NOW + 1);
        vm.etch(address(manager), "");
        assertEq(_swapFee(key, address(1), true), 3_000, "no CF without a slot0");
        assertEq(hook.cfWord(id), cf, "no write without a slot0");
    }

    function _validCalldata() internal view returns (bytes memory) {
        return _beforeSwapCalldata(_key(7), address(0xBEEF), true, -1e18, "");
    }

    function _notPoolManager() internal pure returns (bytes memory) {
        return abi.encodeWithSelector(FablesHookCore.NotPoolManager.selector);
    }

    function testFuzz_gate_rejectsEveryCallerButThePoolManager(address caller) public {
        vm.assume(caller != address(manager));
        vm.prank(caller);
        (bool ok, bytes memory ret) = hookAddr.call(_validCalldata());
        assertFalse(ok);
        assertEq(ret, _notPoolManager());
    }

    function test_gate_rejectsOtherSelectorsFromThePoolManager() public {
        bytes4[5] memory sels = [
            bytes4(0),
            IHooks.afterSwap.selector,
            IHooks.beforeAddLiquidity.selector,
            IHooks.beforeDonate.selector,
            bytes4(0xffffffff)
        ];
        for (uint256 k = 0; k < sels.length; ++k) {
            bytes memory cd = _validCalldata();
            cd[0] = sels[k][0];
            cd[1] = sels[k][1];
            cd[2] = sels[k][2];
            cd[3] = sels[k][3];
            (bool ok, bytes memory ret) = _callAsPoolManager(cd);
            assertFalse(ok, "another selector passed the gate");
            assertEq(ret, _notPoolManager());
        }
    }

    function test_gate_rejectsShortAndEmptyCalldata() public {
        (bool ok, bytes memory ret) = _callAsPoolManager(hex"575e24");
        assertFalse(ok);
        assertEq(ret, _notPoolManager());
        (ok, ret) = _callAsPoolManager("");
        assertFalse(ok);
        assertEq(ret, _notPoolManager());
        vm.prank(address(0xBEEF));
        (ok, ret) = hookAddr.call("");
        assertFalse(ok, "no receive(): plain calls revert");
        assertEq(ret, _notPoolManager());
    }

    function test_gate_isNotPayable() public {
        vm.deal(address(manager), 1 ether);
        vm.prank(address(manager));
        (bool ok, bytes memory ret) = hookAddr.call{value: 1}(_validCalldata());
        assertFalse(ok, "value accepted");
        assertEq(ret.length, 0, "non-payable fallback reverts with no data");
    }

    function test_gate_typedCallFromThePoolManagerIsServed() public {
        PoolKey memory key = _key(3);
        hook.__setWord(key.toId(), _configuredWord(0, 1_234, 4_321, 0, 50_000));
        vm.prank(address(manager));
        (bytes4 sel,, uint24 fee) = IHooks(hookAddr)
            .beforeSwap(
                address(0xBEEF),
                key,
                IPoolManager.SwapParams({
                zeroForOne: false, amountSpecified: -1e18, sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
                ""
            );
        assertEq(sel, IHooks.beforeSwap.selector);
        assertEq(fee, 4_321 | LPFeeLibrary.OVERRIDE_FEE_FLAG);
    }

    function test_constantsMatchTheirSources() public view {
        assertEq(hook.BEFORE_SWAP_SELECTOR(), uint32(IHooks.beforeSwap.selector));
        assertEq(hook.NOT_POOL_MANAGER_SELECTOR(), uint32(FablesHookCore.NotPoolManager.selector));
        assertEq(hook.EXTSLOAD_SELECTOR(), uint32(bytes4(keccak256("extsload(bytes32)"))));
        assertEq(hook.PM_POOLS_SLOT(), uint256(StateLibrary.POOLS_SLOT));
        assertEq(hook.OVERRIDE_FEE_FLAG(), LPFeeLibrary.OVERRIDE_FEE_FLAG);
    }

    function testFuzz_storageSlotConstantsMatchTheLayout(PoolId id, address account, uint256 w, uint256 cf, uint256 e)
        public
    {
        hook.__setWord(id, w);
        hook.__setCF(id, cf);
        hook.__setEntry(id, account, e);
        assertEq(uint256(vm.load(hookAddr, keccak256(abi.encode(id, hook.WORD_SLOT())))), w, "WORD_SLOT");
        assertEq(uint256(vm.load(hookAddr, keccak256(abi.encode(id, hook.CF_SLOT())))), cf, "CF_SLOT");
        bytes32 inner = keccak256(abi.encode(id, hook.ENTRY_SLOT()));
        assertEq(uint256(vm.load(hookAddr, keccak256(abi.encode(account, inner)))), e, "ENTRY_SLOT");
    }
}
