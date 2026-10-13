// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {TaskEscrow} from "../contracts/TaskEscrow.sol";
import {ITaskEscrow} from "../contracts/interfaces/ITaskEscrow.sol";
import {MockUSDC} from "../contracts/mocks/MockUSDC.sol";
import {BaseTest} from "./utils/BaseTest.sol";
import {Test} from "forge-std/Test.sol";

/// @dev Drives random, valid lifecycle transitions and tracks expected balances and feedback writes.
contract EscrowHandler is Test {
    TaskEscrow internal escrow;
    MockUSDC internal usdc;
    address internal buyer;
    address internal seller;
    address internal verifier;
    uint256 internal sellerAgentId;
    uint256 internal buyerAgentId;

    uint256[] public orderIds;
    uint256 public ghostLocked;
    uint256 public ghostReleased;
    uint256 public ghostExpertWrites;
    uint256 public ghostBuyerWrites;
    uint256 public ghostSettled;

    constructor(
        TaskEscrow escrow_,
        MockUSDC usdc_,
        address buyer_,
        address seller_,
        address verifier_,
        uint256 sellerAgentId_,
        uint256 buyerAgentId_
    ) {
        escrow = escrow_;
        usdc = usdc_;
        buyer = buyer_;
        seller = seller_;
        verifier = verifier_;
        sellerAgentId = sellerAgentId_;
        buyerAgentId = buyerAgentId_;
    }

    function orderCount() external view returns (uint256) {
        return orderIds.length;
    }

    function open(uint256 amount, uint32 dueIn, uint32 window, bool approveForMe) external {
        amount = bound(amount, 1, 10_000e6);
        dueIn = uint32(bound(dueIn, 1, 2 days));
        window = uint32(bound(window, 1, 2 days));
        usdc.mint(buyer, amount);
        bytes32 specHash = keccak256(abi.encode(amount, dueIn, orderIds.length));

        vm.prank(buyer);
        uint256 id = escrow.createOrder(
            ITaskEscrow.OrderParams({
                sellerAgentId: sellerAgentId,
                buyerAgentId: buyerAgentId,
                verifier: address(0),
                amount: amount,
                specHash: specHash,
                specURI: "ipfs://spec",
                taskType: "fuzz",
                deliverBy: uint64(vm.getBlockTimestamp()) + dueIn,
                reviewWindow: window,
                approvalMode: approveForMe ? ITaskEscrow.ApprovalMode.ApproveForMe : ITaskEscrow.ApprovalMode.User
            })
        );
        orderIds.push(id);
        vm.prank(seller);
        escrow.agree(id, specHash);
        vm.prank(buyer);
        escrow.fund(id);
        ghostLocked += amount;
    }

    function deliver(uint256 seed) external {
        (uint256 id, ITaskEscrow.Order memory o) = _pick(seed);
        if (o.status != ITaskEscrow.Status.Funded) return;
        vm.prank(seller);
        escrow.submitDelivery(id, keccak256(abi.encode(id)), "ipfs://delivery");
    }

    function pass(uint256 seed) external {
        (uint256 id, ITaskEscrow.Order memory o) = _pick(seed);
        if (!_verifiable(o)) return;
        vm.prank(verifier);
        escrow.release(id, keccak256("pass"), "ipfs://result");
        if (o.approvalMode == ITaskEscrow.ApprovalMode.ApproveForMe) _settledRelease(o);
    }

    function fail(uint256 seed) external {
        (uint256 id, ITaskEscrow.Order memory o) = _pick(seed);
        if (!_verifiable(o)) return;
        vm.prank(verifier);
        escrow.fail(id, keccak256("fail"), "ipfs://result");
        _settledRefund(o, true);
    }

    function approve(uint256 seed) external {
        (uint256 id, ITaskEscrow.Order memory o) = _pick(seed);
        if (o.status != ITaskEscrow.Status.Verified) return;
        vm.prank(buyer);
        escrow.approve(id);
        _settledRelease(o);
    }

    function releaseExpired(uint256 seed) external {
        (uint256 id, ITaskEscrow.Order memory o) = _pick(seed);
        if (!escrow.isReleasable(id)) return;
        escrow.releaseExpired(id);
        _settledRelease(o);
    }

    function refund(uint256 seed) external {
        (uint256 id, ITaskEscrow.Order memory o) = _pick(seed);
        if (!escrow.isRefundable(id)) return;
        escrow.refundExpired(id);
        _settledRefund(o, o.status == ITaskEscrow.Status.Funded);
    }

    function warp(uint32 secs) external {
        vm.warp(vm.getBlockTimestamp() + bound(secs, 1, 12 hours));
    }

    function _verifiable(ITaskEscrow.Order memory o) internal view returns (bool) {
        return o.status == ITaskEscrow.Status.Delivered && vm.getBlockTimestamp() <= o.deliveredAt + o.reviewWindow;
    }

    function _settledRelease(ITaskEscrow.Order memory o) internal {
        ghostLocked -= o.amount;
        ghostReleased += o.amount;
        ++ghostExpertWrites;
        ++ghostBuyerWrites;
        ++ghostSettled;
    }

    function _settledRefund(ITaskEscrow.Order memory o, bool expertAtFault) internal {
        ghostLocked -= o.amount;
        if (expertAtFault) ++ghostExpertWrites;
        ++ghostBuyerWrites;
        ++ghostSettled;
    }

    function _pick(uint256 seed) internal view returns (uint256 id, ITaskEscrow.Order memory o) {
        if (orderIds.length == 0) return (0, o);
        id = orderIds[seed % orderIds.length];
        o = escrow.getOrder(id);
    }
}

contract TaskEscrowInvariantTest is BaseTest {
    EscrowHandler internal handler;

    function setUp() public override {
        super.setUp();
        handler = new EscrowHandler(escrow, usdc, buyer, sellerOwner, verifier, sellerAgentId, buyerAgentId);
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
            if (o.status == ITaskEscrow.Status.Verified) assertTrue(o.passed, "only passes rest in Verified");
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

    function invariant_everySettlementIsOnChain() public view {
        assertEq(reputation.getLastIndex(sellerAgentId, address(escrow)), handler.ghostExpertWrites());
        assertEq(reputation.getLastIndex(buyerAgentId, address(escrow)), handler.ghostBuyerWrites());
        assertEq(handler.ghostBuyerWrites(), handler.ghostSettled());
    }
}
