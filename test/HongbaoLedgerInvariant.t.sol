// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {HongbaoBox} from "src/HongbaoBox.sol";
import {MockIMD} from "./helpers/MockIMD.sol";

/// @dev Multiple creators also act as recipients and relayers. No minting occurs after setup.
/// Expected liabilities come from inputs and completed operations, not remaining()/totalEscrow().
contract HongbaoLedgerHandler is Test {
    uint256 public constant ACTORS = 6;
    uint256 public constant FUNDING = 100_000 ether;
    uint256 private constant MIN = 1e16;
    uint256 private immutable signingKey;
    address private immutable signer;
    HongbaoBox public immutable box;
    MockIMD public immutable imd;
    address[6] public actors;
    mapping(address => uint256) public expectedBalances;
    uint256 public packetCount;
    uint256 public expectedBurn;
    uint256 public surplus;
    uint256 public successfulGrabs;
    uint256 public reveals;
    uint256 public settlements;
    uint256 public refunds;
    uint256 public rejectedGrabs;
    uint256 public recoveries;

    struct Model {
        address creator;
        uint256 net;
        uint256 slots;
        bool lucky;
        uint256 expiry;
        bytes32 secret;
        uint256 owed;
        uint256 filled;
        HongbaoBox.State state;
        address winner;
        address[] recipients;
        uint256[] shares;
        mapping(address => bool) claimed;
    }

    mapping(uint256 => Model) private models;

    constructor(HongbaoBox target, MockIMD token) {
        box = target;
        imd = token;
        (address keyAddress, uint256 key) = makeAddrAndKey("multi actor packet signer");
        signer = keyAddress;
        signingKey = key;
        for (uint256 i; i < ACTORS; ++i) {
            address actor = makeAddr(string.concat("packet ledger actor ", vm.toString(i)));
            actors[i] = actor;
            token.mint(actor, FUNDING);
            expectedBalances[actor] = FUNDING;
            vm.prank(actor);
            token.approve(address(target), type(uint256).max);
        }
    }

    function createPacket(uint256 creatorSeed, uint256 slotsSeed, uint256 extraSeed, bool lucky, uint256 durationSeed)
        external
    {
        if (packetCount == 24) return;
        uint256 id = packetCount + 1;
        Model storage m = models[id];
        m.creator = _actor(creatorSeed);
        m.slots = bound(slotsSeed, 1, ACTORS);
        m.net = m.slots * MIN + bound(extraSeed, 0, 100 ether);
        // Smallest gross amount which leaves exactly this net after floor(gross / 200).
        uint256 gross = m.net + (m.net - 1) / 199;
        uint256 duration = bound(durationSeed, 10 minutes, 7 days);
        m.expiry = vm.getBlockTimestamp() + duration;
        m.lucky = lucky;
        m.secret = keccak256(abi.encode(id, m.creator, extraSeed));
        m.owed = m.net;
        vm.prank(m.creator);
        uint256 actualId = box.create(
            gross,
            m.slots,
            lucky,
            signer,
            bytes32(id),
            duration,
            lucky ? keccak256(abi.encodePacked(m.secret)) : bytes32(0)
        );
        assertEq(actualId, id, "packet ids remain sequential");
        expectedBalances[m.creator] -= gross;
        expectedBurn += gross - m.net;
        packetCount = id;
    }

    function grabPacket(uint256 packetSeed, uint256 recipientSeed, uint256 relayerSeed) external {
        if (packetCount == 0) return;
        uint256 id = bound(packetSeed, 1, packetCount);
        Model storage m = models[id];
        address recipient = _actor(recipientSeed);
        if (
            m.state != HongbaoBox.State.Open || vm.getBlockTimestamp() >= m.expiry || m.recipients.length == m.slots
                || m.claimed[recipient]
        ) return;
        bytes memory signature = _signature(id, recipient, signingKey);
        vm.prank(_actor(relayerSeed));
        box.grab(id, recipient, signature);
        m.claimed[recipient] = true;
        m.recipients.push(recipient);
        uint256 share;
        if (m.recipients.length == m.slots) m.filled = vm.getBlockTimestamp();
        if (!m.lucky) {
            share = m.recipients.length == m.slots ? m.owed : m.net / m.slots;
            m.owed -= share;
            expectedBalances[recipient] += share;
            if (m.recipients.length == m.slots) m.state = HongbaoBox.State.Completed;
        }
        m.shares.push(share);
        ++successfulGrabs;
    }

    function finishPacket(uint256 packetSeed, bool useReveal, uint256 relayerSeed) public {
        if (packetCount == 0) return;
        uint256 id = bound(packetSeed, 1, packetCount);
        Model storage m = models[id];
        if (m.state != HongbaoBox.State.Open) return;
        if (!m.lucky) {
            if (vm.getBlockTimestamp() < m.expiry) return;
            vm.prank(_actor(relayerSeed));
            box.refund(id);
            expectedBalances[m.creator] += m.owed;
            m.owed = 0;
            m.state = HongbaoBox.State.Refunded;
            ++refunds;
            return;
        }
        uint256 count = m.recipients.length;
        uint256 payout = m.net * count / m.slots;
        if (useReveal) {
            if (count < m.slots && vm.getBlockTimestamp() < m.expiry) return;
            vm.prank(m.creator);
            box.reveal(id, m.secret);
            // Check the random output's constraints, not a second copy of the RNG implementation.
            (, uint256[] memory shares) = box.grabbers(id);
            assertEq(shares.length, count);
            uint256 rest = payout;
            uint256 largest;
            for (uint256 i; i < count; ++i) {
                uint256 share = shares[i];
                assertGe(share, MIN, "minimum lucky share");
                if (i + 1 < count) {
                    assertLe(share, 2 * rest / (count - i), "double average ceiling");
                    assertLe(share, rest - MIN * (count - i - 1), "reserve remaining minima");
                }
                rest -= share;
                m.shares[i] = share;
                expectedBalances[m.recipients[i]] += share;
                if (share > largest) {
                    largest = share;
                    m.winner = m.recipients[i];
                }
            }
            assertEq(rest, 0, "lucky payout conservation");
            m.state = HongbaoBox.State.Revealed;
            ++reveals;
        } else {
            uint256 availableAt = (count == m.slots ? m.filled : m.expiry) + 24 hours;
            if (vm.getBlockTimestamp() < availableAt) return;
            vm.prank(_actor(relayerSeed));
            box.settle(id);
            uint256 paid;
            for (uint256 i; i < count; ++i) {
                uint256 share = i + 1 == count ? payout - paid : payout / count;
                m.shares[i] = share;
                paid += share;
                expectedBalances[m.recipients[i]] += share;
            }
            m.state = HongbaoBox.State.Settled;
            ++settlements;
        }
        expectedBalances[m.creator] += m.net - payout;
        m.owed = 0;
    }

    function donate(uint256 donorSeed, uint256 amountSeed) external {
        address donor = _actor(donorSeed);
        uint256 amount = bound(amountSeed, 0, 10 ether);
        vm.prank(donor);
        assertTrue(imd.transfer(address(box), amount));
        expectedBalances[donor] -= amount;
        surplus += amount;
    }

    function recover(uint256 actorSeed) public {
        address recipient = _actor(actorSeed);
        if (surplus == 0) {
            vm.expectRevert(HongbaoBox.NoSurplus.selector);
            vm.prank(recipient);
            box.recoverSurplus();
            return;
        }
        vm.prank(recipient);
        uint256 recovered = box.recoverSurplus();
        assertEq(recovered, surplus, "recovery excludes all escrow");
        expectedBalances[recipient] += surplus;
        surplus = 0;
        ++recoveries;
    }

    /// @dev Expected reverts are exercised within the random sequences and must change no ledger entry.
    function rejectGrab(uint256 packetSeed, uint256 recipientSeed) external {
        if (packetCount == 0) return;
        uint256 id = bound(packetSeed, 1, packetCount);
        Model storage m = models[id];
        address recipient = _actor(recipientSeed);
        bytes memory signature = _signature(id, recipient, signingKey + 1);
        bytes4 reason;
        if (m.state != HongbaoBox.State.Open) reason = HongbaoBox.PacketClosed.selector;
        else if (vm.getBlockTimestamp() >= m.expiry) reason = HongbaoBox.PacketExpired.selector;
        else if (m.recipients.length == m.slots) reason = HongbaoBox.PacketFull.selector;
        else if (m.claimed[recipient]) reason = HongbaoBox.AlreadyGrabbed.selector;
        else reason = HongbaoBox.InvalidSignature.selector;
        vm.expectRevert(reason);
        box.grab(id, recipient, signature);
        ++rejectedGrabs;
    }

    function advanceTime(uint256 delta) external {
        vm.warp(vm.getBlockTimestamp() + bound(delta, 0, 2 days));
    }

    function rejectClosedMutator(uint256 packetSeed, uint256 operationSeed) external {
        if (packetCount == 0) return;
        uint256 id = bound(packetSeed, 1, packetCount);
        if (models[id].state == HongbaoBox.State.Open) return;
        uint256 operation = bound(operationSeed, 0, 2);
        vm.expectRevert(HongbaoBox.PacketClosed.selector);
        if (operation == 0) box.reveal(id, models[id].secret);
        else if (operation == 1) box.settle(id);
        else box.refund(id);
    }

    /// @dev Lost secrets must not strand any packet, including ones with no grabbers.
    function closeAll() external {
        vm.warp(vm.getBlockTimestamp() + 8 days);
        for (uint256 id = 1; id <= packetCount; ++id) {
            finishPacket(id, false, id);
        }
        recover(0);
    }

    function checkLedger() external view {
        uint256 sum;
        for (uint256 i; i < ACTORS; ++i) {
            address actor = actors[i];
            assertEq(imd.balanceOf(actor), expectedBalances[actor], "individual actor ledger");
            sum += imd.balanceOf(actor);
        }
        assertEq(imd.balanceOf(box.BURN_ADDRESS()), expectedBurn, "only creation burns IMD");
        sum += imd.balanceOf(address(box)) + expectedBurn;
        assertEq(sum, ACTORS * FUNDING, "IMD conservation");
        assertEq(imd.totalSupply(), ACTORS * FUNDING, "no test-time balance top-ups");
    }

    function checkPackets() external view {
        uint256 owed;
        assertEq(box.nextPacketId(), packetCount + 1);
        for (uint256 id = 1; id <= packetCount; ++id) {
            Model storage m = models[id];
            HongbaoBox.Packet memory p = box.packet(id);
            assertEq(p.creator, m.creator);
            assertEq(p.amount, m.net);
            assertEq(p.slots, m.slots);
            assertEq(p.grabbed, m.recipients.length);
            assertEq(p.lucky, m.lucky);
            assertEq(p.expiry, m.expiry);
            assertEq(p.keyAddress, signer);
            assertEq(p.salt, bytes32(id));
            assertEq(uint256(p.state), uint256(m.state), "terminal packets cannot reopen");
            assertEq(box.remaining(id), m.owed);
            assertEq(box.filledAt(id), m.filled);
            assertEq(box.bestLuck(id), m.winner);
            assertEq(box.revealCommitments(id), m.lucky ? keccak256(abi.encodePacked(m.secret)) : bytes32(0));
            (address[] memory recipients, uint256[] memory shares) = box.grabbers(id);
            assertEq(recipients.length, m.recipients.length);
            assertEq(shares.length, m.shares.length);
            for (uint256 i; i < recipients.length; ++i) {
                assertEq(recipients[i], m.recipients[i], "grab order");
                assertEq(shares[i], m.shares[i], "recorded payout");
            }
            for (uint256 i; i < ACTORS; ++i) {
                assertEq(box.hasGrabbed(id, actors[i]), m.claimed[actors[i]], "recipient replay flag");
            }
            owed += m.owed;
        }
        assertEq(box.totalEscrow(), owed, "independently modeled liabilities");
        assertEq(imd.balanceOf(address(box)), owed + surplus, "escrow plus unsolicited transfers");
    }

    function _signature(uint256 id, address recipient, uint256 key) private view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, box.grabDigest(id, recipient));
        return abi.encodePacked(r, s, v);
    }

    function _actor(uint256 seed) private view returns (address) {
        return actors[bound(seed, 0, ACTORS - 1)];
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 96
/// forge-config: default.invariant.fail-on-revert = true
contract HongbaoLedgerInvariantTest is StdInvariant, Test {
    HongbaoLedgerHandler private handler;
    HongbaoBox private box;

    function setUp() public {
        vm.chainId(4663);
        vm.warp(1_000_000);
        MockIMD imd = new MockIMD();
        box = new HongbaoBox(address(imd));
        handler = new HongbaoLedgerHandler(box, imd);
        bytes4[] memory selectors = new bytes4[](8);
        selectors[0] = handler.createPacket.selector;
        selectors[1] = handler.grabPacket.selector;
        selectors[2] = handler.finishPacket.selector;
        selectors[3] = handler.donate.selector;
        selectors[4] = handler.recover.selector;
        selectors[5] = handler.rejectGrab.selector;
        selectors[6] = handler.advanceTime.selector;
        selectors[7] = handler.rejectClosedMutator.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariantIndividualBalancesAndPacketObligationsMatchModel() public view {
        handler.checkLedger();
        handler.checkPackets();
    }

    function afterInvariant() public {
        handler.closeAll();
        handler.checkLedger();
        handler.checkPackets();
        assertEq(box.totalEscrow(), 0, "all obligations can be discharged without secrets");
    }

    function testModelExercisesEveryTerminalPathAndOverlappingRoles() public {
        handler.createPacket(0, 1, 1, false, 10 minutes);
        handler.grabPacket(1, 0, 1); // Creator is also recipient, with a different relayer.
        handler.rejectGrab(1, 0); // Completed.
        handler.createPacket(1, 2, 3, true, 10 minutes);
        handler.grabPacket(2, 1, 0);
        handler.rejectGrab(2, 1); // Duplicate.
        handler.rejectGrab(2, 2); // Wrong key.
        handler.grabPacket(2, 2, 0);
        handler.rejectGrab(2, 3); // Full lucky packet, still open until reveal.
        handler.finishPacket(2, true, 3);
        handler.createPacket(2, 3, 1, true, 10 minutes);
        handler.grabPacket(3, 2, 4);
        handler.createPacket(3, 3, 1, false, 10 minutes);
        handler.grabPacket(4, 4, 3);
        handler.donate(0, 1 ether);
        handler.recover(5);
        handler.recover(0); // No surplus: may not take packet funds.
        handler.advanceTime(2 days);
        handler.rejectGrab(3, 5); // Expired.
        handler.finishPacket(3, false, 5);
        handler.finishPacket(4, false, 0);
        for (uint256 id = 1; id <= 4; ++id) {
            for (uint256 operation; operation < 3; ++operation) {
                handler.rejectClosedMutator(id, operation);
            }
        }
        invariantIndividualBalancesAndPacketObligationsMatchModel();
        assertEq(handler.successfulGrabs(), 5);
        assertEq(handler.reveals(), 1);
        assertEq(handler.settlements(), 1);
        assertEq(handler.refunds(), 1);
        assertEq(handler.rejectedGrabs(), 5);
        assertEq(handler.recoveries(), 1);
        afterInvariant();
    }
}
