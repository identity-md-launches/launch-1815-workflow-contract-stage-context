// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {HongbaoTestBase} from "./helpers/HongbaoTestBase.sol";
import {MockIMD} from "./helpers/MockIMD.sol";
import {HongbaoBox} from "../src/HongbaoBox.sol";

contract HongbaoLuckyTest is HongbaoTestBase {
    function testLuckyGrabPaysNothingUntilFullReveal() public {
        uint256 id = _create(1 ether, 2, true);
        uint256 net = box.packet(id).amount;
        _grab(id, alice);
        assertEq(imd.balanceOf(alice), 0);
        (, uint256[] memory beforeShares) = box.grabbers(id);
        assertEq(beforeShares[0], 0);
        vm.expectRevert(HongbaoBox.NotReady.selector);
        _reveal(id);
        _grab(id, bob);
        vm.expectRevert(HongbaoBox.PacketFull.selector);
        box.grab(id, carol, "");
        _reveal(id);
        (, uint256[] memory shares) = box.grabbers(id);
        assertEq(shares[0] + shares[1], net);
        assertEq(imd.balanceOf(alice), shares[0]);
        assertEq(imd.balanceOf(bob), shares[1]);
        assertGe(shares[0], MIN);
        assertGe(shares[1], MIN);
        assertEq(box.bestLuck(id), shares[0] >= shares[1] ? alice : bob);
        assertEq(uint256(box.packet(id).state), uint256(HongbaoBox.State.Revealed));
        _assertAccounting();
        _assertTerminal(id);
    }

    function testCreatorOnlyAndWrongSecret() public {
        uint256 id = _create(1 ether, 1, true);
        _grab(id, alice);
        vm.expectRevert(HongbaoBox.NotCreator.selector);
        box.reveal(id, SECRET);
        vm.expectRevert(HongbaoBox.WrongSecret.selector);
        vm.prank(creator);
        box.reveal(id, bytes32(uint256(42)));
        assertEq(box.packet(id).grabbed, 1);
        assertEq(box.remaining(id), box.packet(id).amount);
        _reveal(id);
        assertEq(imd.balanceOf(alice), box.packet(id).amount);
        _assertAccounting();
    }

    function testPartialRevealScalesOnlyGrabbedSlotsAndRefundsCreator() public {
        uint256 id = _create(_grossForNet(1 ether + 2), 7, true);
        _grab(id, alice);
        _grab(id, bob);
        uint256 net = box.packet(id).amount;
        uint256 payout = net * 2 / 7;
        uint256 beforeCreator = imd.balanceOf(creator);
        vm.warp(box.packet(id).expiry);
        _reveal(id);
        assertEq(imd.balanceOf(alice) + imd.balanceOf(bob), payout);
        assertEq(imd.balanceOf(creator), beforeCreator + net - payout);
        _assertAccounting();
    }

    function testNoGrabsCanRevealOrSettleWithFullRefund() public {
        uint256 first = _create(1 ether, 5, true);
        uint256 second = _create(2 ether, 7, true);
        uint256 beforeCreator = imd.balanceOf(creator);
        vm.warp(box.packet(first).expiry);
        vm.expectEmit(true, true, false, true, address(box));
        emit HongbaoBox.Revealed(first, address(0), 0, 0, box.packet(first).amount);
        _reveal(first);
        assertEq(box.bestLuck(first), address(0));
        vm.warp(box.settlementTime(second));
        box.settle(second);
        assertEq(imd.balanceOf(creator), beforeCreator + box.packet(first).amount + box.packet(second).amount);
        _assertAccounting();
    }

    function testFilledDeadlineStartsOnFinalGrabAndSettleIsPermissionless() public {
        uint256 id = _createWith(box, _grossForNet(1 ether), 3, true, 7 days, SECRET);
        _grab(id, alice);
        _grab(id, bob);
        uint256 initialTime = vm.getBlockTimestamp();
        vm.warp(initialTime + 1 hours);
        _grab(id, carol);
        assertEq(box.filledAt(id), initialTime + 1 hours);
        uint256 deadline = initialTime + 25 hours;
        assertEq(box.settlementTime(id), deadline);
        assertLt(deadline, box.packet(id).expiry);
        vm.warp(deadline - 1);
        vm.expectRevert(abi.encodeWithSelector(HongbaoBox.TooEarly.selector, deadline));
        box.settle(id);
        vm.warp(deadline);
        vm.expectEmit(true, false, false, true, address(box));
        emit HongbaoBox.Settled(id, 1 ether, 0);
        vm.prank(relayer);
        box.settle(id);
        (, uint256[] memory shares) = box.grabbers(id);
        assertEq(shares[0], uint256(1 ether) / 3);
        assertEq(shares[1], shares[0]);
        assertEq(shares[2], 1 ether - 2 * shares[0]);
        assertEq(box.bestLuck(id), address(0));
        assertEq(uint256(box.packet(id).state), uint256(HongbaoBox.State.Settled));
        _assertAccounting();
        _assertTerminal(id);
    }

    function testPartialSettleDeadlineIsExpiryPlusGrace() public {
        uint256 id = _create(_grossForNet(1 ether + 6), 5, true);
        _grab(id, alice);
        _grab(id, bob);
        uint256 deadline = box.packet(id).expiry + 24 hours;
        assertEq(box.settlementTime(id), deadline);
        vm.warp(deadline - 1);
        vm.expectRevert(abi.encodeWithSelector(HongbaoBox.TooEarly.selector, deadline));
        box.settle(id);
        vm.warp(deadline);
        uint256 beforeCreator = imd.balanceOf(creator);
        box.settle(id);
        uint256 payout = box.packet(id).amount * 2 / 5;
        assertEq(imd.balanceOf(alice), payout / 2);
        assertEq(imd.balanceOf(bob), payout - payout / 2);
        assertEq(imd.balanceOf(creator), beforeCreator + box.packet(id).amount - payout);
        _assertAccounting();
    }

    function testRevealCanWinRaceAfterSettleDeadline() public {
        uint256 id = _create(1 ether, 1, true);
        _grab(id, alice);
        vm.warp(box.settlementTime(id) + 1);
        _reveal(id);
        vm.expectRevert(HongbaoBox.PacketClosed.selector);
        box.settle(id);
        _assertAccounting();
    }

    function testMinimumFunded200SlotRevealAndTieUsesFirstGrabber() public {
        uint256 id = _create(_grossForNet(200 * MIN), 200, true);
        for (uint256 i; i < 200; ++i) {
            _grab(id, address(uint160(0x1000 + i)));
        }
        vm.expectEmit(true, true, false, true, address(box));
        emit HongbaoBox.Revealed(id, address(0x1000), MIN, 200 * MIN, 0);
        uint256 gasBefore = gasleft();
        _reveal(id);
        uint256 used = gasBefore - gasleft();
        emit log_named_uint("200 recipient reveal gas (mock IMD)", used);
        assertLt(used, 15_000_000, "bounded batch gas");
        (, uint256[] memory shares) = box.grabbers(id);
        for (uint256 i; i < 200; ++i) {
            assertEq(shares[i], MIN);
            assertEq(imd.balanceOf(address(uint160(0x1000 + i))), MIN);
        }
        assertEq(box.bestLuck(id), address(0x1000));
        _assertAccounting();
    }

    function testFullUint256AmountsDoNotOverflowProportionsOrDoubleAverage() public {
        MockIMD huge = new MockIMD();
        HongbaoBox target = new HongbaoBox(address(huge));
        huge.mint(creator, type(uint256).max);
        vm.prank(creator);
        huge.approve(address(target), type(uint256).max);
        uint256 id = _createWith(target, type(uint256).max, 3, true, 10 minutes, SECRET);
        target.grab(id, alice, _sign(target, id, alice));
        target.grab(id, bob, _sign(target, id, bob));
        vm.warp(target.packet(id).expiry);
        vm.prank(creator);
        target.reveal(id, SECRET);
        uint256 net = type(uint256).max - type(uint256).max / 200;
        uint256 payout = Math.mulDiv(net, 2, 3);
        assertEq(huge.balanceOf(alice) + huge.balanceOf(bob), payout);
        assertEq(huge.balanceOf(creator), net - payout);
        assertEq(huge.balanceOf(address(target)), 0);
        assertEq(target.totalEscrow(), 0);
    }

    function testPublishedLuckyDrawVector() public {
        uint256 id = _create(1 ether, 3, true);
        _grab(id, address(0x1000));
        _grab(id, address(0x1001));
        _grab(id, address(0x1002));
        _reveal(id);
        (, uint256[] memory shares) = box.grabbers(id);
        // Independently calculated with cast ABI encoding and Python integer arithmetic.
        assertEq(shares[0], 70_586_284_642_358_507);
        assertEq(shares[1], 548_424_350_498_568_867);
        assertEq(shares[2], 375_989_364_859_072_626);
        assertEq(box.bestLuck(id), address(0x1001));
        _assertAccounting();
    }

    function testFuzzLuckyBoundsConservationAndRefund(uint256 extra, uint8 rawSlots, uint8 rawCount, bytes32 secret)
        public
    {
        uint256 slots = bound(uint256(rawSlots), 1, 200);
        uint256 count = bound(uint256(rawCount), 0, slots);
        uint256 net = MIN * slots + bound(extra, 0, 10_000 ether);
        uint256 id = _createWith(box, _grossForNet(net), slots, true, 10 minutes, secret);
        for (uint256 i; i < count; ++i) {
            _grab(id, address(uint160(0x1000 + i)));
        }
        vm.warp(box.packet(id).expiry);
        uint256 beforeCreator = imd.balanceOf(creator);
        vm.prank(creator);
        box.reveal(id, secret);
        (, uint256[] memory shares) = box.grabbers(id);
        uint256 payout = net * count / slots;
        uint256 rest = payout;
        uint256 largest;
        address winner;
        for (uint256 i; i < count; ++i) {
            assertGe(shares[i], MIN);
            if (i + 1 < count) {
                assertLe(shares[i], 2 * rest / (count - i));
                assertGe(rest - shares[i], MIN * (count - i - 1));
            }
            if (shares[i] > largest) {
                largest = shares[i];
                winner = address(uint160(0x1000 + i));
            }
            rest -= shares[i];
            assertEq(imd.balanceOf(address(uint160(0x1000 + i))), shares[i]);
        }
        assertEq(rest, 0);
        assertEq(box.bestLuck(id), winner);
        assertEq(imd.balanceOf(creator), beforeCreator + net - payout);
        _assertAccounting();
    }

    function testFuzzEqualFallbackConservesFunds(uint8 rawSlots, uint8 rawCount, uint128 extra) public {
        uint256 slots = bound(uint256(rawSlots), 1, 200);
        uint256 count = bound(uint256(rawCount), 0, slots);
        uint256 net = MIN * slots + bound(uint256(extra), 0, 10_000 ether);
        uint256 id = _create(_grossForNet(net), slots, true);
        for (uint256 i; i < count; ++i) {
            _grab(id, address(uint160(0x1000 + i)));
        }
        vm.warp(box.settlementTime(id));
        uint256 beforeCreator = imd.balanceOf(creator);
        box.settle(id);
        (, uint256[] memory shares) = box.grabbers(id);
        uint256 payout = net * count / slots;
        uint256 sum;
        for (uint256 i; i < count; ++i) {
            assertGe(shares[i], MIN);
            assertEq(shares[i], i + 1 == count ? payout - sum : payout / count);
            sum += shares[i];
        }
        assertEq(sum, payout);
        assertEq(imd.balanceOf(creator), beforeCreator + net - payout);
        _assertAccounting();
    }

    function _assertTerminal(uint256 id) internal {
        vm.expectRevert(HongbaoBox.PacketClosed.selector);
        box.grab(id, relayer, "");
        vm.expectRevert(HongbaoBox.PacketClosed.selector);
        _reveal(id);
        vm.expectRevert(HongbaoBox.PacketClosed.selector);
        box.settle(id);
        vm.expectRevert(HongbaoBox.PacketClosed.selector);
        box.refund(id);
    }
}
