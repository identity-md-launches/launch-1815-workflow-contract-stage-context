// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {LaunchToken} from "../src/LaunchToken.sol";

contract LaunchTokenTest is Test {
    LaunchToken private token;
    uint256 private constant SUPPLY = 1e27;

    function setUp() public {
        token = new LaunchToken();
    }

    function testSupplyMetadataAndWholeMintToFactoryCaller() public {
        assertEq(token.name(), "HONGBAO");
        assertEq(token.symbol(), "HONGBAO");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        address factory = makeAddr("factory");
        vm.prank(factory);
        LaunchToken other = new LaunchToken();
        assertEq(other.balanceOf(factory), SUPPLY);
        assertEq(other.balanceOf(address(this)), 0);
    }

    function testFuzzPlainTransfer(uint256 amount) public {
        amount = bound(amount, 0, SUPPLY);
        address recipient = makeAddr("recipient");
        assertTrue(token.transfer(recipient, amount));
        assertEq(token.balanceOf(recipient), amount);
        assertEq(token.balanceOf(address(this)), SUPPLY - amount);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testAllowanceAndTransferFrom() public {
        address spender = makeAddr("spender");
        address recipient = makeAddr("recipient");
        token.approve(spender, 3 ether);
        vm.prank(spender);
        token.transferFrom(address(this), recipient, 2 ether);
        assertEq(token.balanceOf(recipient), 2 ether);
        assertEq(token.allowance(address(this), spender), 1 ether);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 1 ether, 2 ether)
        );
        vm.prank(spender);
        token.transferFrom(address(this), recipient, 2 ether);
    }

    function testInvalidTransfersFail() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 1);
        address empty = makeAddr("empty");
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, empty, 0, 1));
        vm.prank(empty);
        token.transfer(address(this), 1);
    }

    function testNoMintOwnerPauseOrUpgradeEntryPoints() public {
        bytes4[8] memory selectors = [
            bytes4(keccak256("mint(address,uint256)")),
            bytes4(keccak256("burn(uint256)")),
            bytes4(keccak256("owner()")),
            bytes4(keccak256("pause()")),
            bytes4(keccak256("transferOwnership(address)")),
            bytes4(keccak256("upgradeTo(address)")),
            bytes4(keccak256("initialize(address)")),
            bytes4(keccak256("setFee(uint256)"))
        ];
        for (uint256 i; i < selectors.length; ++i) {
            (bool ok,) = address(token).call(abi.encodeWithSelector(selectors[i], address(this), 123));
            assertFalse(ok);
        }
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(address(this)), SUPPLY);
    }
}
