// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HongbaoTestBase} from "./helpers/HongbaoTestBase.sol";
import {HongbaoBox} from "../src/HongbaoBox.sol";

contract HongbaoBoxTest is HongbaoTestBase {
    function testCreateBurnNetFieldsAndSequentialIds() public {
        uint256 beforeCreator = imd.balanceOf(creator);
        uint256 gross = 1 ether + 199;
        uint256 net = gross - gross / 200;
        vm.expectEmit(true, true, false, true, address(box));
        emit HongbaoBox.PacketCreated(
            1,
            creator,
            gross,
            net,
            gross / 200,
            3,
            true,
            block.timestamp + 10 minutes,
            keyAddress,
            SALT,
            keccak256(abi.encodePacked(SECRET))
        );
        assertEq(_create(gross, 3, true), 1);
        HongbaoBox.Packet memory p = box.packet(1);
        assertEq(p.creator, creator);
        assertEq(p.amount, net);
        assertEq(p.slots, 3);
        assertEq(p.grabbed, 0);
        assertTrue(p.lucky);
        assertEq(p.expiry, block.timestamp + 10 minutes);
        assertEq(p.keyAddress, keyAddress);
        assertEq(p.salt, SALT);
        assertEq(uint256(p.state), uint256(HongbaoBox.State.Open));
        assertEq(imd.balanceOf(creator), beforeCreator - gross);
        assertEq(imd.balanceOf(box.BURN_ADDRESS()), gross / 200);
        assertEq(_create(2 ether, 1, false), 2);
        _assertAccounting();
    }

    function testSlotAndDurationBounds() public {
        vm.startPrank(creator);
        vm.expectRevert(HongbaoBox.InvalidSlots.selector);
        box.create(10 ether, 0, false, keyAddress, SALT, 10 minutes, bytes32(0));
        vm.expectRevert(HongbaoBox.InvalidSlots.selector);
        box.create(10 ether, 201, false, keyAddress, SALT, 10 minutes, bytes32(0));
        vm.expectRevert(HongbaoBox.InvalidDuration.selector);
        box.create(10 ether, 1, false, keyAddress, SALT, 10 minutes - 1, bytes32(0));
        vm.expectRevert(HongbaoBox.InvalidDuration.selector);
        box.create(10 ether, 1, false, keyAddress, SALT, 7 days + 1, bytes32(0));
        box.create(10 ether, 200, false, keyAddress, SALT, 10 minutes, bytes32(0));
        box.create(10 ether, 1, false, keyAddress, SALT, 7 days, bytes32(0));
        vm.stopPrank();
        _assertAccounting();
    }

    function testNetMinimumAccountsForBurn() public {
        uint256 gross = _grossForNet(200 * MIN);
        vm.expectRevert(HongbaoBox.AmountTooSmall.selector);
        _create(gross - 1, 200, false);
        _create(gross, 200, false);
        assertEq(box.packet(1).amount, 200 * MIN);
        vm.expectRevert(HongbaoBox.AmountTooSmall.selector);
        _create(0, 1, false);
    }

    function testInvalidKeyAndCommitment() public {
        vm.startPrank(creator);
        vm.expectRevert(HongbaoBox.InvalidKey.selector);
        box.create(1 ether, 1, false, address(0), SALT, 10 minutes, bytes32(0));
        vm.expectRevert(HongbaoBox.InvalidCommitment.selector);
        box.create(1 ether, 1, true, keyAddress, SALT, 10 minutes, bytes32(0));
        vm.expectRevert(HongbaoBox.InvalidCommitment.selector);
        box.create(1 ether, 1, false, keyAddress, SALT, 10 minutes, SECRET);
        vm.stopPrank();
        assertEq(box.nextPacketId(), 1);
        _assertAccounting();
    }

    function testConstructorNeedsNoLiveTokenAndRejectsZero() public {
        address notDeployed = makeAddr("not yet deployed IMD");
        HongbaoBox deferred = new HongbaoBox(notDeployed);
        assertEq(address(deferred.imd()), notDeployed);
        vm.expectRevert(HongbaoBox.InvalidToken.selector);
        _createWith(deferred, 1 ether, 1, false, 10 minutes, SECRET);
        vm.expectRevert(HongbaoBox.InvalidToken.selector);
        new HongbaoBox(address(0));
    }

    function testEqualGrabsImmediateLastGetsRemainderAndCloses() public {
        uint256 id = _create(_grossForNet(1 ether), 3, false);
        uint256 first = uint256(1 ether) / 3;
        vm.expectEmit(true, true, false, true, address(box));
        emit HongbaoBox.Grabbed(id, alice, 0, first);
        _grab(id, alice);
        assertEq(imd.balanceOf(alice), first);
        assertEq(imd.balanceOf(relayer), 0);
        _assertAccounting();
        _grab(id, bob);
        _grab(id, carol);
        assertEq(imd.balanceOf(carol), 1 ether - 2 * first);
        assertEq(uint256(box.packet(id).state), uint256(HongbaoBox.State.Completed));
        (address[] memory recipients, uint256[] memory shares) = box.grabbers(id);
        assertEq(recipients.length, 3);
        assertEq(recipients[0], alice);
        assertEq(recipients[1], bob);
        assertEq(recipients[2], carol);
        assertEq(shares[0] + shares[1] + shares[2], 1 ether);
        _assertAccounting();
        vm.expectRevert(HongbaoBox.PacketClosed.selector);
        box.grab(id, relayer, "");
        vm.warp(block.timestamp + 10 minutes);
        vm.expectRevert(HongbaoBox.PacketClosed.selector);
        box.refund(id);
    }

    function testDuplicateRecipientAndBadRecipients() public {
        uint256 id = _create(1 ether, 3, false);
        _grab(id, alice);
        bytes memory signature = _sign(box, id, alice);
        vm.expectRevert(HongbaoBox.AlreadyGrabbed.selector);
        box.grab(id, alice, signature);
        vm.expectRevert(HongbaoBox.InvalidRecipient.selector);
        box.grab(id, address(0), "");
        vm.expectRevert(HongbaoBox.InvalidRecipient.selector);
        box.grab(id, address(box), "");
        _assertAccounting();
    }

    function testExpiryBoundaryAndPermissionlessRefund() public {
        uint256 id = _create(1 ether, 3, false);
        uint256 expiry = box.packet(id).expiry;
        vm.warp(expiry - 1);
        _grab(id, alice);
        vm.expectRevert(abi.encodeWithSelector(HongbaoBox.TooEarly.selector, expiry));
        box.refund(id);
        vm.warp(expiry);
        vm.expectRevert(HongbaoBox.PacketExpired.selector);
        box.grab(id, bob, "");
        uint256 refundAmount = box.remaining(id);
        uint256 beforeCreator = imd.balanceOf(creator);
        vm.expectEmit(true, true, false, true, address(box));
        emit HongbaoBox.Refunded(id, creator, refundAmount);
        vm.prank(relayer);
        box.refund(id);
        assertEq(imd.balanceOf(creator), beforeCreator + refundAmount);
        assertEq(imd.balanceOf(relayer), 0);
        assertEq(uint256(box.packet(id).state), uint256(HongbaoBox.State.Refunded));
        vm.expectRevert(HongbaoBox.PacketClosed.selector);
        box.refund(id);
        _assertAccounting();
    }

    function testNoGrabRefundReturnsAllNetAndBurnIsPermanent() public {
        uint256 beforeCreator = imd.balanceOf(creator);
        uint256 id = _create(1 ether, 2, false);
        vm.warp(box.packet(id).expiry);
        box.refund(id);
        assertEq(imd.balanceOf(creator), beforeCreator - 1 ether / 200);
        assertEq(imd.balanceOf(box.BURN_ADDRESS()), 1 ether / 200);
        _assertAccounting();
    }

    function testUnknownPacketsAndWrongModes() public {
        vm.expectRevert(HongbaoBox.UnknownPacket.selector);
        box.packet(0);
        vm.expectRevert(HongbaoBox.UnknownPacket.selector);
        box.grabbers(1);
        vm.expectRevert(HongbaoBox.UnknownPacket.selector);
        box.grab(99, alice, "");
        vm.expectRevert(HongbaoBox.UnknownPacket.selector);
        box.reveal(99, SECRET);
        vm.expectRevert(HongbaoBox.UnknownPacket.selector);
        box.settle(99);
        vm.expectRevert(HongbaoBox.UnknownPacket.selector);
        box.refund(99);
        uint256 equal = _create(1 ether, 1, false);
        uint256 lucky = _create(1 ether, 1, true);
        vm.expectRevert(HongbaoBox.NotLucky.selector);
        box.reveal(equal, SECRET);
        vm.expectRevert(HongbaoBox.NotLucky.selector);
        box.settle(equal);
        vm.expectRevert(HongbaoBox.NotLucky.selector);
        box.settlementTime(equal);
        vm.expectRevert(HongbaoBox.NotEqual.selector);
        box.refund(lucky);
    }

    function testSurplusCannotTouchAnyPacketAndCanBeRecovered() public {
        _create(1 ether, 2, true);
        _create(2 ether, 2, false);
        uint256 escrow = box.totalEscrow();
        vm.expectRevert(HongbaoBox.NoSurplus.selector);
        box.recoverSurplus();
        imd.mint(address(box), 0.5 ether);
        vm.expectEmit(true, false, false, true, address(box));
        emit HongbaoBox.SurplusRecovered(alice, 0.5 ether);
        vm.prank(alice);
        assertEq(box.recoverSurplus(), 0.5 ether);
        assertEq(imd.balanceOf(alice), 0.5 ether);
        assertEq(box.totalEscrow(), escrow);
        _assertAccounting();
    }

    function testCreatorCanBeARecipientWithoutAccountingDrift() public {
        uint256 id = _create(1 ether, 2, true);
        _grab(id, creator);
        vm.warp(box.packet(id).expiry);
        _reveal(id);
        _assertAccounting();
        assertEq(imd.balanceOf(creator), 1_000_000 ether - 1 ether / 200);
    }
}
