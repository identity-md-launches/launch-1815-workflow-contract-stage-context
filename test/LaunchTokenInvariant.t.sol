// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {LaunchToken} from "src/LaunchToken.sol";

/// @dev The ledger is driven by requested operations, never by token.balanceOf/allowance.
contract LaunchTokenLedgerHandler is Test {
    LaunchToken public immutable token;
    uint256 public constant SUPPLY = 1e27;
    uint256 public constant ACTORS = 4;
    address[4] public actors;
    mapping(address => uint256) public balances;
    mapping(address => mapping(address => uint256)) public allowances;
    uint256 public transfers;
    uint256 public delegatedTransfers;
    uint256 public rejectedCalls;

    constructor() {
        token = new LaunchToken();
        for (uint256 i; i < ACTORS; ++i) {
            actors[i] = makeAddr(string.concat("token ledger actor ", vm.toString(i)));
        }
        assertTrue(token.transfer(actors[0], SUPPLY));
        balances[actors[0]] = SUPPLY;
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amountSeed) external {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        uint256 amount = bound(amountSeed, 0, balances[from]);
        vm.prank(from);
        assertTrue(token.transfer(to, amount));
        _move(from, to, amount);
        ++transfers;
    }

    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 amount, bool infinite) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        amount = infinite ? type(uint256).max : amount;
        vm.prank(owner);
        assertTrue(token.approve(spender, amount));
        allowances[owner][spender] = amount;
    }

    function transferFrom(
        uint256 ownerSeed,
        uint256 spenderSeed,
        uint256 recipientSeed,
        uint256 amountSeed,
        bool exceed
    ) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        address recipient = _actor(recipientSeed);
        uint256 allowed = allowances[owner][spender];
        if (exceed) {
            // A failed transfer must also roll back any allowance spent before balance validation.
            uint256 failedAmount;
            if (allowed == type(uint256).max) {
                failedAmount = balances[owner] + 1;
                vm.expectRevert(
                    abi.encodeWithSelector(
                        IERC20Errors.ERC20InsufficientBalance.selector, owner, balances[owner], failedAmount
                    )
                );
            } else {
                failedAmount = allowed + 1;
                vm.expectRevert(
                    abi.encodeWithSelector(
                        IERC20Errors.ERC20InsufficientAllowance.selector, spender, allowed, failedAmount
                    )
                );
            }
            vm.prank(spender);
            token.transferFrom(owner, recipient, failedAmount);
            ++rejectedCalls;
            return;
        }
        uint256 limit = balances[owner] < allowed ? balances[owner] : allowed;
        uint256 amount = bound(amountSeed, 0, limit);
        vm.prank(spender);
        assertTrue(token.transferFrom(owner, recipient, amount));
        if (allowed != type(uint256).max) allowances[owner][spender] -= amount;
        _move(owner, recipient, amount);
        ++delegatedTransfers;
    }

    function rejectOverspend(uint256 actorSeed) external {
        address owner = _actor(actorSeed);
        uint256 amount = balances[owner] + 1;
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, owner, balances[owner], amount)
        );
        vm.prank(owner);
        token.transfer(owner, amount);
        ++rejectedCalls;
    }

    function rejectZeroAddress(uint256 actorSeed, uint256 amount, bool approval) external {
        address owner = _actor(actorSeed);
        if (approval) {
            vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
            vm.prank(owner);
            token.approve(address(0), amount);
        } else {
            vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
            vm.prank(owner);
            token.transfer(address(0), amount);
        }
        ++rejectedCalls;
    }

    function _actor(uint256 seed) private view returns (address) {
        return actors[bound(seed, 0, ACTORS - 1)];
    }

    function _move(address from, address to, uint256 amount) private {
        balances[from] -= amount;
        balances[to] += amount;
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 96
/// forge-config: default.invariant.fail-on-revert = true
contract LaunchTokenInvariantTest is StdInvariant, Test {
    LaunchTokenLedgerHandler private handler;
    LaunchToken private token;

    function setUp() public {
        handler = new LaunchTokenLedgerHandler();
        token = handler.token();
        bytes4[] memory selectors = new bytes4[](5);
        selectors[0] = handler.transfer.selector;
        selectors[1] = handler.approve.selector;
        selectors[2] = handler.transferFrom.selector;
        selectors[3] = handler.rejectOverspend.selector;
        selectors[4] = handler.rejectZeroAddress.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// @dev Fixed supply and plain ERC-20 transfers require conservation for every sequence.
    function invariantSupplyBalancesAndAllowancesMatchIndependentLedger() public view {
        uint256 sum;
        for (uint256 i; i < handler.ACTORS(); ++i) {
            address actor = handler.actors(i);
            assertEq(token.balanceOf(actor), handler.balances(actor), "actor balance");
            sum += token.balanceOf(actor);
            for (uint256 j; j < handler.ACTORS(); ++j) {
                address spender = handler.actors(j);
                assertEq(token.allowance(actor, spender), handler.allowances(actor, spender), "allowance");
            }
        }
        assertEq(sum, handler.SUPPLY(), "all supply remains with modeled holders");
        assertEq(token.totalSupply(), handler.SUPPLY(), "fixed supply");
        assertEq(token.balanceOf(address(handler)), 0);
        assertEq(token.balanceOf(address(0)), 0);
    }

    function testHandlerFullSupplyZeroSelfTransferRevocationAndInfiniteAllowance() public {
        uint256 supply = handler.SUPPLY();
        handler.transfer(0, 1, supply);
        handler.transfer(1, 1, supply);
        handler.transfer(1, 2, 0);
        handler.approve(1, 2, supply, false);
        handler.transferFrom(1, 2, 1, 1, false); // Self-transfer still spends finite allowance.
        assertEq(token.balanceOf(handler.actors(1)), supply);
        assertEq(token.allowance(handler.actors(1), handler.actors(2)), supply - 1);
        handler.approve(1, 2, 0, false);
        handler.transferFrom(1, 2, 3, 1, true);
        handler.approve(1, 2, 0, true);
        handler.transferFrom(1, 2, 3, supply, false);
        handler.transferFrom(1, 2, 3, 0, true);
        handler.rejectZeroAddress(3, 0, false);
        handler.rejectZeroAddress(3, type(uint256).max, true);
        invariantSupplyBalancesAndAllowancesMatchIndependentLedger();
        assertEq(handler.transfers(), 3);
        assertEq(handler.delegatedTransfers(), 2);
        assertEq(handler.rejectedCalls(), 4);
    }
}
