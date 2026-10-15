// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {HongbaoBox} from "../src/HongbaoBox.sol";
import {MockIMD} from "./helpers/MockIMD.sol";

/// @dev Generates valid interleavings; any unexpected revert fails the invariant campaign.
contract HongbaoHandler is Test {
    HongbaoBox public immutable box;
    MockIMD public immutable imd;
    address public immutable keyAddress;
    uint256 private immutable key;
    mapping(uint256 => bytes32) private secrets;
    mapping(uint256 => uint256) public terminalState;
    uint256 public creates;
    uint256 public grabs;
    uint256 public reveals;
    uint256 public settlements;
    uint256 public refunds;
    uint256 public claims;
    uint256 public totalBurned;
    uint256 public constant FUNDING = 1_000_000 ether;

    constructor(HongbaoBox target, MockIMD token) {
        box = target;
        imd = token;
        (address signer, uint256 signerKey) = makeAddrAndKey("stateful-test-key");
        keyAddress = signer;
        key = signerKey;
        token.mint(address(this), FUNDING);
        token.approve(address(target), type(uint256).max);
    }

    function createPacket(uint256 amountSeed, uint256 slotsSeed, bool lucky, uint256 durationSeed) external {
        if (creates >= 40) return;
        uint256 slots = bound(slotsSeed, 1, 8);
        uint256 net = slots * 1e16 + bound(amountSeed, 0, 100 ether);
        uint256 gross = net + (net - 1) / 199;
        uint256 expected = box.nextPacketId();
        bytes32 secret = keccak256(abi.encode("stateful test", expected, amountSeed));
        uint256 id = box.create(
            gross,
            slots,
            lucky,
            keyAddress,
            bytes32(expected),
            bound(durationSeed, 10 minutes, 7 days),
            lucky ? keccak256(abi.encodePacked(secret)) : bytes32(0)
        );
        secrets[id] = secret;
        totalBurned += gross / 200;
        ++creates;
    }

    function grabPacket(uint256 packetSeed, uint256 recipientSeed) external {
        if (creates == 0) return;
        uint256 id = bound(packetSeed, 1, creates);
        HongbaoBox.Packet memory p = box.packet(id);
        if (p.state != HongbaoBox.State.Open || p.grabbed == p.slots || block.timestamp >= p.expiry) return;
        address recipient = address(uint160(0x1000 + bound(recipientSeed, 0, 11)));
        if (box.hasGrabbed(id, recipient)) return;
        // An equal grab pays immediately and reverts for a blocked recipient; lucky grabs only record.
        if (!p.lucky && recipient == imd.blockedRecipient()) return;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, box.grabDigest(id, recipient));
        box.grab(id, recipient, abi.encodePacked(r, s, v));
        ++grabs;
        _rememberTerminal(id);
    }

    function revealPacket(uint256 packetSeed) external {
        if (creates == 0) return;
        uint256 id = bound(packetSeed, 1, creates);
        HongbaoBox.Packet memory p = box.packet(id);
        if (p.state != HongbaoBox.State.Open || !p.lucky || (p.grabbed < p.slots && block.timestamp < p.expiry)) {
            return;
        }
        // Reveal is atomic by design: it reverts while IMD refuses any recipient of the batch.
        address blocked = imd.blockedRecipient();
        if (blocked == address(this)) return;
        (address[] memory recipients,) = box.grabbers(id);
        for (uint256 i; i < recipients.length; ++i) {
            if (recipients[i] == blocked) return;
        }
        box.reveal(id, secrets[id]);
        ++reveals;
        _rememberTerminal(id);
    }

    /// @dev Models the IMD owner's blocklist: at most one address is refused at a time, or none.
    function blockRecipient(uint256 seed) external {
        uint256 pick = bound(seed, 0, 13);
        address target = pick == 13 ? address(0) : pick == 12 ? address(this) : address(uint160(0x1000 + pick));
        imd.setBlocked(target);
    }

    function claimCredit(uint256 seed) external {
        address recipient = _actor(bound(seed, 0, 12));
        if (box.claimable(recipient) == 0 || recipient == imd.blockedRecipient()) return;
        box.claim(recipient, recipient);
        ++claims;
    }

    function claimable() external view returns (uint256 sum) {
        for (uint256 i; i <= 12; ++i) {
            sum += box.claimable(_actor(i));
        }
    }

    function _actor(uint256 index) private view returns (address) {
        return index == 12 ? address(this) : address(uint160(0x1000 + index));
    }

    function settlePacket(uint256 packetSeed) external {
        if (creates == 0) return;
        uint256 id = bound(packetSeed, 1, creates);
        HongbaoBox.Packet memory p = box.packet(id);
        if (p.state != HongbaoBox.State.Open || !p.lucky || block.timestamp < box.settlementTime(id)) return;
        box.settle(id);
        ++settlements;
        _rememberTerminal(id);
    }

    function refundPacket(uint256 packetSeed) external {
        if (creates == 0) return;
        uint256 id = bound(packetSeed, 1, creates);
        HongbaoBox.Packet memory p = box.packet(id);
        if (p.state != HongbaoBox.State.Open || p.lucky || block.timestamp < p.expiry) return;
        box.refund(id);
        ++refunds;
        _rememberTerminal(id);
    }

    function advanceTime(uint256 delta) external {
        vm.warp(vm.getBlockTimestamp() + bound(delta, 0, 2 days));
    }

    /// @dev Invariant teardown proves all modeled obligations remain reachable, even with lost secrets
    /// and a recipient IMD refuses: fallbacks still close every packet, and credits drain once unblocked.
    function closeAll() external {
        vm.warp(vm.getBlockTimestamp() + 8 days);
        for (uint256 id = 1; id <= creates; ++id) {
            HongbaoBox.Packet memory p = box.packet(id);
            if (p.state != HongbaoBox.State.Open) continue;
            if (p.lucky) box.settle(id);
            else box.refund(id);
            _rememberTerminal(id);
        }
        imd.setBlocked(address(0));
        for (uint256 i; i <= 12; ++i) {
            address recipient = _actor(i);
            if (box.claimable(recipient) != 0) box.claim(recipient, recipient);
        }
    }

    function _rememberTerminal(uint256 id) private {
        uint256 state = uint256(box.packet(id).state);
        if (state != uint256(HongbaoBox.State.Open)) terminalState[id] = state;
    }
}

contract HongbaoInvariantTest is StdInvariant, Test {
    MockIMD private imd;
    HongbaoBox private box;
    HongbaoHandler private handler;

    function setUp() public {
        vm.chainId(4663);
        vm.warp(1_000_000);
        imd = new MockIMD();
        box = new HongbaoBox(address(imd));
        handler = new HongbaoHandler(box, imd);
        bytes4[] memory selectors = new bytes4[](8);
        selectors[0] = handler.createPacket.selector;
        selectors[1] = handler.grabPacket.selector;
        selectors[2] = handler.revealPacket.selector;
        selectors[3] = handler.settlePacket.selector;
        selectors[4] = handler.refundPacket.selector;
        selectors[5] = handler.advanceTime.selector;
        selectors[6] = handler.blockRecipient.selector;
        selectors[7] = handler.claimCredit.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariantBalanceEqualsIndependentOpenPacketLiabilities() public view {
        uint256 liabilities;
        for (uint256 id = 1; id < box.nextPacketId(); ++id) {
            HongbaoBox.Packet memory p = box.packet(id);
            (address[] memory recipients, uint256[] memory shares) = box.grabbers(id);
            assertEq(recipients.length, p.grabbed);
            assertEq(shares.length, p.grabbed);
            assertLe(p.grabbed, p.slots);
            uint256 paid;
            for (uint256 i; i < shares.length; ++i) {
                assertTrue(box.hasGrabbed(id, recipients[i]));
                for (uint256 j; j < i; ++j) {
                    assertNotEq(recipients[i], recipients[j]);
                }
                if (p.lucky && p.state == HongbaoBox.State.Open) assertEq(shares[i], 0);
                else assertGe(shares[i], 1e16);
                paid += shares[i];
            }
            uint256 owed;
            if (p.state == HongbaoBox.State.Open) {
                owed = p.amount - paid;
                liabilities += owed;
            } else {
                assertEq(uint256(p.state), handler.terminalState(id), "terminal state is immutable");
                if (p.lucky) assertEq(paid, p.amount * p.grabbed / p.slots);
                else if (p.state == HongbaoBox.State.Completed) assertEq(paid, p.amount);
            }
            assertEq(box.remaining(id), owed);
        }
        liabilities += handler.claimable();
        assertEq(imd.balanceOf(address(box)), liabilities);
        assertEq(box.totalEscrow(), liabilities);
    }

    function invariantAllIMDConservedAcrossCreatorEscrowBurnAndRecipients() public view {
        uint256 accounted = imd.balanceOf(address(handler)) + imd.balanceOf(address(box));
        assertEq(imd.balanceOf(box.BURN_ADDRESS()), handler.totalBurned());
        accounted += handler.totalBurned();
        for (uint256 i; i < 12; ++i) {
            accounted += imd.balanceOf(address(uint160(0x1000 + i)));
        }
        assertEq(accounted, handler.FUNDING());
        assertEq(imd.totalSupply(), handler.FUNDING());
    }

    function afterInvariant() public {
        handler.closeAll();
        invariantBalanceEqualsIndependentOpenPacketLiabilities();
        invariantAllIMDConservedAcrossCreatorEscrowBurnAndRecipients();
        assertEq(box.totalEscrow(), 0);
        assertEq(imd.balanceOf(address(box)), 0);
    }

    function testHandlerExercisesEveryTerminalPath() public {
        handler.createPacket(0, 1, false, 10 minutes);
        handler.grabPacket(1, 0);
        handler.createPacket(0, 1, true, 10 minutes);
        handler.grabPacket(2, 1);
        handler.revealPacket(2);
        handler.createPacket(0, 2, true, 10 minutes);
        handler.grabPacket(3, 2);
        handler.createPacket(0, 2, false, 10 minutes);
        handler.grabPacket(4, 3);
        handler.advanceTime(2 days);
        handler.blockRecipient(2); // the only grabber of packet 3 is refused by IMD
        handler.settlePacket(3);
        handler.refundPacket(4);
        assertGt(box.claimable(address(0x1002)), 0);
        handler.claimCredit(2); // still blocked: skipped
        assertEq(handler.claims(), 0);
        handler.blockRecipient(13);
        handler.claimCredit(2);
        assertEq(handler.creates(), 4);
        assertEq(handler.grabs(), 4);
        assertEq(handler.reveals(), 1);
        assertEq(handler.settlements(), 1);
        assertEq(handler.refunds(), 1);
        assertEq(handler.claims(), 1);
        afterInvariant();
    }
}
