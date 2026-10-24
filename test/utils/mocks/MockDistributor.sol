// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

/// @notice Distributor stand-in that only names the protocol token.
contract MockDistributor {
    address public ff;

    constructor(address ff_) {
        ff = ff_;
    }
}
