// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title Slimez
/// @notice Fixed supply ERC-20 with 18 decimals and no administrative powers.
contract Slimez is ERC20 {
    /// @notice Mints all 1,000,000,000 SLIMEZ to the constructor caller.
    /// @dev When created by a factory, that factory receives the entire supply.
    constructor() ERC20("Slimez", "SLIMEZ") {
        _mint(msg.sender, 1_000_000_000 * 10 ** 18);
    }
}
