// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {IPermit2, LiqHelper} from "./RCBytecodeHarness.sol";

/// @notice Public Robinhood Chain (chain id 4663) addresses read by the fork tests.
library RCAddresses {
    uint256 internal constant CHAIN_ID = 4663;

    address internal constant POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address internal constant UNIVERSAL_ROUTER = 0x204FAca1764B154221e35c0d20aBb3c525710498;
    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    /// @dev USDe (18 decimals) sorts below USDG (6 decimals).
    address internal constant USDE = 0x5d3a1Ff2b6BAb83b63cd9AD0787074081a52ef34;
    address internal constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    uint8 internal constant USDE_DECIMALS = 18;
    uint8 internal constant USDG_DECIMALS = 6;
    /// @dev 1 USDe == 1 USDG across the 18/6 decimals gap.
    int24 internal constant USDE_USDG_PARITY_TICK = -276325;
}

/// @notice Read-only Robinhood Chain fork fixture. The RPC URL is read from `RC_RPC_URL` only; when it is unset
///         `forkOrSkip` skips the calling suite.
abstract contract RCForkHelpers is Test {
    /// @dev Pinned block (needs an archive node); `RC_FORK_BLOCK` overrides it.
    uint256 internal constant RC_FORK_BLOCK = 78_440_229;

    string internal constant RC_RPC_ENV = "RC_RPC_URL";
    string internal constant RC_FORK_BLOCK_ENV = "RC_FORK_BLOCK";

    IPoolManager internal pmRC = IPoolManager(RCAddresses.POOL_MANAGER);
    LiqHelper internal liqRC;
    uint256 internal forkId;
    uint256 internal forkBlock;

    /// @notice Create and select the fork, or skip when `RC_RPC_URL` is unset. Call first in `setUp`.
    function forkOrSkip() internal {
        string memory url = vm.envOr(RC_RPC_ENV, string(""));
        if (bytes(url).length == 0) {
            vm.skip(true, "RC_RPC_URL not set: fork tests skipped");
            return;
        }
        forkBlock = vm.envOr(RC_FORK_BLOCK_ENV, RC_FORK_BLOCK);
        forkId = vm.createSelectFork(url, forkBlock);
        require(block.chainid == RCAddresses.CHAIN_ID, "ForkHelpers: not Robinhood Chain (4663)");
        liqRC = new LiqHelper(pmRC);
    }

    /// @notice Give `to` `amount` of a real token and set the Permit2 -> Universal Router allowances.
    function fundRC(address token, address to, uint256 amount) internal {
        deal(token, to, amount);
        vm.startPrank(to);
        IERC20Metadata(token).approve(RCAddresses.PERMIT2, type(uint256).max);
        IPermit2(RCAddresses.PERMIT2).approve(token, RCAddresses.UNIVERSAL_ROUTER, type(uint160).max, type(uint48).max);
        vm.stopPrank();
    }

    /// @notice USDe/USDG key; dynamic fee when `hook != 0`.
    function usdeUsdgKey(address hook, uint24 staticFee, int24 tickSpacing) internal pure returns (PoolKey memory) {
        return PoolKey(
            Currency.wrap(RCAddresses.USDE),
            Currency.wrap(RCAddresses.USDG),
            hook == address(0) ? staticFee : LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing,
            IHooks(hook)
        );
    }

    function parityPriceUsdeUsdg() internal pure returns (uint160) {
        return TickMath.getSqrtPriceAtTick(RCAddresses.USDE_USDG_PARITY_TICK);
    }
}
