// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HongbaoBox} from "src/HongbaoBox.sol";
import {HongbaoTestBase} from "./helpers/HongbaoTestBase.sol";
import {MockIMD} from "./helpers/MockIMD.sol";

contract HongbaoArithmeticTest is HongbaoTestBase {
    /// forge-config: default.fuzz.runs = 1000
    function testFuzzFullWidthLuckyAmounts(uint256 gross, uint256 slotSeed, uint256 countSeed, bool fallbackPayout)
        public
    {
        uint256 slots = bound(slotSeed, 1, 200);
        uint256 count = bound(countSeed, 0, slots);
        gross = bound(gross, _grossForNet(slots * MIN), type(uint256).max);
        _checkFullWidthPayout(gross, slots, count, fallbackPayout);
    }

    function testMaximumAmountAndMaximumSlotsReveal() public {
        _checkFullWidthPayout(type(uint256).max, 200, 200, false);
    }

    function testMaximumAmountAndMaximumSlotsSettlePartialPacket() public {
        _checkFullWidthPayout(type(uint256).max, 200, 199, true);
    }

    function testMaximumAmountWithNoGrabbersRefundsEntireNet() public {
        _checkFullWidthPayout(type(uint256).max, 200, 0, false);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzzMinimumFundingBoundary(uint256 slotSeed, bool lucky) public {
        uint256 slots = bound(slotSeed, 1, 200);
        uint256 gross = _grossForNet(slots * MIN);
        vm.expectRevert(HongbaoBox.AmountTooSmall.selector);
        _create(gross - 1, slots, lucky);
        assertEq(box.nextPacketId(), 1);
        assertEq(imd.balanceOf(creator), 1_000_000 ether);
        uint256 id = _create(gross, slots, lucky);
        assertEq(box.packet(id).amount, slots * MIN);
        _assertAccounting();
    }

    function _checkFullWidthPayout(uint256 gross, uint256 slots, uint256 count, bool fallbackPayout) private {
        MockIMD token = new MockIMD();
        HongbaoBox target = new HongbaoBox(address(token));
        token.mint(creator, gross);
        vm.prank(creator);
        token.approve(address(target), gross);
        uint256 id = _createWith(target, gross, slots, true, 10 minutes, SECRET);
        for (uint256 i; i < count; ++i) {
            address recipient = address(uint160(0x2000 + i));
            target.grab(id, recipient, _sign(target, id, recipient));
            assertEq(token.balanceOf(recipient), 0, "lucky grabs defer all payouts");
        }
        vm.warp(fallbackPayout ? target.settlementTime(id) : target.packet(id).expiry);
        if (fallbackPayout) {
            target.settle(id);
        } else {
            vm.prank(creator);
            target.reveal(id, SECRET);
        }
        uint256 net = gross - gross / 200;
        // Independent overflow-free decomposition, instead of copying the target's mulDiv call.
        uint256 payout = (net / slots) * count + ((net % slots) * count) / slots;
        (address[] memory recipients, uint256[] memory shares) = target.grabbers(id);
        assertEq(recipients.length, count);
        assertEq(shares.length, count);
        uint256 paid;
        uint256 largest;
        address winner;
        for (uint256 i; i < count; ++i) {
            assertEq(recipients[i], address(uint160(0x2000 + i)));
            assertEq(token.balanceOf(recipients[i]), shares[i]);
            assertGe(shares[i], MIN);
            if (fallbackPayout) {
                assertEq(shares[i], i + 1 == count ? payout - paid : payout / count);
            } else {
                uint256 left = count - i;
                if (left > 1) {
                    uint256 rest = payout - paid;
                    uint256 doubleAverage = (rest / left) * 2 + ((rest % left) * 2) / left;
                    assertLe(shares[i], doubleAverage);
                    assertLe(shares[i], rest - MIN * (left - 1));
                }
                if (shares[i] > largest) {
                    largest = shares[i];
                    winner = recipients[i];
                }
            }
            paid += shares[i];
        }
        assertEq(target.bestLuck(id), fallbackPayout ? address(0) : winner);
        assertEq(paid, payout, "shares exhaust the proportional payout at uint256 scale");
        assertEq(token.balanceOf(creator), net - payout, "ungrabbed part refunded exactly");
        assertEq(token.balanceOf(target.BURN_ADDRESS()), gross / 200);
        assertEq(token.balanceOf(address(target)), 0);
        assertEq(target.remaining(id), 0);
        assertEq(target.totalEscrow(), 0);
        assertEq(token.totalSupply(), gross);
        assertEq(
            uint256(target.packet(id).state),
            uint256(fallbackPayout ? HongbaoBox.State.Settled : HongbaoBox.State.Revealed)
        );
    }
}
