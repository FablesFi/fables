// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

/// @notice Five sample fee categories (pips): floorMin, capMax and raise step per minute.
library CategoryTable {
    uint8 internal constant COUNT = 5;
    uint8 internal constant STABLE = 1;
    uint8 internal constant MAJOR = 2;
    uint8 internal constant STOCK = 3;
    uint8 internal constant MEME = 4;
    uint8 internal constant LAUNCH = 5;
    uint24 internal constant ABSOLUTE_MAX_FEE = 100_000;

    struct Cat {
        uint24 floorMin;
        uint24 capMax;
        uint24 raiseStep;
    }

    function get(uint8 id) internal pure returns (Cat memory c) {
        if (id == STABLE) return Cat(0, 10_000, 500);
        if (id == MAJOR) return Cat(0, 30_000, 2_500);
        if (id == STOCK) return Cat(0, 50_000, 2_500);
        if (id == MEME) return Cat(2_500, 100_000, 10_000);
        if (id == LAUNCH) return Cat(0, 100_000, 100_000);
        revert("CategoryTable: unknown id");
    }

    function label(uint8 id) internal pure returns (string memory) {
        if (id == STABLE) return "STABLE";
        if (id == MAJOR) return "MAJOR";
        if (id == STOCK) return "STOCK";
        if (id == MEME) return "MEME";
        return "LAUNCH";
    }
}
