// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice The launch's plain, fixed-supply token. Hongbao packets use IMD, not this token.
contract LaunchToken is ERC20 {
    constructor() ERC20("HONGBAO", "HONGBAO") {
        _mint(msg.sender, 1_000_000_000 * 10 ** 18);
    }
}
