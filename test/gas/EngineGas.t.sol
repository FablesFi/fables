// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "v4-core/test/utils/Deployers.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";

import {EngineHarness} from "../utils/EngineHarness.sol";

/// @notice Gas of the poke and admin paths, with loose ceilings.
contract EngineGasTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;

    EngineHarness hook;
    PoolId poolId;

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();
        AccessManager authority = new AccessManager(address(this));
        address hookAddr = address(uint160(0x9999 << 144) | uint160(Hooks.BEFORE_INITIALIZE_FLAG));
        deployCodeTo("EngineHarness.sol:EngineHarness", abi.encode(manager, address(authority)), hookAddr);
        hook = EngineHarness(hookAddr);
        hook.setCategory(1, 0, 50_000, 2500, "STOCK");
        vm.warp(1_785_859_200);
        key = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(hookAddr));
        hook.configurePool(key, 1, 700, 900, 300, 8000);
        poolId = key.toId();
        hook.initializePool(key, SQRT_PRICE_1_1);
    }

    function test_gas_pokeAndAdminPaths() public {
        uint256 g0 = gasleft();
        hook.pokeFee(poolId, 3000, 3000, 1 hours);
        uint256 pokeCold = g0 - gasleft();
        emit log_named_uint("pokeFee (first raise, meta slot cold)", pokeCold);

        vm.warp(block.timestamp + 60);
        g0 = gasleft();
        hook.pokeFee(poolId, 3000, 3000, 1 hours);
        uint256 pokeRenew = g0 - gasleft();
        emit log_named_uint("pokeFee (renewal, no raise)", pokeRenew);

        g0 = gasleft();
        hook.pokeFee(poolId, 5000, 5000, 1 hours);
        uint256 pokeRaise = g0 - gasleft();
        emit log_named_uint("pokeFee (raise, meta slot warm)", pokeRaise);

        g0 = gasleft();
        hook.clearPoke(poolId);
        uint256 clear_ = g0 - gasleft();
        emit log_named_uint("clearPoke", clear_);

        g0 = gasleft();
        hook.configurePool(key, 1, 800, 800, 300, 9000);
        uint256 reconfigure = g0 - gasleft();
        emit log_named_uint("configurePool (reconfigure)", reconfigure);

        PoolKey memory k2 = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 120, IHooks(address(hook)));
        g0 = gasleft();
        hook.configurePool(k2, 1, 800, 800, 300, 9000);
        uint256 configureNew = g0 - gasleft();
        emit log_named_uint("configurePool (new pool: word + maxFee + meta from zero)", configureNew);

        g0 = gasleft();
        hook.configureCF(poolId, 0, 256, 1000, 80, 60, 15);
        uint256 cf = g0 - gasleft();
        emit log_named_uint("configureCF (first write)", cf);

        g0 = gasleft();
        hook.setCFActive(poolId, true, TickMath.MIN_TICK, TickMath.MAX_TICK, type(uint256).max);
        uint256 cfOn = g0 - gasleft();
        emit log_named_uint("setCFActive(true)", cfOn);

        PoolId[] memory ids = new PoolId[](1);
        ids[0] = poolId;
        g0 = gasleft();
        hook.setDiscount(ids, address(0xDE5C), 2500, 0, 3, uint40(block.timestamp + 1 days));
        uint256 disc = g0 - gasleft();
        emit log_named_uint("setDiscount (one pool, new entry)", disc);

        assertLt(pokeRenew, 40_000, "poke renewal");
        assertLt(pokeRaise, 45_000, "poke raise");
        assertLt(clear_, 40_000, "clear");
        assertLt(reconfigure, 50_000, "reconfigure");
        assertLt(configureNew, 120_000, "configure new");
        assertLt(cf, 90_000, "configureCF");
        assertLt(cfOn, 40_000, "setCFActive");
        assertLt(disc, 80_000, "setDiscount");
    }
}
