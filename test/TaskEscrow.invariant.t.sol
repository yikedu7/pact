// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {TaskEscrow} from "../contracts/TaskEscrow.sol";
import {ITaskEscrow} from "../contracts/interfaces/ITaskEscrow.sol";
import {MockUSDC} from "../contracts/mocks/MockUSDC.sol";
import {ReputationRegistry} from "../contracts/registries/ReputationRegistry.sol";
import {BaseTest} from "./utils/BaseTest.sol";
import {Test} from "forge-std/Test.sol";

/// @dev Drives random, mostly-valid lifecycle transitions and tracks expected escrow balances.
contract EscrowHandler is Test {
    TaskEscrow internal escrow;
    MockUSDC internal usdc;
    address internal buyer;
    address internal seller;
    address internal verifier;
    uint256 internal agentId;

    uint256[] public orderIds;
    uint256 public ghostLocked;
    uint256 public ghostReleased;
    uint256 public ghostRefunded;
    uint256 public ghostFeedbackWrites;

    constructor(TaskEscrow escrow_, MockUSDC usdc_, address buyer_, address seller_, address verifier_, uint256 id) {
        escrow = escrow_;
        usdc = usdc_;
        buyer = buyer_;
        seller = seller_;
        verifier = verifier_;
        agentId = id;
    }

    function orderCount() external view returns (uint256) {
        return orderIds.length;
    }

    function open(uint256 amount, uint32 dueIn, uint32 window, bool fundIt) external {
        amount = bound(amount, 1, 10_000e6);
        dueIn = uint32(bound(dueIn, 1, 7 days));
        window = uint32(bound(window, 1, 2 days));
        usdc.mint(buyer, amount);

        vm.prank(buyer);
        uint256 id = escrow.createOrder(
            agentId,
            verifier,
            amount,
            keccak256(abi.encode(amount, dueIn)),
            "ipfs://spec",
            "fuzz",
            uint64(vm.getBlockTimestamp()) + dueIn,
            window
        );
        orderIds.push(id);
        vm.prank(seller);
        escrow.agree(id);
        if (fundIt) {
            vm.prank(buyer);
            escrow.fund(id);
            ghostLocked += amount;
        }
    }

    function deliver(uint256 seed) external {
        (uint256 id, ITaskEscrow.Order memory o) = _pick(seed);
        if (o.status != ITaskEscrow.Status.Funded) return;
        vm.prank(seller);
        escrow.submitDelivery(id, keccak256(abi.encode(id)), "ipfs://delivery");
    }

    function verify(uint256 seed) external {
        (uint256 id, ITaskEscrow.Order memory o) = _pick(seed);
        if (o.status != ITaskEscrow.Status.Delivered || vm.getBlockTimestamp() > o.deliveredAt + o.verifyWindow) {
            return;
        }
        vm.prank(verifier);
        escrow.verify(id, keccak256("ok"), "ipfs://report");
    }

    function release(uint256 seed, bool byPayee) external {
        (uint256 id, ITaskEscrow.Order memory o) = _pick(seed);
        if (o.status != ITaskEscrow.Status.Verified) return;
        vm.prank(byPayee ? seller : verifier);
        escrow.release(id);
        ghostLocked -= o.amount;
        ghostReleased += o.amount;
        ++ghostFeedbackWrites;
    }

    function fail(uint256 seed) external {
        (uint256 id, ITaskEscrow.Order memory o) = _pick(seed);
        if (o.status != ITaskEscrow.Status.Delivered || vm.getBlockTimestamp() > o.deliveredAt + o.verifyWindow) {
            return;
        }
        vm.prank(verifier);
        escrow.fail(id, keccak256("bad"), "ipfs://report");
        ghostLocked -= o.amount;
        ghostRefunded += o.amount;
        ++ghostFeedbackWrites;
    }

    function refund(uint256 seed) external {
        (uint256 id, ITaskEscrow.Order memory o) = _pick(seed);
        if (!escrow.isRefundable(id)) return;
        escrow.refundExpired(id);
        ghostLocked -= o.amount;
        ghostRefunded += o.amount;
        if (o.status == ITaskEscrow.Status.Funded) ++ghostFeedbackWrites;
    }

    function warp(uint32 secs) external {
        vm.warp(vm.getBlockTimestamp() + bound(secs, 1, 3 days));
    }

    function _pick(uint256 seed) internal view returns (uint256 id, ITaskEscrow.Order memory o) {
        if (orderIds.length == 0) return (0, o);
        id = orderIds[seed % orderIds.length];
        o = escrow.getOrder(id);
    }
}

contract TaskEscrowInvariantTest is BaseTest {
    EscrowHandler internal handler;
    uint256 internal initialSupply;

    function setUp() public override {
        super.setUp();
        handler = new EscrowHandler(escrow, usdc, buyer, sellerOwner, verifier, sellerAgentId);
        vm.prank(buyer);
        usdc.approve(address(escrow), type(uint256).max);
        initialSupply = usdc.totalSupply();
        targetContract(address(handler));
    }

    function invariant_escrowHoldsExactlyOpenOrders() public view {
        assertEq(usdc.balanceOf(address(escrow)), handler.ghostLocked());

        uint256 open;
        for (uint256 i; i < handler.orderCount(); ++i) {
            ITaskEscrow.Order memory o = escrow.getOrder(handler.orderIds(i));
            if (
                o.status == ITaskEscrow.Status.Funded || o.status == ITaskEscrow.Status.Delivered
                    || o.status == ITaskEscrow.Status.Verified
            ) open += o.amount;
            assertTrue(o.status != ITaskEscrow.Status.Disputed);
        }
        assertEq(open, handler.ghostLocked());
    }

    function invariant_tokensAreConserved() public view {
        assertEq(
            usdc.balanceOf(buyer) + usdc.balanceOf(sellerOwner) + usdc.balanceOf(address(escrow)), usdc.totalSupply()
        );
        assertEq(usdc.balanceOf(sellerOwner), handler.ghostReleased());
    }

    function invariant_everySellerOutcomeIsOnChain() public view {
        assertEq(
            ReputationRegistry(address(reputation)).getLastIndex(sellerAgentId, address(escrow)),
            handler.ghostFeedbackWrites()
        );
    }
}
