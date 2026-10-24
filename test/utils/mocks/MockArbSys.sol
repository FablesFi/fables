// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Vm} from "forge-std/Vm.sol";

/// @notice Stand-in for the ArbSys precompile at 0x64 (L2 block number), with failure modes.
contract MockArbSys {
    enum Mode {
        Normal,
        Revert,
        ShortReturn
    }

    uint256 public blockNumber;
    Mode public mode;

    error ArbSysDown();

    function arbBlockNumber() external view returns (uint256) {
        if (mode == Mode.Revert) revert ArbSysDown();
        if (mode == Mode.ShortReturn) {
            assembly ("memory-safe") {
                mstore(0x00, 0x01)
                return(0x1f, 1)
            }
        }
        return blockNumber;
    }

    function setBlockNumber(uint256 n) external {
        blockNumber = n;
    }

    function advance(uint256 n) external {
        blockNumber += n;
    }

    function setMode(Mode m) external {
        mode = m;
    }
}

/// @notice Installs and drives the ArbSys stand-in. Install before deploying a stable hook (the clock is latched at
///         construction).
library ArbSysHelper {
    address internal constant ARB_SYS = address(0x64);

    function install(Vm vm, uint256 startBlock) internal returns (MockArbSys) {
        vm.etch(ARB_SYS, type(MockArbSys).runtimeCode);
        MockArbSys(ARB_SYS).setBlockNumber(startBlock);
        MockArbSys(ARB_SYS).setMode(MockArbSys.Mode.Normal);
        vm.label(ARB_SYS, "ArbSys(mock)");
        return MockArbSys(ARB_SYS);
    }

    function set(uint256 n) internal {
        MockArbSys(ARB_SYS).setBlockNumber(n);
    }

    function advance(uint256 n) internal {
        MockArbSys(ARB_SYS).advance(n);
    }

    function setMode(MockArbSys.Mode m) internal {
        MockArbSys(ARB_SYS).setMode(m);
    }

    function remove(Vm vm) internal {
        vm.etch(ARB_SYS, "");
    }

    function installed() internal view returns (bool) {
        return ARB_SYS.code.length > 0;
    }

    function probe() internal view returns (bool usesArbSys, uint256 number) {
        if (ARB_SYS.code.length == 0) return (false, block.number);
        (bool ok, bytes memory ret) = ARB_SYS.staticcall(abi.encodeWithSignature("arbBlockNumber()"));
        if (!ok || ret.length != 32) return (false, block.number);
        return (true, abi.decode(ret, (uint256)));
    }
}
