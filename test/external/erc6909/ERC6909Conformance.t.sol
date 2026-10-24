// SPDX-License-Identifier: MIT
// Adapted from Solady v0.1.26 test/ERC6909.t.sol (MIT, Copyright (c) 2022-2026 Solady).
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {stdError} from "forge-std/StdError.sol";
import {Deployers} from "v4-core/test/utils/Deployers.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IERC20Minimal} from "v4-core/src/interfaces/external/IERC20Minimal.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import {FablesFeeEngine} from "../../../src/base/FablesFeeEngine.sol";
import {FablesLedgerV2} from "../../../src/base/FablesLedgerV2.sol";
import {MockBallotGate} from "../../utils/mocks/MockBallotGate.sol";
import {MockWETH9} from "../../utils/mocks/MockWETH9.sol";

/// @notice Deposits native ETH and, in the refund callback, tries to move its receipts and to approve.
contract RefundProbe {
    FablesLedgerV2 internal immutable hook;
    uint256 internal id;
    bytes public transferRevert;
    bool public approved;

    constructor(FablesLedgerV2 hook_) {
        hook = hook_;
    }

    function depositNative(PoolKey calldata key, uint256 id_, uint128 liquidity) external payable {
        id = id_;
        hook.deposit{value: msg.value}(
            key, -600, 600, liquidity, uint128(msg.value), type(uint128).max, block.timestamp
        );
    }

    receive() external payable {
        if (msg.sender != address(hook)) return;
        try hook.transfer(address(0xBEEF), id, 1) {}
        catch (bytes memory reason) {
            transferRevert = reason;
        }
        approved = hook.approve(address(0xBEEF), id, 1);
    }
}

/// @notice ERC-6909 conformance of the LP receipts of a real FablesHook: Solady's ERC6909 suite and the EIP-6909 MUST
///         rules, with receipts minted by `deposit` and burned by `withdraw`. The documented deviations are pinned as
///         expected reverts.
contract ERC6909ConformanceTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    event Transfer(
        address caller, address indexed sender, address indexed receiver, uint256 indexed id, uint256 amount
    );
    event OperatorSet(address indexed owner, address indexed spender, bool approved);
    event Approval(address indexed owner, address indexed spender, uint256 indexed id, uint256 amount);

    int24 internal constant LOWER = -600;
    int24 internal constant UPPER = 600;
    uint256 internal constant MAX_RECEIPTS = 1e24;

    AccessManager internal authority;
    FablesLedgerV2 internal token;
    uint256 internal id;

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();
        authority = new AccessManager(address(this));
        address at = address(uint160(0x6909 << 144) | 0x2080);
        deployCodeTo("FablesHook.sol:FablesHook", abi.encode(manager, address(authority)), at);
        token = FablesLedgerV2(payable(at));
        key = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(at));
        FablesFeeEngine(at).setCategory(1, 0, 100_000, 100_000, "ANY");
        FablesFeeEngine(at).configurePool(key, 1, 3000, 3000, 500, 50_000);
        FablesFeeEngine(at).initializePool(key, SQRT_PRICE_1_1);
        token.setBallotGate(address(new MockBallotGate()));
        id = token.rangeId(key.toId(), LOWER, UPPER);
    }

    // --------------- Solady ERC6909Test, deterministic --------------- //

    function testMint() public {
        _fund(address(0xBEEF));
        vm.expectEmit(true, true, true, true, address(token));
        emit Transfer(address(0xBEEF), address(0), address(0xBEEF), id, 1e18);
        _deposit(address(0xBEEF), 1e18);
        assertEq(token.balanceOf(address(0xBEEF), id), 1e18);
    }

    function testBurn() public {
        _mint(address(0xBEEF), 1e18);
        vm.expectEmit(true, true, true, true, address(token));
        emit Transfer(address(0xBEEF), address(0xBEEF), address(0), id, 0.9e18);
        _burn(address(0xBEEF), 0.9e18);
        assertEq(token.balanceOf(address(0xBEEF), id), 0.1e18);
    }

    function testApprove() public {
        vm.expectEmit(true, true, true, true, address(token));
        emit Approval(address(this), address(0xBEEF), id, 1e18);
        assertTrue(token.approve(address(0xBEEF), id, 1e18));
        assertEq(token.allowance(address(this), address(0xBEEF), id), 1e18);
    }

    function testTransfer() public {
        _mint(address(this), 1e18);
        vm.expectEmit(true, true, true, true, address(token));
        emit Transfer(address(this), address(this), address(0xBEEF), id, 1e18);
        assertTrue(token.transfer(address(0xBEEF), id, 1e18));
        assertEq(token.balanceOf(address(this), id), 0);
        assertEq(token.balanceOf(address(0xBEEF), id), 1e18);
    }

    function testTransferFrom() public {
        address from = address(0xABCD);
        _mint(from, 1e18);
        _approve(from, address(this), 1e18);
        vm.expectEmit(true, true, true, true, address(token));
        emit Transfer(address(this), from, address(0xBEEF), id, 1e18);
        assertTrue(token.transferFrom(from, address(0xBEEF), id, 1e18));
        assertEq(token.allowance(from, address(this), id), 0);
        assertEq(token.balanceOf(from, id), 0);
        assertEq(token.balanceOf(address(0xBEEF), id), 1e18);
    }

    function testInfiniteApproveTransferFrom() public {
        address from = address(0xABCD);
        _mint(from, 1e18);
        _approve(from, address(this), type(uint256).max);
        assertTrue(token.transferFrom(from, address(0xBEEF), id, 1e18));
        assertEq(token.allowance(from, address(this), id), type(uint256).max);
        assertEq(token.balanceOf(address(0xBEEF), id), 1e18);
    }

    function testOperatorTransferFrom() public {
        address from = address(0xABCD);
        _mint(from, 1e18);
        _approve(from, address(this), 5);
        _setOperator(from, address(this), true);
        vm.expectEmit(true, true, true, true, address(token));
        emit Transfer(address(this), from, address(0xBEEF), id, 1e18);
        assertTrue(token.transferFrom(from, address(0xBEEF), id, 1e18));
        assertEq(token.allowance(from, address(this), id), 5, "an operator spent the allowance");
        assertEq(token.balanceOf(address(0xBEEF), id), 1e18);
    }

    /// @notice EIP-6909: the sender itself needs no allowance, and its allowance is not spent.
    function testTransferFromBySenderNeedsNoAllowance() public {
        _mint(address(this), 1e18);
        token.approve(address(this), id, 7);
        assertTrue(token.transferFrom(address(this), address(0xBEEF), id, 1e18));
        assertEq(token.allowance(address(this), address(this), id), 7);
    }

    function testSetOperator() public {
        assertFalse(token.isOperator(address(this), address(0xBEEF)));
        vm.expectEmit(true, true, true, true, address(token));
        emit OperatorSet(address(this), address(0xBEEF), true);
        assertTrue(token.setOperator(address(0xBEEF), true));
        assertTrue(token.isOperator(address(this), address(0xBEEF)));
    }

    function testTransferInsufficientBalanceReverts() public {
        _mint(address(this), 0.9e18);
        vm.expectRevert(FablesLedgerV2.InsufficientUnstakedShares.selector);
        token.transfer(address(0xBEEF), id, 1e18);
    }

    function testTransferFromInsufficientPermission() public {
        address from = address(0xABCD);
        _mint(from, 1e18);
        _approve(from, address(this), 0.9e18);
        vm.expectRevert(stdError.arithmeticError);
        token.transferFrom(from, address(0xBEEF), id, 1e18);
    }

    function testTransferFromInsufficientBalanceReverts() public {
        address from = address(0xABCD);
        _mint(from, 0.9e18);
        _approve(from, address(this), 1e18);
        vm.expectRevert(FablesLedgerV2.InsufficientUnstakedShares.selector);
        token.transferFrom(from, address(0xBEEF), id, 1e18);
    }

    /// @notice EIP-6909 requires ERC-165; interface id 0x0f632fb3, answered within ERC-165's 30k gas.
    function testSupportsInterface() public view {
        assertTrue(token.supportsInterface(0x01ffc9a7));
        assertTrue(token.supportsInterface(0x0f632fb3));
        assertFalse(token.supportsInterface(0xffffffff));
        (bool ok, bytes memory ret) =
            address(token).staticcall{gas: 30_000}(abi.encodeWithSelector(0x01ffc9a7, bytes4(0x0f632fb3)));
        assertTrue(ok && abi.decode(ret, (bool)));
    }

    // --------------- Solady ERC6909Test, fuzzed --------------- //

    function testMint(address to, uint256 amount) public {
        _assumeHolder(to);
        amount = bound(amount, 1, MAX_RECEIPTS);
        _fund(to);
        vm.expectEmit(true, true, true, true, address(token));
        emit Transfer(to, address(0), to, id, amount);
        _deposit(to, amount);
        assertEq(token.balanceOf(to, id), amount);
    }

    function testBurn(address from, uint256 mintAmount, uint256 burnAmount) public {
        _assumeHolder(from);
        mintAmount = bound(mintAmount, 1, MAX_RECEIPTS);
        burnAmount = bound(burnAmount, 1, mintAmount);
        _mint(from, mintAmount);
        vm.expectEmit(true, true, true, true, address(token));
        emit Transfer(from, from, address(0), id, burnAmount);
        _burn(from, burnAmount);
        assertEq(token.balanceOf(from, id), mintAmount - burnAmount);
    }

    function testApprove(address to, uint256 anyId, uint256 amount) public {
        vm.expectEmit(true, true, true, true, address(token));
        emit Approval(address(this), to, anyId, amount);
        assertTrue(token.approve(to, anyId, amount));
        assertEq(token.allowance(address(this), to, anyId), amount);
    }

    function testTransfer(address to, uint256 amount) public {
        amount = bound(amount, 1, MAX_RECEIPTS);
        _mint(address(this), amount);
        vm.expectEmit(true, true, true, true, address(token));
        emit Transfer(address(this), address(this), to, id, amount);
        assertTrue(token.transfer(to, id, amount));
        if (to == address(this)) {
            assertEq(token.balanceOf(address(this), id), amount);
        } else {
            assertEq(token.balanceOf(address(this), id), 0);
            assertEq(token.balanceOf(to, id), amount);
        }
    }

    function testTransferFrom(address spender, address from, address to, uint256 approval, uint256 amount) public {
        _assumeHolder(from);
        _assumeCaller(spender);
        amount = bound(amount, 1, MAX_RECEIPTS);
        approval = bound(approval, amount, type(uint256).max);
        _mint(from, amount);
        _approve(from, spender, approval);

        vm.expectEmit(true, true, true, true, address(token));
        emit Transfer(spender, from, to, id, amount);
        vm.prank(spender);
        assertTrue(token.transferFrom(from, to, id, amount));

        if (approval == type(uint256).max || spender == from) {
            assertEq(token.allowance(from, spender, id), approval);
        } else {
            assertEq(token.allowance(from, spender, id), approval - amount);
        }
        if (from == to) {
            assertEq(token.balanceOf(from, id), amount);
        } else {
            assertEq(token.balanceOf(from, id), 0);
            assertEq(token.balanceOf(to, id), amount);
        }
    }

    function testSetOperator(address owner, address spender, bool approved) public {
        _assumeCaller(owner);
        _setOperator(owner, spender, approved);
    }

    function testTransferInsufficientBalanceReverts(address to, uint256 mintAmount, uint256 sendAmount) public {
        mintAmount = bound(mintAmount, 1, MAX_RECEIPTS);
        sendAmount = bound(sendAmount, mintAmount + 1, type(uint256).max);
        _mint(address(this), mintAmount);
        vm.expectRevert(FablesLedgerV2.InsufficientUnstakedShares.selector);
        token.transfer(to, id, sendAmount);
    }

    function testTransferFromInsufficientAllowanceReverts(address to, uint256 approval, uint256 amount) public {
        address from = address(0xABCD);
        amount = bound(amount, 1, MAX_RECEIPTS);
        approval = bound(approval, 0, amount - 1);
        _mint(from, amount);
        _approve(from, address(this), approval);
        vm.expectRevert(stdError.arithmeticError);
        token.transferFrom(from, to, id, amount);
    }

    function testTransferFromInsufficientBalanceReverts(address to, uint256 mintAmount, uint256 sendAmount) public {
        address from = address(0xABCD);
        mintAmount = bound(mintAmount, 1, MAX_RECEIPTS);
        sendAmount = bound(sendAmount, mintAmount + 1, type(uint256).max);
        _mint(from, mintAmount);
        _approve(from, address(this), sendAmount);
        vm.expectRevert(FablesLedgerV2.InsufficientUnstakedShares.selector);
        token.transferFrom(from, to, id, sendAmount);
    }

    function testTransferFromCallerIsNotOperator(address to, uint256 amount) public {
        address from = address(0xABCD);
        amount = bound(amount, 1, MAX_RECEIPTS);
        _mint(from, amount);
        vm.expectRevert(stdError.arithmeticError);
        token.transferFrom(from, to, id, amount);
    }

    /// @notice Solady `testDirectFunctions`: for any balance, allowance, operator status and amount, `transfer` and
    ///         `transferFrom` succeed exactly when the EIP-6909 MUST rules allow, and move allowance and balances as
    ///         the spec says.
    /// forge-config: default.fuzz.runs = 512
    function testTransfersFollowTheSpec(
        address by,
        address from,
        address to,
        uint256 balance,
        uint256 allowance,
        uint256 amount,
        bool isOperator,
        bool byOwner
    ) public {
        _assumeHolder(from);
        _assumeCaller(by);
        if (byOwner) by = from;
        balance = bound(balance, 1, MAX_RECEIPTS);
        amount = bound(amount, 1, 2 * MAX_RECEIPTS);
        allowance = allowance % 4 == 0 ? type(uint256).max : bound(allowance, 0, 2 * MAX_RECEIPTS);
        _mint(from, balance);
        _setOperator(from, by, isOperator);
        _approve(from, by, allowance);

        bool authorized = by == from || isOperator || allowance >= amount;
        bool success = authorized && balance >= amount;
        if (success) {
            vm.expectEmit(true, true, true, true, address(token));
            emit Transfer(by, from, to, id, amount);
        } else {
            vm.expectRevert();
        }
        vm.prank(by);
        if (byOwner && allowance % 2 == 0) token.transfer(to, id, amount);
        else token.transferFrom(from, to, id, amount);

        bool spends = success && by != from && !isOperator && allowance != type(uint256).max;
        assertEq(token.allowance(from, by, id), spends ? allowance - amount : allowance);
        if (!success || from == to) {
            assertEq(token.balanceOf(from, id), balance);
        } else {
            assertEq(token.balanceOf(from, id), balance - amount);
            assertEq(token.balanceOf(to, id), amount);
        }
    }

    // --------------- Documented deviations: expected reverts --------------- //

    /// @notice A transfer of 0 reverts (a zero transfer would be a free fee sync), for owners and operators alike.
    function testTransferOfZeroReverts() public {
        _mint(address(this), 1e18);
        token.setOperator(address(0xCAFE), true);
        vm.expectRevert(FablesLedgerV2.ZeroShares.selector);
        token.transfer(address(0xBEEF), id, 0);
        vm.expectRevert(FablesLedgerV2.ZeroShares.selector);
        token.transferFrom(address(this), address(0xBEEF), id, 0);
        vm.prank(address(0xCAFE));
        vm.expectRevert(FablesLedgerV2.ZeroShares.selector);
        token.transferFrom(address(this), address(0xBEEF), id, 0);
    }

    /// @notice Staked receipts must be unstaked before they move: only `balanceOf - staked` is transferable.
    function testStakedReceiptsAreNotTransferable() public {
        _mint(address(this), 1e18);
        token.stake(key, LOWER, UPPER, 0.4e18, 0);
        token.setOperator(address(0xCAFE), true);

        vm.expectRevert(FablesLedgerV2.InsufficientUnstakedShares.selector);
        token.transfer(address(0xBEEF), id, 0.6e18 + 1);
        vm.prank(address(0xCAFE));
        vm.expectRevert(FablesLedgerV2.InsufficientUnstakedShares.selector);
        token.transferFrom(address(this), address(0xBEEF), id, 0.6e18 + 1);

        assertTrue(token.transfer(address(0xBEEF), id, 0.6e18));
        vm.expectRevert(FablesLedgerV2.InsufficientUnstakedShares.selector);
        token.transfer(address(0xBEEF), id, 1);
        assertEq(token.balanceOf(address(this), id), 0.4e18, "staked receipts still count in balanceOf");

        token.unstake(key, LOWER, UPPER, 0.4e18);
        assertTrue(token.transfer(address(0xBEEF), id, 0.4e18));
        assertEq(token.balanceOf(address(0xBEEF), id), 1e18);
    }

    /// @notice Transfers stop while the ledger or the receipt's pool is paused; approvals and operators do not.
    function testTransfersRevertWhilePaused() public {
        _mint(address(this), 1e18);
        token.setOperator(address(0xCAFE), true);

        token.pause(1 days);
        vm.expectRevert(FablesLedgerV2.LedgerPaused.selector);
        token.transfer(address(0xBEEF), id, 1);
        vm.prank(address(0xCAFE));
        vm.expectRevert(FablesLedgerV2.LedgerPaused.selector);
        token.transferFrom(address(this), address(0xBEEF), id, 1);
        assertTrue(token.approve(address(0xBEEF), id, 1));
        assertTrue(token.setOperator(address(0xBEEF), true));

        token.setPaused(0);
        token.pausePool(key, 1 days);
        vm.expectRevert(FablesLedgerV2.LedgerPaused.selector);
        token.transfer(address(0xBEEF), id, 1);

        token.setPoolPaused(key, 0);
        assertTrue(token.transfer(address(0xBEEF), id, 1));
    }

    /// @notice Transfers revert while a ledger call is in progress (reentrancy guard), here inside the native-deposit
    ///         refund; approvals still work there.
    function testTransfersRevertDuringALedgerCall() public {
        address at = address(uint160(0x690A << 144) | 0x2080);
        deployCodeTo(
            "FablesHookETH.sol:FablesHookETH", abi.encode(manager, address(authority), address(new MockWETH9())), at
        );
        FablesLedgerV2 ethHook = FablesLedgerV2(payable(at));
        PoolKey memory k =
            PoolKey(CurrencyLibrary.ADDRESS_ZERO, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(at));
        _configureNative(at, k);

        RefundProbe probe = new RefundProbe(ethHook);
        IERC20Minimal(Currency.unwrap(currency1)).transfer(address(probe), 1e24);
        vm.prank(address(probe));
        IERC20Minimal(Currency.unwrap(currency1)).approve(at, type(uint256).max);
        uint256 rid = ethHook.rangeId(k.toId(), LOWER, UPPER);
        vm.deal(address(this), 1 ether);
        probe.depositNative{value: 1 ether}(k, rid, 1e18);

        assertEq(ethHook.balanceOf(address(probe), rid), 1e18);
        assertEq(
            probe.transferRevert(),
            abi.encodeWithSelector(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector)
        );
        assertTrue(probe.approved());
    }

    // --------------- Helpers --------------- //

    function _configureNative(address at, PoolKey memory k) internal {
        FablesFeeEngine(at).setCategory(1, 0, 100_000, 100_000, "ANY");
        FablesFeeEngine(at).configurePool(k, 1, 3000, 3000, 500, 50_000);
        FablesFeeEngine(at).initializePool(k, SQRT_PRICE_1_1);
    }

    /// @dev Mints `amount` receipts to `to` by a real deposit from `to`.
    function _mint(address to, uint256 amount) internal {
        _fund(to);
        _deposit(to, amount);
    }

    function _fund(address to) internal {
        IERC20Minimal t0 = IERC20Minimal(Currency.unwrap(currency0));
        IERC20Minimal t1 = IERC20Minimal(Currency.unwrap(currency1));
        if (to != address(this)) {
            assertTrue(t0.transfer(to, 1e24));
            assertTrue(t1.transfer(to, 1e24));
        }
        vm.startPrank(to);
        t0.approve(address(token), type(uint256).max);
        t1.approve(address(token), type(uint256).max);
        vm.stopPrank();
    }

    function _deposit(address to, uint256 amount) internal {
        vm.prank(to);
        // forge-lint: disable-next-line(unsafe-typecast)
        token.deposit(key, LOWER, UPPER, uint128(amount), type(uint128).max, type(uint128).max, block.timestamp);
    }

    /// @dev Burns by a real withdrawal.
    function _burn(address from, uint256 amount) internal {
        vm.prank(from);
        // forge-lint: disable-next-line(unsafe-typecast)
        token.withdraw(key, LOWER, UPPER, uint128(amount), from, 0, 0, block.timestamp);
    }

    function _approve(address owner, address spender, uint256 amount) internal {
        vm.expectEmit(true, true, true, true, address(token));
        emit Approval(owner, spender, id, amount);
        vm.prank(owner);
        assertTrue(token.approve(spender, id, amount));
        assertEq(token.allowance(owner, spender, id), amount);
    }

    function _setOperator(address owner, address operator, bool approved) internal {
        vm.expectEmit(true, true, true, true, address(token));
        emit OperatorSet(owner, operator, approved);
        vm.prank(owner);
        assertTrue(token.setOperator(operator, approved));
        assertEq(token.isOperator(owner, operator), approved);
    }

    /// @dev A caller the test can prank.
    function _assumeCaller(address a) internal view {
        assumeNotForgeAddress(a);
        assumeNotPrecompile(a);
        vm.assume(a != address(0) && a != address(manager));
    }

    /// @dev An LP that can deposit: a prankable caller other than the hook.
    function _assumeHolder(address a) internal view {
        _assumeCaller(a);
        vm.assume(a != address(token) && a.code.length == 0);
    }
}
