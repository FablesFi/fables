// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import "../../utils/StableTestBase.sol";
import {FablesHookCore} from "../../../src/base/FablesHookCore.sol";
import {FablesLedgerV2} from "../../../src/base/FablesLedgerV2.sol";

/// @notice The two Stable Lite builds side by side: flag words, the liquidity gate and hook-only pool creation.
contract StableLiteBuildsTest is StableTestBase {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    int24 internal constant LO = INIT_TICK - 60;
    int24 internal constant HI = INIT_TICK + 60;

    address internal open;
    address internal excl;

    function setUp() public {
        setUpChain();
        open = _deployBuild("b-open", false);
        excl = _deployBuild("b-excl", true);
    }

    function _k(address h) internal view returns (PoolKey memory) {
        return PoolKey(c0, c1, DYN, 1, IHooks(h));
    }

    function _configure(address h) internal returns (PoolKey memory k) {
        k = _k(h);
        (StableFeeConfig memory c, uint160 p0) = _cfgIn();
        _createPool(h, k, p0, c);
    }

    function _construct(bool exclusive, address at) internal returns (bool ok, bytes memory ret) {
        vm.etch(at, abi.encodePacked(StableBuild.creationCode(exclusive), abi.encode(PM_ADDR, address(authority))));
        (ok, ret) = at.call("");
    }

    function test_eachBuildDeploysOnlyAtItsOwnFlagWord() public {
        uint160[9] memory words = [uint160(0x0000), 0x2000, 0x0080, 0x0800, 0x2080, 0x2880, 0x2A80, 0x3880, 0x3FFF];
        for (uint256 e; e < 2; e++) {
            bool exclusive = e == 1;
            for (uint256 w; w < words.length; w++) {
                address at = address(uint160((0x5B00 + e * 16 + w) << 144) | words[w]);
                (bool ok, bytes memory ret) = _construct(exclusive, at);
                if (words[w] == StableBuild.flags(exclusive)) {
                    assertTrue(ok, string.concat(StableBuild.name(exclusive), " refused its own flag word"));
                    continue;
                }
                assertFalse(ok, string.concat(StableBuild.name(exclusive), " accepted a foreign flag word"));
                assertEq(
                    ret, abi.encodeWithSelector(Hooks.HookAddressNotValid.selector, at), StableBuild.name(exclusive)
                );
            }
        }
        assertEq(StableBuild.flags(false), 0x2080, "open build: beforeInitialize | beforeSwap");
        assertEq(StableBuild.flags(true), 0x2880, "Exclusive build: + beforeAddLiquidity");
    }

    function test_eachBuildRevertsAtTheOtherBuildsFlags() public {
        address atExclusiveWord = flagged("b-cross-open", LITE_EXCLUSIVE_FLAGS);
        vm.expectRevert(abi.encodeWithSelector(Hooks.HookAddressNotValid.selector, atExclusiveWord));
        deployCodeTo(StableBuild.artifact(false), abi.encode(PM_ADDR, address(authority)), atExclusiveWord);
        address atOpenWord = flagged("b-cross-excl", LITE_FLAGS);
        vm.expectRevert(abi.encodeWithSelector(Hooks.HookAddressNotValid.selector, atOpenWord));
        deployCodeTo(StableBuild.artifact(true), abi.encode(PM_ADDR, address(authority)), atOpenWord);
    }

    function test_openBuildHasNoBeforeAddLiquidity() public {
        PoolKey memory k = _configure(open);
        assertFalse(Hooks.hasPermission(IHooks(open), Hooks.BEFORE_ADD_LIQUIDITY_FLAG), "open: flag unset");
        assertTrue(Hooks.hasPermission(IHooks(excl), Hooks.BEFORE_ADD_LIQUIDITY_FLAG), "Exclusive: flag set");
        bytes memory cd = abi.encodeCall(
            IHooks.beforeAddLiquidity,
            (address(this), k, IPoolManager.ModifyLiquidityParams(LO, HI, 1e18, 0), bytes(""))
        );
        vm.prank(PM_ADDR);
        (bool ok, bytes memory ret) = open.call(cd);
        assertFalse(ok, "open: not implemented");
        assertEq(ret, abi.encodeWithSelector(FablesStableFee.HookNotImplemented.selector));
        (ok, ret) = open.call(cd);
        assertEq(ret, abi.encodeWithSelector(FablesHookCore.NotPoolManager.selector), "open: stranger");

        vm.prank(PM_ADDR);
        (ok, ret) = excl.call(cd);
        assertFalse(ok, "Exclusive: a stranger's add is refused");
        assertEq(ret, abi.encodeWithSelector(FablesExclusiveLiquidityV2.LiquidityOnlyViaLedger.selector));
        vm.prank(PM_ADDR);
        (ok, ret) = excl.call(
            abi.encodeCall(
                IHooks.beforeAddLiquidity, (excl, k, IPoolManager.ModifyLiquidityParams(LO, HI, 1e18, 0), bytes(""))
            )
        );
        assertTrue(ok, "Exclusive: the ledger's own add passes");
        assertEq(abi.decode(ret, (bytes4)), IHooks.beforeAddLiquidity.selector);
    }

    function test_directAddAndRemove_openAccepts_exclusiveRefuses() public {
        PoolKey memory ko = _configure(open);
        PoolKey memory ke = _configure(excl);

        _addDirect(ko, LO, HI, 1e21);
        addLiquidityViaRouter(ko, LO, HI, 2e21, bytes32(uint256(7)));
        assertEq(pm.getLiquidity(ko.toId()), 3e21, "open: direct adds landed");
        _removeDirect(ko, LO, HI, 1e21);
        addLiquidityViaRouter(ko, LO, HI, -2e21, bytes32(uint256(7)));
        assertEq(pm.getLiquidity(ko.toId()), 0, "open: direct removes landed");

        vm.expectRevert(_gateRevert(excl));
        _addDirect(ke, LO, HI, 1e21);
        vm.expectRevert(_gateRevert(excl));
        addLiquidityViaRouter(ke, LO, HI, 2e21, bytes32(uint256(7)));
        assertEq(pm.getLiquidity(ke.toId()), 0, "Exclusive: nothing landed");

        PoolKey[2] memory ks = [ko, ke];
        for (uint256 i; i < 2; i++) {
            FablesLedgerV2 l = FablesLedgerV2(payable(address(ks[i].hooks)));
            _addLiq(address(ks[i].hooks), ks[i], LO, HI, 1e21);
            assertEq(pm.getLiquidity(ks[i].toId()), 1e21, "ledger deposit");
            assertEq(l.balanceOf(address(this), l.rangeId(ks[i].toId(), LO, HI)), 1e21, "receipts");
            _removeLiq(address(ks[i].hooks), ks[i], LO, HI, 1e21);
            assertEq(pm.getLiquidity(ks[i].toId()), 0, "ledger withdraw");
        }
    }

    function test_poolCreationStaysHookOnly_onBothBuilds() public {
        address[2] memory hs = [open, excl];
        for (uint256 i; i < 2; i++) {
            PoolKey memory k = _k(hs[i]);
            vm.expectRevert(
                abi.encodeWithSelector(
                    CustomRevert.WrappedError.selector,
                    hs[i],
                    IHooks.beforeInitialize.selector,
                    abi.encodeWithSelector(FablesStableFee.InvalidInitializer.selector, address(this)),
                    abi.encodeWithSelector(Hooks.HookCallFailed.selector)
                )
            );
            pm.initialize(k, SQRT_1_1);
            _configure(hs[i]);
            (uint160 sqrtP,,,) = pm.getSlot0(k.toId());
            assertEq(sqrtP, _refSqrt(), "initialized by configureStablePool");
        }
    }
}
