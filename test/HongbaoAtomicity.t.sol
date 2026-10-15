// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {HongbaoBox} from "src/HongbaoBox.sol";
import {HongbaoTestBase} from "./helpers/HongbaoTestBase.sol";
import {MockIMD} from "./helpers/MockIMD.sol";

contract HongbaoAtomicityTest is HongbaoTestBase {
    /// @dev Enumerate this finite matrix so every payout path sees every outbound failure mode.
    function testAllOutboundModesRollbackAndRetryEveryPayoutPath() public {
        MockIMD.Mode[4] memory modes =
            [MockIMD.Mode.FeeOut, MockIMD.Mode.SenderFeeOut, MockIMD.Mode.NoOpOut, MockIMD.Mode.FalseOut];
        for (uint256 operation; operation < 5; ++operation) {
            for (uint256 mode; mode < modes.length; ++mode) {
                setUp();
                uint256 equal = _create(1 ether, 2, false);
                uint256 lucky = _create(2 ether, 3, true);
                _create(3 ether, 2, true); // Other packets must remain solvent on sender surcharges.
                _grab(equal, alice);
                _grab(lucky, bob);
                _grab(lucky, carol);
                imd.mint(address(box), 1 ether);
                bytes memory signature = _sign(box, equal, bob);
                if (operation != 0) vm.warp(box.settlementTime(lucky));
                bytes32 beforeState = _snapshot();
                imd.setMode(modes[mode]);
                if (modes[mode] == MockIMD.Mode.FalseOut) {
                    vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(imd)));
                } else {
                    vm.expectRevert(HongbaoBox.InexactTransfer.selector);
                }
                _act(operation, equal, lucky, signature);
                assertEq(_snapshot(), beforeState, "failed payout must roll back balances, shares and terminal state");
                imd.setMode(MockIMD.Mode.Normal);
                _act(operation, equal, lucky, signature);
                if (operation == 0) {
                    assertEq(uint256(box.packet(equal).state), uint256(HongbaoBox.State.Completed));
                    assertTrue(box.hasGrabbed(equal, bob));
                } else if (operation == 1) {
                    assertEq(uint256(box.packet(lucky).state), uint256(HongbaoBox.State.Revealed));
                } else if (operation == 2) {
                    assertEq(uint256(box.packet(lucky).state), uint256(HongbaoBox.State.Settled));
                } else if (operation == 3) {
                    assertEq(uint256(box.packet(equal).state), uint256(HongbaoBox.State.Refunded));
                } else {
                    assertEq(imd.balanceOf(relayer), 1 ether);
                }
                if (operation != 4) box.recoverSurplus();
                _assertAccounting();
            }
        }
    }

    function testRevealCreatorRecipientFailureRollsBackEarlierPayoutsAndWinner() public {
        uint256 id = _create(3 ether, 4, true);
        _grab(id, alice);
        _grab(id, creator); // Creator is second in payout order and is also owed a refund.
        vm.warp(box.packet(id).expiry);
        imd.setBlocked(creator);
        bytes32 beforeState = _snapshot();
        vm.expectRevert(MockIMD.Blocked.selector);
        _reveal(id);
        assertEq(_snapshot(), beforeState);
        assertEq(box.bestLuck(id), address(0));
        imd.setBlocked(address(0));
        _reveal(id);
        _assertAccounting();
    }

    function testRevealRefundFailureAfterAllGrabberTransfersRollsBackBatch() public {
        uint256 id = _create(3 ether, 4, true);
        _grab(id, alice);
        _grab(id, bob);
        vm.warp(box.packet(id).expiry);
        imd.setBlocked(creator);
        bytes32 beforeState = _snapshot();
        vm.expectRevert(MockIMD.Blocked.selector);
        _reveal(id);
        assertEq(_snapshot(), beforeState, "refund failure must undo both earlier successful transfers");
        imd.setBlocked(address(0));
        _reveal(id);
        _assertAccounting();
    }

    function _act(uint256 operation, uint256 equal, uint256 lucky, bytes memory signature) private {
        if (operation == 0) {
            box.grab(equal, bob, signature);
        } else if (operation == 1) {
            _reveal(lucky);
        } else if (operation == 2) {
            box.settle(lucky);
        } else if (operation == 3) {
            box.refund(equal);
        } else {
            vm.prank(relayer);
            box.recoverSurplus();
        }
    }

    function _snapshot() private view returns (bytes32 result) {
        result = keccak256(
            abi.encode(
                box.nextPacketId(),
                box.totalEscrow(),
                imd.totalSupply(),
                imd.balanceOf(address(box)),
                imd.balanceOf(creator),
                imd.balanceOf(alice),
                imd.balanceOf(bob),
                imd.balanceOf(carol),
                imd.balanceOf(relayer),
                imd.balanceOf(box.BURN_ADDRESS()),
                imd.allowance(creator, address(box))
            )
        );
        for (uint256 id = 1; id < box.nextPacketId(); ++id) {
            (address[] memory recipients, uint256[] memory shares) = box.grabbers(id);
            result = keccak256(
                abi.encode(
                    result,
                    box.packet(id),
                    box.remaining(id),
                    box.filledAt(id),
                    box.bestLuck(id),
                    box.revealCommitments(id),
                    recipients,
                    shares,
                    box.hasGrabbed(id, creator),
                    box.hasGrabbed(id, alice),
                    box.hasGrabbed(id, bob),
                    box.hasGrabbed(id, carol)
                )
            );
        }
    }
}
