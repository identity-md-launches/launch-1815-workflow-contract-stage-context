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

    /// @dev The reviewer's scenario: one blocked grabber must not strand the others or the creator.
    function testBlockedGrabberCannotStrandLuckyPacketSettlePaysOthersAndCreditsThem() public {
        uint256 id = _create(100 ether, 3, true);
        uint256 net = box.packet(id).amount;
        _grab(id, alice);
        _grab(id, bob);
        imd.setBlocked(bob);
        vm.warp(box.settlementTime(id));
        // The atomic reveal cannot complete while IMD refuses bob.
        vm.expectRevert(MockIMD.Blocked.selector);
        _reveal(id);
        _assertUnpaidLucky(id, 2);
        // The permissionless fallback finishes anyway.
        uint256 payout = net * 2 / 3;
        uint256 creatorBefore = imd.balanceOf(creator);
        vm.expectEmit(address(box));
        emit HongbaoBox.Settled(id, payout, net - payout);
        vm.expectEmit(address(box));
        emit HongbaoBox.PayoutDeferred(id, bob, payout - payout / 2);
        vm.prank(relayer);
        box.settle(id);
        assertEq(uint256(box.packet(id).state), uint256(HongbaoBox.State.Settled));
        assertEq(imd.balanceOf(alice), payout / 2, "alice paid");
        assertEq(imd.balanceOf(bob), 0, "bob not paid by IMD");
        assertEq(box.claimable(bob), payout - payout / 2, "bob credited");
        assertEq(imd.balanceOf(creator) - creatorBefore, net - payout, "creator refunded");
        assertEq(box.remaining(id), 0);
        assertEq(box.totalEscrow(), box.claimable(bob), "credit stays inside escrow");
        (, uint256[] memory shares) = box.grabbers(id);
        assertEq(shares[1], box.claimable(bob));
        _assertAccounting();
        // Nobody can take the credit as surplus, reveal and settle are closed, and claim pays bob.
        vm.expectRevert(HongbaoBox.NoSurplus.selector);
        box.recoverSurplus();
        vm.expectRevert(HongbaoBox.PacketClosed.selector);
        _reveal(id);
        vm.expectRevert(HongbaoBox.PacketClosed.selector);
        box.settle(id);
        imd.setBlocked(address(0));
        vm.expectEmit(address(box));
        emit HongbaoBox.Claimed(bob, bob, payout - payout / 2);
        vm.prank(relayer);
        assertEq(box.claim(bob, bob), payout - payout / 2);
        assertEq(imd.balanceOf(bob), payout - payout / 2);
        assertEq(box.claimable(bob), 0);
        assertEq(box.totalEscrow(), 0);
        _assertAccounting();
    }

    function testSettleCreditsBlockedCreatorRefundAndCreatorCanRedirectIt() public {
        uint256 id = _create(1 ether, 3, true);
        uint256 net = box.packet(id).amount;
        _grab(id, alice);
        _grab(id, bob);
        vm.warp(box.settlementTime(id));
        imd.setBlocked(creator);
        box.settle(id);
        assertEq(uint256(box.packet(id).state), uint256(HongbaoBox.State.Settled));
        assertGt(imd.balanceOf(alice), 0);
        assertGt(imd.balanceOf(bob), 0);
        assertEq(box.claimable(creator), net - net * 2 / 3);
        _assertAccounting();
        // While IMD still refuses the creator's address, only the creator may redirect the credit.
        vm.expectRevert(HongbaoBox.NotRecipient.selector);
        vm.prank(relayer);
        box.claim(creator, relayer);
        vm.expectRevert(MockIMD.Blocked.selector);
        vm.prank(relayer);
        box.claim(creator, creator);
        assertEq(box.claimable(creator), net - net * 2 / 3, "failed claim keeps the credit");
        vm.prank(creator);
        assertEq(box.claim(creator, carol), net - net * 2 / 3);
        assertEq(imd.balanceOf(carol), net - net * 2 / 3);
        assertEq(box.claimable(creator), 0);
        _assertAccounting();
    }

    function testEqualRefundCreditsBlockedCreatorInsteadOfRevertingForever() public {
        uint256 id = _create(1 ether, 3, false);
        _grab(id, alice);
        vm.warp(box.packet(id).expiry);
        uint256 owed = box.remaining(id);
        uint256 creatorBefore = imd.balanceOf(creator);
        imd.setBlocked(creator);
        vm.expectEmit(address(box));
        emit HongbaoBox.PayoutDeferred(id, creator, owed);
        box.refund(id);
        assertEq(uint256(box.packet(id).state), uint256(HongbaoBox.State.Refunded));
        assertEq(box.remaining(id), 0);
        assertEq(box.claimable(creator), owed);
        assertEq(imd.balanceOf(creator), creatorBefore);
        _assertAccounting();
        vm.expectRevert(HongbaoBox.PacketClosed.selector);
        box.refund(id);
        imd.setBlocked(address(0));
        box.claim(creator, creator);
        assertEq(imd.balanceOf(creator), creatorBefore + owed);
        _assertAccounting();
    }

    function testClaimRejectsEmptyCreditsAndInvalidDestinations() public {
        vm.expectRevert(HongbaoBox.InvalidRecipient.selector);
        box.claim(alice, address(0));
        vm.expectRevert(HongbaoBox.InvalidRecipient.selector);
        box.claim(alice, address(box));
        vm.expectRevert(HongbaoBox.NothingToClaim.selector);
        box.claim(alice, alice);
        vm.prank(alice);
        vm.expectRevert(HongbaoBox.NothingToClaim.selector);
        box.claim(alice, bob);
        vm.expectRevert(HongbaoBox.NotRecipient.selector);
        vm.prank(bob);
        box.claim(alice, bob);
    }

    function testCreditsAccumulateAcrossPacketsAndSurvivePartialClaims() public {
        uint256 first = _create(1 ether, 2, false);
        uint256 second = _create(2 ether, 2, false);
        _grab(first, alice);
        _grab(second, alice);
        vm.warp(box.packet(second).expiry);
        imd.setBlocked(creator);
        box.refund(first);
        box.refund(second);
        uint256 expected = box.packet(first).amount / 2 + box.packet(second).amount / 2;
        assertEq(box.claimable(creator), expected);
        assertEq(box.totalEscrow(), expected);
        _assertAccounting();
        // Unsolicited IMD above the credits is still recoverable, but never the credits themselves.
        imd.mint(address(box), 0.25 ether);
        vm.prank(bob);
        assertEq(box.recoverSurplus(), 0.25 ether);
        assertEq(box.totalEscrow(), expected);
        _assertAccounting();
        imd.setBlocked(address(0));
        box.claim(creator, creator);
        assertEq(box.totalEscrow(), 0);
        _assertAccounting();
    }

    function testSettleCreditsSilentNoOpAndFalseReturnsButRejectsInexactMoves() public {
        uint256 id = _create(1 ether, 2, true);
        _grab(id, alice);
        _grab(id, bob);
        vm.warp(box.settlementTime(id));
        // Balances moving by the wrong amount is a broken token, not a refused recipient: whole batch reverts.
        imd.setMode(MockIMD.Mode.FeeOut);
        vm.expectRevert(HongbaoBox.InexactTransfer.selector);
        box.settle(id);
        imd.setMode(MockIMD.Mode.SenderFeeOut);
        vm.expectRevert(HongbaoBox.InexactTransfer.selector);
        box.settle(id);
        _assertUnpaidLucky(id, 2);
        // Nothing moving at all is treated like a refusal: credited, never lost.
        imd.setMode(MockIMD.Mode.FalseOut);
        box.settle(id);
        uint256 net = box.packet(id).amount;
        assertEq(box.claimable(alice), net / 2);
        assertEq(box.claimable(bob), net - net / 2);
        assertEq(imd.balanceOf(address(box)), net);
        _assertAccounting();
        imd.setMode(MockIMD.Mode.Normal);
        box.claim(alice, alice);
        box.claim(bob, bob);
        assertEq(imd.balanceOf(alice) + imd.balanceOf(bob), net);
        _assertAccounting();

        uint256 other = _create(1 ether, 1, true);
        _grab(other, carol);
        vm.warp(box.settlementTime(other));
        imd.setMode(MockIMD.Mode.NoOpOut);
        box.settle(other);
        assertEq(box.claimable(carol), box.packet(other).amount);
        _assertAccounting();
    }

    function testClaimRejectsReentryAndCannotRecoverCreditsAsSurplus() public {
        uint256 id = _create(1 ether, 2, false);
        _grab(id, alice);
        vm.warp(box.packet(id).expiry);
        imd.setBlocked(creator);
        box.refund(id);
        imd.setBlocked(address(0));
        imd.setCallback(address(box), abi.encodeCall(box.recoverSurplus, ()), false, true);
        box.claim(creator, creator);
        _assertGuardedCallback();
        imd.setCallback(address(box), abi.encodeCall(box.claim, (creator, creator)), false, true);
        _create(1 ether, 1, false);
        _assertGuardedCallback();
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
