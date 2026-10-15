// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {HongbaoTestBase} from "./helpers/HongbaoTestBase.sol";
import {MockIMD} from "./helpers/MockIMD.sol";
import {HongbaoBox} from "../src/HongbaoBox.sol";

contract HongbaoFailuresTest is HongbaoTestBase {
    function testInsufficientAllowanceAndBalanceFailWithoutCreatingPacket() public {
        vm.prank(creator);
        imd.approve(address(box), 0);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(box), 0, 1 ether)
        );
        _create(1 ether, 2, true);
        vm.prank(alice);
        imd.approve(address(box), 1 ether);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 0, 1 ether));
        vm.prank(alice);
        box.create(1 ether, 2, false, keyAddress, SALT, 10 minutes, bytes32(0));
        _assertPristine();
    }

    function testIncomingFeesBonusesNoOpsAndFalseReturnsRejectAtomically() public {
        MockIMD.Mode[4] memory modes =
            [MockIMD.Mode.FeeIn, MockIMD.Mode.BonusIn, MockIMD.Mode.NoOpIn, MockIMD.Mode.FalseIn];
        for (uint256 i; i < modes.length; ++i) {
            imd.setMode(modes[i]);
            if (modes[i] == MockIMD.Mode.FalseIn) {
                vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(imd)));
            } else {
                vm.expectRevert(HongbaoBox.InexactTransfer.selector);
            }
            _create(1 ether, 2, true);
            _assertPristine();
        }
        imd.setMode(MockIMD.Mode.Normal);
        assertEq(_create(1 ether, 2, true), 1);
        _assertAccounting();
    }

    function testBurnMustTransferExactlyAndFailuresRollbackDeposit() public {
        MockIMD.Mode[4] memory modes =
            [MockIMD.Mode.FeeOut, MockIMD.Mode.SenderFeeOut, MockIMD.Mode.NoOpOut, MockIMD.Mode.FalseOut];
        for (uint256 i; i < modes.length; ++i) {
            imd.setMode(modes[i]);
            if (modes[i] == MockIMD.Mode.FalseOut) {
                vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(imd)));
            } else {
                vm.expectRevert(HongbaoBox.InexactTransfer.selector);
            }
            _create(1 ether, 2, true);
            _assertPristine();
        }
        imd.setMode(MockIMD.Mode.Normal);
        imd.setBlocked(box.BURN_ADDRESS());
        vm.expectRevert(MockIMD.Blocked.selector);
        _create(1 ether, 2, false);
        _assertPristine();
    }

    function testNoReturnERC20IsSupportedWhenBalancesMoveExactly() public {
        imd.setMode(MockIMD.Mode.NoReturn);
        uint256 id = _create(1 ether, 1, false);
        _grab(id, alice);
        assertEq(imd.balanceOf(alice), box.packet(id).amount);
        _assertAccounting();
    }

    function testEqualFailedPayoutDoesNotConsumeSignatureOrSlot() public {
        uint256 id = _create(1 ether, 2, false);
        bytes memory signature = _sign(box, id, alice);
        imd.setBlocked(alice);
        vm.expectRevert(MockIMD.Blocked.selector);
        box.grab(id, alice, signature);
        assertFalse(box.hasGrabbed(id, alice));
        assertEq(box.packet(id).grabbed, 0);
        (address[] memory recipients, uint256[] memory shares) = box.grabbers(id);
        assertEq(recipients.length, 0);
        assertEq(shares.length, 0);
        _assertAccounting();
        imd.setBlocked(address(0));
        box.grab(id, alice, signature);
        assertTrue(box.hasGrabbed(id, alice));
        _assertAccounting();
    }

    function testOutboundFeesCannotStealOtherPacketsEscrow() public {
        uint256 id = _create(1 ether, 2, false);
        _create(5 ether, 2, true);
        uint256 beforeBalance = imd.balanceOf(address(box));
        bytes memory signature = _sign(box, id, alice);
        imd.setMode(MockIMD.Mode.SenderFeeOut);
        vm.expectRevert(HongbaoBox.InexactTransfer.selector);
        box.grab(id, alice, signature);
        imd.setMode(MockIMD.Mode.FeeOut);
        vm.expectRevert(HongbaoBox.InexactTransfer.selector);
        box.grab(id, alice, signature);
        assertEq(imd.balanceOf(address(box)), beforeBalance);
        assertEq(imd.balanceOf(alice), 0);
        _assertAccounting();
    }

    function testRevealSecondPayoutFailureRollsBackWholeBatchAndCanRetry() public {
        uint256 id = _create(1 ether, 3, true);
        _grab(id, alice);
        _grab(id, bob);
        _grab(id, carol);
        imd.setBlocked(bob);
        vm.expectRevert(MockIMD.Blocked.selector);
        _reveal(id);
        _assertUnpaidLucky(id, 3);
        imd.setBlocked(address(0));
        _reveal(id);
        assertEq(imd.balanceOf(alice) + imd.balanceOf(bob) + imd.balanceOf(carol), box.packet(id).amount);
        _assertAccounting();
    }

    function testSettleRefundFailureRollsBackAllRecipientsAndCanRetry() public {
        uint256 id = _create(1 ether, 3, true);
        _grab(id, alice);
        _grab(id, bob);
        vm.warp(box.settlementTime(id));
        imd.setBlocked(creator);
        vm.expectRevert(MockIMD.Blocked.selector);
        box.settle(id);
        _assertUnpaidLucky(id, 2);
        imd.setBlocked(address(0));
        box.settle(id);
        assertGt(imd.balanceOf(alice), 0);
        _assertAccounting();
    }

    function testEqualRefundFailureLeavesRecoverableLiability() public {
        uint256 id = _create(1 ether, 3, false);
        _grab(id, alice);
        vm.warp(box.packet(id).expiry);
        uint256 beforeRemaining = box.remaining(id);
        imd.setBlocked(creator);
        vm.expectRevert(MockIMD.Blocked.selector);
        box.refund(id);
        assertEq(box.remaining(id), beforeRemaining);
        assertEq(uint256(box.packet(id).state), uint256(HongbaoBox.State.Open));
        _assertAccounting();
        imd.setBlocked(address(0));
        box.refund(id);
        _assertAccounting();
    }

    function testAllMutatorsRejectReentryDuringDepositAndBurn() public {
        bytes[] memory payloads = new bytes[](6);
        payloads[0] = abi.encodeCall(box.create, (1 ether, 1, false, keyAddress, SALT, 10 minutes, bytes32(0)));
        payloads[1] = abi.encodeCall(box.grab, (1, alice, bytes("")));
        payloads[2] = abi.encodeCall(box.reveal, (1, SECRET));
        payloads[3] = abi.encodeCall(box.settle, (1));
        payloads[4] = abi.encodeCall(box.refund, (1));
        payloads[5] = abi.encodeCall(box.recoverSurplus, ());
        for (uint256 i; i < payloads.length; ++i) {
            uint256 beforeAttempts = imd.callbackAttempts();
            imd.setCallback(address(box), payloads[i], true, true);
            _create(1 ether, 2, true);
            assertEq(imd.callbackAttempts(), beforeAttempts + 2);
            _assertGuardedCallback();
            _assertAccounting();
        }
    }

    function testReentryDuringEachPayoutPathCannotRecoverEscrowAsSurplus() public {
        uint256 equal = _create(1 ether, 2, false);
        uint256 lucky = _create(2 ether, 2, true);
        uint256 fallbackId = _create(3 ether, 2, true);
        _grab(lucky, alice);
        _grab(lucky, bob);
        _grab(fallbackId, alice);
        imd.setCallback(address(box), abi.encodeCall(box.recoverSurplus, ()), false, true);
        _grab(equal, carol);
        _assertGuardedCallback();
        _reveal(lucky);
        _assertGuardedCallback();
        vm.warp(box.settlementTime(fallbackId));
        box.settle(fallbackId);
        _assertGuardedCallback();
        box.refund(equal);
        _assertGuardedCallback();
        imd.mint(address(box), 1 ether);
        box.recoverSurplus();
        _assertGuardedCallback();
        _assertAccounting();
    }

    function _assertPristine() internal view {
        assertEq(box.nextPacketId(), 1);
        assertEq(imd.balanceOf(creator), 1_000_000 ether);
        assertEq(imd.balanceOf(box.BURN_ADDRESS()), 0);
        _assertAccounting();
    }

    function _assertUnpaidLucky(uint256 id, uint256 count) internal view {
        assertEq(uint256(box.packet(id).state), uint256(HongbaoBox.State.Open));
        assertEq(box.bestLuck(id), address(0));
        assertEq(imd.balanceOf(alice), 0);
        assertEq(imd.balanceOf(bob), 0);
        assertEq(imd.balanceOf(carol), 0);
        (, uint256[] memory shares) = box.grabbers(id);
        assertEq(shares.length, count);
        for (uint256 i; i < count; ++i) {
            assertEq(shares[i], 0);
        }
        _assertAccounting();
    }

    function _assertGuardedCallback() internal view {
        assertFalse(imd.callbackSucceeded());
        assertEq(imd.callbackResult(), abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector));
    }
}
