// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev Test-only token. None of its minting or failure controls belong to a deployed artifact.
contract MockIMD is ERC20 {
    enum Mode {
        Normal,
        FeeIn,
        BonusIn,
        FeeOut,
        SenderFeeOut,
        FalseIn,
        FalseOut,
        NoOpIn,
        NoOpOut,
        NoReturn
    }

    Mode public mode;
    address public blockedRecipient;
    address public callbackTarget;
    bytes public callbackData;
    bool public callbackOnTransferFrom;
    bool public callbackOnTransfer;
    bool public callbackSucceeded;
    bytes public callbackResult;
    uint256 public callbackAttempts;

    error Blocked();

    constructor() ERC20("Mock IMD", "IMD") {}

    function mint(address recipient, uint256 amount) external {
        _mint(recipient, amount);
    }

    function setMode(Mode next) external {
        mode = next;
    }

    function setBlocked(address recipient) external {
        blockedRecipient = recipient;
    }

    function setCallback(address target, bytes calldata data, bool onTransferFrom, bool onTransfer) external {
        callbackTarget = target;
        callbackData = data;
        callbackOnTransferFrom = onTransferFrom;
        callbackOnTransfer = onTransfer;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        if (mode == Mode.FalseIn) return false;
        if (mode == Mode.NoOpIn) return true;
        bool result = super.transferFrom(from, to, amount);
        if (mode == Mode.FeeIn) _burn(to, amount / 100);
        if (mode == Mode.BonusIn) _mint(to, amount / 100);
        if (callbackOnTransferFrom) _callback();
        if (mode == Mode.NoReturn) {
            assembly ("memory-safe") {
                return(0, 0)
            }
        }
        return result;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (to == blockedRecipient) revert Blocked();
        if (mode == Mode.FalseOut) return false;
        if (mode == Mode.NoOpOut) return true;
        bool result = super.transfer(to, amount);
        if (mode == Mode.FeeOut) _burn(to, amount / 100);
        if (mode == Mode.SenderFeeOut) _burn(msg.sender, amount / 100);
        if (callbackOnTransfer) _callback();
        if (mode == Mode.NoReturn) {
            assembly ("memory-safe") {
                return(0, 0)
            }
        }
        return result;
    }

    function _callback() private {
        ++callbackAttempts;
        (callbackSucceeded, callbackResult) = callbackTarget.call(callbackData);
    }
}
