// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {TaskEscrow} from "../contracts/TaskEscrow.sol";
import {IIdentityRegistry} from "../contracts/interfaces/IIdentityRegistry.sol";
import {IReputationRegistry} from "../contracts/interfaces/IReputationRegistry.sol";
import {ITaskEscrow} from "../contracts/interfaces/ITaskEscrow.sol";
import {FulfillmentFeedback} from "../contracts/libraries/FulfillmentFeedback.sol";
import {IdentityRegistry} from "../contracts/registries/IdentityRegistry.sol";
import {ReputationRegistry} from "../contracts/registries/ReputationRegistry.sol";
import {FeeOnTransferToken, ReentrantToken} from "./mocks/TestTokens.sol";
import {BaseTest} from "./utils/BaseTest.sol";
import {IERC20Errors, IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Vm} from "forge-std/Vm.sol";

contract TaskEscrowTest is BaseTest {
    using FulfillmentFeedback for string;

    // =====================================================================
    // Constructor
    // =====================================================================

    function test_constructor_wiresDependencies() public view {
        assertEq(address(escrow.paymentToken()), address(usdc));
        assertEq(address(escrow.identityRegistry()), address(identity));
        assertEq(address(escrow.reputationRegistry()), address(reputation));
        assertEq(escrow.defaultVerifier(), verifier);
        assertEq(escrow.nextOrderId(), 1);
    }

    function test_constructor_revertsOnZeroAddress() public {
        vm.expectRevert(ITaskEscrow.ZeroAddress.selector);
        new TaskEscrow(IERC20(address(0)), identity, reputation, verifier);
        vm.expectRevert(ITaskEscrow.ZeroAddress.selector);
        new TaskEscrow(IERC20(address(usdc)), identity, reputation, address(0));
    }

    function test_constructor_revertsOnRegistryMismatch() public {
        IdentityRegistry other = new IdentityRegistry();
        vm.expectRevert(abi.encodeWithSelector(TaskEscrow.RegistryMismatch.selector, address(other), address(identity)));
        new TaskEscrow(IERC20(address(usdc)), IIdentityRegistry(address(other)), reputation, verifier);
    }

    // =====================================================================
    // Happy path (approval_mode = user):
    // Created -> Agreed -> Funded -> Delivered -> Verified(pass) -> Released
    // =====================================================================

    function test_happyPath_userApproval() public {
        ITaskEscrow.OrderParams memory p = _params();

        vm.expectEmit(address(escrow));
        emit ITaskEscrow.OrderCreated(
            1,
            buyer,
            sellerAgentId,
            buyerAgentId,
            sellerOwner,
            verifier,
            PRICE,
            SPEC_HASH,
            SPEC_URI,
            TASK_TYPE,
            deliverBy,
            REVIEW_WINDOW,
            ITaskEscrow.ApprovalMode.User
        );
        uint256 orderId = _create(p);
        assertEq(uint8(_status(orderId)), uint8(ITaskEscrow.Status.Created));

        vm.expectEmit(address(escrow));
        emit ITaskEscrow.OrderAgreed(orderId, sellerOwner, SPEC_HASH);
        vm.prank(sellerOwner);
        escrow.agree(orderId, SPEC_HASH);
        assertEq(uint8(_status(orderId)), uint8(ITaskEscrow.Status.Agreed));

        vm.expectEmit(address(escrow));
        emit ITaskEscrow.OrderFunded(orderId, buyer, PRICE);
        vm.prank(buyer);
        escrow.fund(orderId);
        assertEq(uint8(_status(orderId)), uint8(ITaskEscrow.Status.Funded));
        assertEq(usdc.balanceOf(address(escrow)), PRICE);
        assertEq(usdc.balanceOf(buyer), BUYER_BALANCE - PRICE);

        vm.warp(vm.getBlockTimestamp() + 2 hours);
        vm.expectEmit(address(escrow));
        emit ITaskEscrow.OrderDelivered(orderId, sellerOwner, DELIVERY_HASH, DELIVERY_URI, true);
        vm.prank(sellerOwner);
        escrow.submitDelivery(orderId, DELIVERY_HASH, DELIVERY_URI);
        assertEq(uint8(_status(orderId)), uint8(ITaskEscrow.Status.Delivered));
        assertEq(escrow.reviewDeadline(orderId), vm.getBlockTimestamp() + REVIEW_WINDOW);

        vm.warp(vm.getBlockTimestamp() + 10 minutes);
        vm.expectEmit(address(escrow));
        emit ITaskEscrow.OrderVerified(orderId, verifier, true, RESULT_HASH, RESULT_URI);
        vm.prank(verifier);
        escrow.release(orderId, RESULT_HASH, RESULT_URI);
        assertEq(uint8(_status(orderId)), uint8(ITaskEscrow.Status.Verified));
        assertTrue(escrow.getOrder(orderId).passed);
        assertEq(usdc.balanceOf(address(escrow)), PRICE, "user mode waits for approval");

        vm.warp(vm.getBlockTimestamp() + 5 minutes);
        string memory expertJson = escrow.previewFeedback(orderId, ITaskEscrow.Role.Expert, true, true, true);
        string memory buyerJson = escrow.previewFeedback(orderId, ITaskEscrow.Role.Buyer, true, true, true);
        vm.expectEmit(address(reputation));
        emit IReputationRegistry.NewFeedback(
            sellerAgentId,
            address(escrow),
            1,
            100,
            0,
            "expert",
            "expert",
            TASK_TYPE,
            "",
            expertJson.toDataURI(),
            keccak256(bytes(expertJson))
        );
        vm.expectEmit(address(escrow));
        emit ITaskEscrow.FulfillmentRecorded(
            orderId, sellerAgentId, ITaskEscrow.Role.Expert, 1, true, true, keccak256(bytes(expertJson))
        );
        vm.expectEmit(address(escrow));
        emit ITaskEscrow.FulfillmentRecorded(
            orderId, buyerAgentId, ITaskEscrow.Role.Buyer, 1, true, true, keccak256(bytes(buyerJson))
        );
        vm.expectEmit(address(escrow));
        emit ITaskEscrow.OrderReleased(orderId, sellerOwner, PRICE, buyer);
        vm.prank(buyer);
        escrow.approve(orderId);

        ITaskEscrow.Order memory o = escrow.getOrder(orderId);
        assertEq(uint8(o.status), uint8(ITaskEscrow.Status.Released));
        assertEq(o.buyer, buyer);
        assertEq(o.payee, sellerOwner);
        assertEq(o.verifier, verifier);
        assertEq(o.amount, PRICE);
        assertEq(o.specHash, SPEC_HASH);
        assertEq(o.deliveryHash, DELIVERY_HASH);
        assertEq(o.deliveryURI, DELIVERY_URI);
        assertEq(o.resultHash, RESULT_HASH);
        assertEq(o.taskType, TASK_TYPE);
        assertEq(o.sellerFeedbackIndex, 1);
        assertEq(o.buyerFeedbackIndex, 1);

        assertEq(usdc.balanceOf(address(escrow)), 0);
        assertEq(usdc.balanceOf(sellerOwner), PRICE);
        assertEq(usdc.balanceOf(buyer), BUYER_BALANCE - PRICE);

        (int128 value, string memory tag1, string memory tag2) = _feedback(sellerAgentId, 1);
        assertEq(value, 100);
        assertEq(tag1, "expert");
        assertEq(tag2, TASK_TYPE);
        (value, tag1, tag2) = _feedback(buyerAgentId, 1);
        assertEq(value, 100);
        assertEq(tag1, "buyer");
        assertEq(tag2, TASK_TYPE);
    }

    function test_happyPath_approveForMeReleasesOnVerifierPass() public {
        ITaskEscrow.OrderParams memory p = _params();
        p.approvalMode = ITaskEscrow.ApprovalMode.ApproveForMe;
        uint256 orderId = _delivered(p);

        vm.expectEmit(address(escrow));
        emit ITaskEscrow.OrderVerified(orderId, verifier, true, RESULT_HASH, RESULT_URI);
        vm.expectEmit(address(escrow));
        emit ITaskEscrow.OrderReleased(orderId, sellerOwner, PRICE, verifier);
        vm.prank(verifier);
        escrow.release(orderId, RESULT_HASH, RESULT_URI);

        assertEq(uint8(_status(orderId)), uint8(ITaskEscrow.Status.Released));
        assertEq(usdc.balanceOf(sellerOwner), PRICE);
        assertEq(reputation.getLastIndex(sellerAgentId, address(escrow)), 1);
        assertEq(reputation.getLastIndex(buyerAgentId, address(escrow)), 1);
    }

    function test_feedbackFile_containsRequiredProductFields() public {
        uint256 orderId = _passed();
        string memory json = escrow.previewFeedback(orderId, ITaskEscrow.Role.Expert, true, true, true);

        assertEq(vm.parseJsonString(json, ".task_type"), TASK_TYPE);
        assertEq(vm.parseJsonString(json, ".amount"), vm.toString(PRICE));
        assertTrue(vm.parseJsonBool(json, ".passed"));
        assertTrue(vm.parseJsonBool(json, ".on_time"));

        assertEq(vm.parseJsonString(json, ".role"), "expert");
        assertEq(vm.parseJsonString(json, ".outcome"), "released");
        assertEq(vm.parseJsonString(json, ".token"), vm.toString(address(usdc)));
        assertEq(vm.parseJsonString(json, ".orderId"), vm.toString(orderId));
        assertEq(vm.parseJsonBytes32(json, ".specHash"), SPEC_HASH);
        assertEq(vm.parseJsonBytes32(json, ".deliveryHash"), DELIVERY_HASH);
        assertEq(vm.parseJsonBytes32(json, ".resultHash"), RESULT_HASH);

        // ERC-8004 mandatory feedback-file fields.
        assertEq(
            vm.parseJsonString(json, ".agentRegistry"),
            string.concat("eip155:", vm.toString(block.chainid), ":", vm.toString(address(identity)))
        );
        assertEq(vm.parseJsonUint(json, ".agentId"), sellerAgentId);
        assertEq(
            vm.parseJsonString(json, ".clientAddress"),
            string.concat("eip155:", vm.toString(block.chainid), ":", vm.toString(address(escrow)))
        );
        assertEq(vm.parseJsonString(json, ".createdAt"), "2023-11-14T22:13:20Z");
        assertEq(vm.parseJsonInt(json, ".value"), 100);
        assertEq(vm.parseJsonUint(json, ".valueDecimals"), 0);
        assertEq(vm.parseJsonString(json, ".tag1"), "expert");
        assertEq(vm.parseJsonString(json, ".tag2"), TASK_TYPE);

        string memory buyerJson = escrow.previewFeedback(orderId, ITaskEscrow.Role.Buyer, true, false, false);
        assertEq(vm.parseJsonUint(buyerJson, ".agentId"), buyerAgentId);
        assertEq(vm.parseJsonString(buyerJson, ".role"), "buyer");
        assertEq(vm.parseJsonString(buyerJson, ".outcome"), "refunded");
        assertFalse(vm.parseJsonBool(buyerJson, ".on_time"));
    }

    function test_releaseExpired_paysExpertWhenBuyerSilent() public {
        uint256 orderId = _passed();
        uint64 deadline = escrow.reviewDeadline(orderId);
        assertFalse(escrow.isReleasable(orderId));

        vm.warp(deadline);
        vm.expectRevert(abi.encodeWithSelector(ITaskEscrow.ReviewWindowOpen.selector, orderId, deadline));
        escrow.releaseExpired(orderId);

        vm.warp(deadline + 1);
        assertTrue(escrow.isReleasable(orderId));
        vm.expectEmit(address(escrow));
        emit ITaskEscrow.OrderReleased(orderId, sellerOwner, PRICE, stranger);
        vm.prank(stranger);
        escrow.releaseExpired(orderId);

        assertEq(usdc.balanceOf(sellerOwner), PRICE);
        (int128 value,,) = _feedback(buyerAgentId, 1);
        assertEq(value, 100, "buyer still paid");
        assertFalse(
            vm.parseJsonBool(escrow.previewFeedback(orderId, ITaskEscrow.Role.Buyer, true, false, true), ".on_time")
        );
    }

    function test_approve_afterWindowIsRecordedLate() public {
        uint256 orderId = _passed();
        vm.warp(escrow.reviewDeadline(orderId) + 1);
        string memory lateJson = escrow.previewFeedback(orderId, ITaskEscrow.Role.Buyer, true, false, true);

        vm.expectEmit(address(escrow));
        emit ITaskEscrow.FulfillmentRecorded(
            orderId, buyerAgentId, ITaskEscrow.Role.Buyer, 1, true, false, keccak256(bytes(lateJson))
        );
        vm.prank(buyer);
        escrow.approve(orderId);
        assertEq(uint8(_status(orderId)), uint8(ITaskEscrow.Status.Released));
    }

    function test_lateDelivery_isAcceptedAndRecordedLate() public {
        uint256 orderId = _funded();
        vm.warp(deliverBy + 1);

        vm.expectEmit(address(escrow));
        emit ITaskEscrow.OrderDelivered(orderId, sellerOwner, DELIVERY_HASH, DELIVERY_URI, false);
        vm.prank(sellerOwner);
        escrow.submitDelivery(orderId, DELIVERY_HASH, DELIVERY_URI);

        vm.prank(verifier);
        escrow.release(orderId, RESULT_HASH, RESULT_URI);
        string memory json = escrow.previewFeedback(orderId, ITaskEscrow.Role.Expert, true, false, true);
        vm.expectEmit(address(escrow));
        emit ITaskEscrow.FulfillmentRecorded(
            orderId, sellerAgentId, ITaskEscrow.Role.Expert, 1, true, false, keccak256(bytes(json))
        );
        vm.prank(buyer);
        escrow.approve(orderId);
        assertEq(usdc.balanceOf(sellerOwner), PRICE);
    }

    function test_deliveryExactlyAtDeadline_isOnTime() public {
        uint256 orderId = _funded();
        vm.warp(deliverBy);
        vm.expectEmit(address(escrow));
        emit ITaskEscrow.OrderDelivered(orderId, sellerOwner, DELIVERY_HASH, DELIVERY_URI, true);
        vm.prank(sellerOwner);
        escrow.submitDelivery(orderId, DELIVERY_HASH, DELIVERY_URI);
    }

    function test_verifiedPass_isNeverRefundable() public {
        uint256 orderId = _passed();
        vm.warp(vm.getBlockTimestamp() + 365 days);
        assertFalse(escrow.isRefundable(orderId));
        vm.expectRevert(abi.encodeWithSelector(ITaskEscrow.NotRefundable.selector, orderId));
        escrow.refundExpired(orderId);

        escrow.releaseExpired(orderId);
        assertEq(usdc.balanceOf(sellerOwner), PRICE);
    }

    function test_unregisteredBuyer_onlyExpertFeedback() public {
        ITaskEscrow.OrderParams memory p = _params();
        p.buyerAgentId = 0;
        p.approvalMode = ITaskEscrow.ApprovalMode.ApproveForMe;
        uint256 orderId = _delivered(p);
        vm.prank(verifier);
        escrow.release(orderId, RESULT_HASH, RESULT_URI);

        assertEq(reputation.getLastIndex(sellerAgentId, address(escrow)), 1);
        assertEq(escrow.getOrder(orderId).buyerFeedbackIndex, 0);
        assertEq(reputation.getClients(buyerAgentId).length, 0);
    }

    // =====================================================================
    // Unauthorized release / fail / approve
    // =====================================================================

    function test_release_revertsForUnauthorizedCallers() public {
        uint256 orderId = _delivered();
        address[3] memory callers = [buyer, sellerOwner, stranger];
        for (uint256 i; i < callers.length; ++i) {
            vm.prank(callers[i]);
            vm.expectRevert(abi.encodeWithSelector(ITaskEscrow.NotVerifier.selector, orderId, callers[i]));
            escrow.release(orderId, RESULT_HASH, RESULT_URI);
        }
        assertEq(uint8(_status(orderId)), uint8(ITaskEscrow.Status.Delivered));
        assertEq(usdc.balanceOf(address(escrow)), PRICE);
    }

    function testFuzz_release_onlyVerifier(address caller) public {
        vm.assume(caller != verifier);
        uint256 orderId = _delivered();
        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(ITaskEscrow.NotVerifier.selector, orderId, caller));
        escrow.release(orderId, RESULT_HASH, RESULT_URI);
    }

    function testFuzz_fail_onlyVerifier(address caller) public {
        vm.assume(caller != verifier);
        uint256 orderId = _delivered();
        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(ITaskEscrow.NotVerifier.selector, orderId, caller));
        escrow.fail(orderId, RESULT_HASH, RESULT_URI);
    }

    function testFuzz_approve_onlyBuyer(address caller) public {
        vm.assume(caller != buyer);
        uint256 orderId = _passed();
        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(ITaskEscrow.NotBuyer.selector, orderId, caller));
        escrow.approve(orderId);
    }

    function test_customVerifier_replacesDefault() public {
        address customVerifier = makeAddr("customVerifier");
        ITaskEscrow.OrderParams memory p = _params();
        p.verifier = customVerifier;
        uint256 orderId = _delivered(p);
        assertEq(escrow.getOrder(orderId).verifier, customVerifier);

        vm.prank(verifier);
        vm.expectRevert(abi.encodeWithSelector(ITaskEscrow.NotVerifier.selector, orderId, verifier));
        escrow.release(orderId, RESULT_HASH, RESULT_URI);

        vm.prank(customVerifier);
        escrow.release(orderId, RESULT_HASH, RESULT_URI);
        assertEq(uint8(_status(orderId)), uint8(ITaskEscrow.Status.Verified));
    }

    // =====================================================================
    // Double release
    // =====================================================================

    function test_release_revertsOnDoubleVerdict() public {
        uint256 orderId = _passed();
        vm.prank(verifier);
        vm.expectRevert(
            abi.encodeWithSelector(
                ITaskEscrow.InvalidStatus.selector, orderId, ITaskEscrow.Status.Verified, ITaskEscrow.Status.Delivered
            )
        );
        escrow.release(orderId, RESULT_HASH, RESULT_URI);
    }

    function test_release_revertsOnDoubleReleaseApproveForMe() public {
        ITaskEscrow.OrderParams memory p = _params();
        p.approvalMode = ITaskEscrow.ApprovalMode.ApproveForMe;
        uint256 orderId = _delivered(p);
        vm.prank(verifier);
        escrow.release(orderId, RESULT_HASH, RESULT_URI);

        vm.prank(verifier);
        vm.expectRevert(
            abi.encodeWithSelector(
                ITaskEscrow.InvalidStatus.selector, orderId, ITaskEscrow.Status.Released, ITaskEscrow.Status.Delivered
            )
        );
        escrow.release(orderId, RESULT_HASH, RESULT_URI);
        assertEq(usdc.balanceOf(sellerOwner), PRICE);
        assertEq(reputation.getLastIndex(sellerAgentId, address(escrow)), 1);
    }

    function test_approve_revertsOnDoubleApprove() public {
        uint256 orderId = _passed();
        vm.prank(buyer);
        escrow.approve(orderId);

        bytes memory err = abi.encodeWithSelector(
            ITaskEscrow.InvalidStatus.selector, orderId, ITaskEscrow.Status.Released, ITaskEscrow.Status.Verified
        );
        vm.prank(buyer);
        vm.expectRevert(err);
        escrow.approve(orderId);
        vm.warp(vm.getBlockTimestamp() + 30 days);
        vm.expectRevert(err);
        escrow.releaseExpired(orderId);
        assertEq(usdc.balanceOf(sellerOwner), PRICE);
    }

    function test_approve_revertsBeforeVerification() public {
        uint256 orderId = _delivered();
        vm.prank(buyer);
        vm.expectRevert(
            abi.encodeWithSelector(
                ITaskEscrow.InvalidStatus.selector, orderId, ITaskEscrow.Status.Delivered, ITaskEscrow.Status.Verified
            )
        );
        escrow.approve(orderId);
    }

    function test_release_revertsAfterRefund() public {
        uint256 orderId = _funded();
        vm.warp(deliverBy + 1);
        escrow.refundExpired(orderId);
        vm.prank(verifier);
        vm.expectRevert(
            abi.encodeWithSelector(
                ITaskEscrow.InvalidStatus.selector, orderId, ITaskEscrow.Status.Refunded, ITaskEscrow.Status.Delivered
            )
        );
        escrow.release(orderId, RESULT_HASH, RESULT_URI);
    }

    function test_release_revertsAfterReviewWindow() public {
        uint256 orderId = _delivered();
        uint64 deadline = escrow.reviewDeadline(orderId);
        vm.warp(deadline + 1);
        vm.prank(verifier);
        vm.expectRevert(abi.encodeWithSelector(ITaskEscrow.ReviewWindowClosed.selector, orderId, deadline));
        escrow.release(orderId, RESULT_HASH, RESULT_URI);
    }

    function test_release_allowedAtWindowEnd() public {
        uint256 orderId = _delivered();
        vm.warp(escrow.reviewDeadline(orderId));
        vm.prank(verifier);
        escrow.release(orderId, RESULT_HASH, RESULT_URI);
        assertEq(uint8(_status(orderId)), uint8(ITaskEscrow.Status.Verified));
    }

    function test_release_revertsOnZeroResultHash() public {
        uint256 orderId = _delivered();
        vm.prank(verifier);
        vm.expectRevert(ITaskEscrow.ZeroHash.selector);
        escrow.release(orderId, bytes32(0), RESULT_URI);
    }

    function test_release_revertsForUnknownOrder() public {
        vm.prank(verifier);
        vm.expectRevert(
            abi.encodeWithSelector(
                ITaskEscrow.InvalidStatus.selector, 42, ITaskEscrow.Status.None, ITaskEscrow.Status.Delivered
            )
        );
        escrow.release(42, RESULT_HASH, RESULT_URI);
    }

    // =====================================================================
    // fail
    // =====================================================================

    function test_fail_refundsBuyerAndRecordsFailure() public {
        uint256 orderId = _delivered();

        vm.expectEmit(address(escrow));
        emit ITaskEscrow.OrderVerified(orderId, verifier, false, RESULT_HASH, RESULT_URI);
        vm.expectEmit(address(escrow));
        emit ITaskEscrow.OrderRefunded(orderId, buyer, PRICE, ITaskEscrow.RefundReason.Failed);
        vm.recordLogs();
        vm.prank(verifier);
        escrow.fail(orderId, RESULT_HASH, RESULT_URI);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        // Same block, so the preview reproduces exactly the file that was published.
        string memory expertJson = escrow.previewFeedback(orderId, ITaskEscrow.Role.Expert, false, true, false);
        string memory buyerJson = escrow.previewFeedback(orderId, ITaskEscrow.Role.Buyer, true, true, false);
        uint256 found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(escrow) || logs[i].topics[0] != ITaskEscrow.FulfillmentRecorded.selector) {
                continue;
            }
            (ITaskEscrow.Role role, uint64 idx, bool passed, bool onTime, bytes32 feedbackHash) =
                abi.decode(logs[i].data, (ITaskEscrow.Role, uint64, bool, bool, bytes32));
            assertEq(idx, 1);
            assertTrue(onTime);
            if (role == ITaskEscrow.Role.Expert) {
                assertFalse(passed);
                assertEq(feedbackHash, keccak256(bytes(expertJson)));
            } else {
                assertTrue(passed);
                assertEq(feedbackHash, keccak256(bytes(buyerJson)));
            }
            ++found;
        }
        assertEq(found, 2, "expert + buyer feedback");
        assertEq(vm.parseJsonString(expertJson, ".outcome"), "refunded");

        ITaskEscrow.Order memory o = escrow.getOrder(orderId);
        assertEq(uint8(o.status), uint8(ITaskEscrow.Status.Refunded));
        assertFalse(o.passed);
        assertEq(o.resultHash, RESULT_HASH);
        assertEq(usdc.balanceOf(buyer), BUYER_BALANCE);
        assertEq(usdc.balanceOf(sellerOwner), 0);
        assertEq(usdc.balanceOf(address(escrow)), 0);

        (int128 value, string memory tag1, string memory tag2) = _feedback(sellerAgentId, 1);
        assertEq(value, 0);
        assertEq(tag1, "expert");
        assertEq(tag2, TASK_TYPE);
    }

    function test_fail_revertsAfterPass() public {
        uint256 orderId = _passed();
        vm.prank(verifier);
        vm.expectRevert(
            abi.encodeWithSelector(
                ITaskEscrow.InvalidStatus.selector, orderId, ITaskEscrow.Status.Verified, ITaskEscrow.Status.Delivered
            )
        );
        escrow.fail(orderId, RESULT_HASH, RESULT_URI);
    }

    function test_fail_revertsAfterReviewWindow() public {
        uint256 orderId = _delivered();
        uint64 deadline = escrow.reviewDeadline(orderId);
        vm.warp(deadline + 1);
        vm.prank(verifier);
        vm.expectRevert(abi.encodeWithSelector(ITaskEscrow.ReviewWindowClosed.selector, orderId, deadline));
        escrow.fail(orderId, RESULT_HASH, RESULT_URI);
    }

    // =====================================================================
    // Timeout refunds
    // =====================================================================

    function test_refundExpired_notDelivered_refundsAndRecordsLateFailure() public {
        uint256 orderId = _funded();
        assertFalse(escrow.isRefundable(orderId));

        vm.warp(deliverBy + 1);
        assertTrue(escrow.isRefundable(orderId));
        string memory expertJson = escrow.previewFeedback(orderId, ITaskEscrow.Role.Expert, false, false, false);

        vm.expectEmit(address(escrow));
        emit ITaskEscrow.FulfillmentRecorded(
            orderId, sellerAgentId, ITaskEscrow.Role.Expert, 1, false, false, keccak256(bytes(expertJson))
        );
        vm.expectEmit(address(escrow));
        emit ITaskEscrow.OrderRefunded(orderId, buyer, PRICE, ITaskEscrow.RefundReason.NotDelivered);
        vm.prank(buyer);
        escrow.refundExpired(orderId);

        assertEq(uint8(_status(orderId)), uint8(ITaskEscrow.Status.Refunded));
        assertEq(usdc.balanceOf(buyer), BUYER_BALANCE);
        assertEq(usdc.balanceOf(address(escrow)), 0);
        (int128 value,,) = _feedback(sellerAgentId, 1);
        assertEq(value, 0);
        (value,,) = _feedback(buyerAgentId, 1);
        assertEq(value, 100);
    }

    function test_refundExpired_isPermissionlessButPaysBuyer() public {
        uint256 orderId = _funded();
        vm.warp(deliverBy + 1);
        vm.prank(stranger);
        escrow.refundExpired(orderId);
        assertEq(usdc.balanceOf(buyer), BUYER_BALANCE);
        assertEq(usdc.balanceOf(stranger), 0);
    }

    function test_refundExpired_notVerified_noExpertFeedback() public {
        uint256 orderId = _delivered();
        uint64 deadline = escrow.reviewDeadline(orderId);

        vm.warp(deadline);
        assertFalse(escrow.isRefundable(orderId));
        vm.expectRevert(abi.encodeWithSelector(ITaskEscrow.NotRefundable.selector, orderId));
        escrow.refundExpired(orderId);

        vm.warp(deadline + 1);
        vm.expectEmit(address(escrow));
        emit ITaskEscrow.OrderRefunded(orderId, buyer, PRICE, ITaskEscrow.RefundReason.NotVerified);
        escrow.refundExpired(orderId);

        assertEq(uint8(_status(orderId)), uint8(ITaskEscrow.Status.Refunded));
        assertEq(usdc.balanceOf(buyer), BUYER_BALANCE);
        assertEq(reputation.getLastIndex(sellerAgentId, address(escrow)), 0);
        assertEq(escrow.getOrder(orderId).sellerFeedbackIndex, 0);
        assertEq(reputation.getLastIndex(buyerAgentId, address(escrow)), 1);
    }

    function test_refundExpired_revertsAtDeliverBy() public {
        uint256 orderId = _funded();
        vm.warp(deliverBy);
        vm.expectRevert(abi.encodeWithSelector(ITaskEscrow.NotRefundable.selector, orderId));
        escrow.refundExpired(orderId);
    }

    function test_refundExpired_revertsForUnfundedOrders() public {
        uint256 created = _create();
        uint256 agreed = _agreed();
        vm.warp(deliverBy + 1);
        vm.expectRevert(abi.encodeWithSelector(ITaskEscrow.NotRefundable.selector, created));
        escrow.refundExpired(created);
        vm.expectRevert(abi.encodeWithSelector(ITaskEscrow.NotRefundable.selector, agreed));
        escrow.refundExpired(agreed);
    }

    function test_refundExpired_revertsTwice() public {
        uint256 orderId = _funded();
        vm.warp(deliverBy + 1);
        escrow.refundExpired(orderId);
        vm.expectRevert(abi.encodeWithSelector(ITaskEscrow.NotRefundable.selector, orderId));
        escrow.refundExpired(orderId);
        assertEq(usdc.balanceOf(buyer), BUYER_BALANCE);
    }

    function test_refundExpired_revertsAfterRelease() public {
        uint256 orderId = _passed();
        vm.prank(buyer);
        escrow.approve(orderId);
        vm.warp(vm.getBlockTimestamp() + 30 days);
        vm.expectRevert(abi.encodeWithSelector(ITaskEscrow.NotRefundable.selector, orderId));
        escrow.refundExpired(orderId);
    }

    // =====================================================================
    // createOrder
    // =====================================================================

    function test_createOrder_incrementsIds() public {
        assertEq(_create(), 1);
        assertEq(_create(), 2);
        assertEq(escrow.nextOrderId(), 3);
    }

    function test_createOrder_storesSpecHashOnly() public {
        uint256 orderId = _create();
        ITaskEscrow.Order memory o = escrow.getOrder(orderId);
        assertEq(o.specHash, keccak256(bytes(SPEC_JSON)));
        assertEq(escrow.hashSpec(bytes(SPEC_JSON)), SPEC_HASH);
        assertEq(o.verifier, verifier, "defaults to protocol verifier");
        assertEq(uint8(o.approvalMode), uint8(ITaskEscrow.ApprovalMode.User));
        assertEq(usdc.balanceOf(address(escrow)), 0);
    }

    function test_createOrder_payeeIsVerifiedAgentWallet() public {
        (address wallet, uint256 walletKey) = makeAddrAndKey("sellerWallet");
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        bytes memory sig = _signAgentWallet(walletKey, sellerAgentId, wallet, sellerOwner, deadline);
        vm.prank(sellerOwner);
        identity.setAgentWallet(sellerAgentId, wallet, deadline, sig);

        uint256 orderId = _create();
        assertEq(escrow.getOrder(orderId).payee, wallet);

        vm.prank(wallet);
        escrow.agree(orderId, SPEC_HASH);
        vm.prank(buyer);
        escrow.fund(orderId);
        vm.prank(wallet);
        escrow.submitDelivery(orderId, DELIVERY_HASH, DELIVERY_URI);
        vm.prank(verifier);
        escrow.release(orderId, RESULT_HASH, RESULT_URI);
        vm.prank(buyer);
        escrow.approve(orderId);
        assertEq(usdc.balanceOf(wallet), PRICE);
        assertEq(usdc.balanceOf(sellerOwner), 0);
    }

    function test_createOrder_payeeFallsBackToOwnerWhenWalletCleared() public {
        address newOwner = makeAddr("newOwner");
        vm.prank(sellerOwner);
        identity.transferFrom(sellerOwner, newOwner, sellerAgentId);
        assertEq(identity.getAgentWallet(sellerAgentId), address(0));

        uint256 orderId = _create();
        assertEq(escrow.getOrder(orderId).payee, newOwner);
    }

    function test_createOrder_revertsOnInvalidTerms() public {
        ITaskEscrow.OrderParams memory p = _params();
        p.amount = 0;
        vm.prank(buyer);
        vm.expectRevert(ITaskEscrow.ZeroAmount.selector);
        escrow.createOrder(p);

        p = _params();
        p.specHash = bytes32(0);
        vm.prank(buyer);
        vm.expectRevert(ITaskEscrow.ZeroHash.selector);
        escrow.createOrder(p);

        p = _params();
        p.deliverBy = uint64(vm.getBlockTimestamp());
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(ITaskEscrow.InvalidDeadline.selector, p.deliverBy));
        escrow.createOrder(p);

        p = _params();
        p.reviewWindow = 0;
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(ITaskEscrow.InvalidReviewWindow.selector, 0));
        escrow.createOrder(p);

        p = _params();
        p.sellerAgentId = 999;
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 999));
        escrow.createOrder(p);
    }

    function test_createOrder_revertsOnInvalidTaskType() public {
        string[5] memory bad = ["", "Design.Logo", "has space", 'quo"te', "abcdefghijklmnopqrstuvwxyz0123456"];
        ITaskEscrow.OrderParams memory p = _params();
        for (uint256 i; i < bad.length; ++i) {
            p.taskType = bad[i];
            vm.prank(buyer);
            vm.expectRevert(abi.encodeWithSelector(ITaskEscrow.InvalidTaskType.selector, bad[i]));
            escrow.createOrder(p);
        }
    }

    function test_createOrder_revertsOnInvalidVerifier() public {
        ITaskEscrow.OrderParams memory p = _params();
        p.verifier = sellerOwner;
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(ITaskEscrow.InvalidVerifier.selector, sellerOwner));
        escrow.createOrder(p);
    }

    /// Demo path: the buyer address is the order verifier and later signs release.
    function test_createOrder_buyerIsVerifier() public {
        ITaskEscrow.OrderParams memory p = _params();
        p.verifier = buyer;
        p.approvalMode = ITaskEscrow.ApprovalMode.ApproveForMe;
        uint256 orderId = _delivered(p);
        assertEq(escrow.getOrder(orderId).verifier, buyer);
        assertEq(escrow.getOrder(orderId).buyer, buyer);

        vm.prank(buyer);
        escrow.release(orderId, RESULT_HASH, RESULT_URI);
        assertEq(uint8(_status(orderId)), uint8(ITaskEscrow.Status.Released));
        assertEq(usdc.balanceOf(sellerOwner), PRICE);
    }

    function test_createOrder_defaultVerifierAddressMayBuyAndVerify() public {
        usdc.mint(verifier, PRICE);
        ITaskEscrow.OrderParams memory p = _params();
        p.buyerAgentId = 0;
        vm.prank(verifier);
        uint256 orderId = escrow.createOrder(p);
        assertEq(escrow.getOrder(orderId).buyer, verifier);
        assertEq(escrow.getOrder(orderId).verifier, verifier);
    }

    function test_createOrder_revertsOnSelfDealing() public {
        ITaskEscrow.OrderParams memory p = _params();
        p.buyerAgentId = 0;
        vm.prank(sellerOwner);
        vm.expectRevert(abi.encodeWithSelector(ITaskEscrow.SelfDealing.selector, sellerOwner));
        escrow.createOrder(p);
    }

    function test_createOrder_revertsOnBuyerAgentNotControlledByCaller() public {
        vm.prank(stranger);
        uint256 strangerAgent = identity.register();
        ITaskEscrow.OrderParams memory p = _params();
        p.buyerAgentId = strangerAgent;
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(ITaskEscrow.InvalidBuyerAgent.selector, strangerAgent));
        escrow.createOrder(p);

        p.buyerAgentId = sellerAgentId;
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(ITaskEscrow.InvalidBuyerAgent.selector, sellerAgentId));
        escrow.createOrder(p);
    }

    // =====================================================================
    // agree (spec freeze)
    // =====================================================================

    function test_agree_revertsOnSpecMismatch() public {
        uint256 orderId = _create();
        bytes32 other = keccak256("tampered spec");
        vm.prank(sellerOwner);
        vm.expectRevert(abi.encodeWithSelector(ITaskEscrow.SpecMismatch.selector, SPEC_HASH, other));
        escrow.agree(orderId, other);
    }

    function test_agree_byOperator() public {
        address operator = makeAddr("operator");
        vm.prank(sellerOwner);
        identity.setApprovalForAll(operator, true);
        uint256 orderId = _create();
        vm.prank(operator);
        escrow.agree(orderId, SPEC_HASH);
        assertEq(uint8(_status(orderId)), uint8(ITaskEscrow.Status.Agreed));
    }

    function test_agree_revertsForNonSeller() public {
        uint256 orderId = _create();
        address[3] memory callers = [buyer, stranger, verifier];
        for (uint256 i; i < callers.length; ++i) {
            vm.prank(callers[i]);
            vm.expectRevert(abi.encodeWithSelector(ITaskEscrow.NotSeller.selector, orderId, callers[i]));
            escrow.agree(orderId, SPEC_HASH);
        }
    }

    function test_agree_revertsTwice() public {
        uint256 orderId = _agreed();
        vm.prank(sellerOwner);
        vm.expectRevert(
            abi.encodeWithSelector(
                ITaskEscrow.InvalidStatus.selector, orderId, ITaskEscrow.Status.Agreed, ITaskEscrow.Status.Created
            )
        );
        escrow.agree(orderId, SPEC_HASH);
    }

    function test_agree_revertsAfterDeadline() public {
        uint256 orderId = _create();
        vm.warp(deliverBy + 1);
        vm.prank(sellerOwner);
        vm.expectRevert(abi.encodeWithSelector(ITaskEscrow.OrderExpired.selector, orderId, deliverBy));
        escrow.agree(orderId, SPEC_HASH);
    }

    // =====================================================================
    // fund
    // =====================================================================

    function test_fund_revertsBeforeAgreement() public {
        uint256 orderId = _create();
        vm.prank(buyer);
        vm.expectRevert(
            abi.encodeWithSelector(
                ITaskEscrow.InvalidStatus.selector, orderId, ITaskEscrow.Status.Created, ITaskEscrow.Status.Agreed
            )
        );
        escrow.fund(orderId);
    }

    function test_fund_revertsForNonBuyer() public {
        uint256 orderId = _agreed();
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(ITaskEscrow.NotBuyer.selector, orderId, stranger));
        escrow.fund(orderId);
    }

    function test_fund_revertsTwice() public {
        uint256 orderId = _funded();
        vm.prank(buyer);
        vm.expectRevert(
            abi.encodeWithSelector(
                ITaskEscrow.InvalidStatus.selector, orderId, ITaskEscrow.Status.Funded, ITaskEscrow.Status.Agreed
            )
        );
        escrow.fund(orderId);
        assertEq(usdc.balanceOf(address(escrow)), PRICE);
    }

    function test_fund_revertsAfterDeadline() public {
        uint256 orderId = _agreed();
        vm.warp(deliverBy + 1);
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(ITaskEscrow.OrderExpired.selector, orderId, deliverBy));
        escrow.fund(orderId);
    }

    function test_fund_revertsWithoutAllowance() public {
        uint256 orderId = _agreed();
        vm.prank(buyer);
        usdc.approve(address(escrow), 0);
        vm.prank(buyer);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(escrow), 0, PRICE)
        );
        escrow.fund(orderId);
    }

    function test_fund_rejectsFeeOnTransferToken() public {
        FeeOnTransferToken fot = new FeeOnTransferToken();
        TaskEscrow fotEscrow = new TaskEscrow(IERC20(address(fot)), identity, reputation, verifier);
        fot.mint(buyer, PRICE);

        vm.startPrank(buyer);
        fot.approve(address(fotEscrow), PRICE);
        uint256 orderId = fotEscrow.createOrder(_params());
        vm.stopPrank();
        vm.prank(sellerOwner);
        fotEscrow.agree(orderId, SPEC_HASH);

        vm.prank(buyer);
        vm.expectRevert(
            abi.encodeWithSelector(ITaskEscrow.UnexpectedTransferAmount.selector, PRICE, PRICE - PRICE / 100)
        );
        fotEscrow.fund(orderId);
    }

    // =====================================================================
    // submitDelivery
    // =====================================================================

    function test_submitDelivery_storesHashAndUriOnly() public {
        uint256 orderId = _delivered();
        ITaskEscrow.Order memory o = escrow.getOrder(orderId);
        assertEq(o.deliveryHash, DELIVERY_HASH);
        assertEq(o.deliveryURI, DELIVERY_URI);
        assertEq(o.deliveredAt, vm.getBlockTimestamp());
    }

    function test_submitDelivery_revertsBeforeFunding() public {
        uint256 orderId = _agreed();
        vm.prank(sellerOwner);
        vm.expectRevert(
            abi.encodeWithSelector(
                ITaskEscrow.InvalidStatus.selector, orderId, ITaskEscrow.Status.Agreed, ITaskEscrow.Status.Funded
            )
        );
        escrow.submitDelivery(orderId, DELIVERY_HASH, DELIVERY_URI);
    }

    function test_submitDelivery_revertsForNonSeller() public {
        uint256 orderId = _funded();
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(ITaskEscrow.NotSeller.selector, orderId, stranger));
        escrow.submitDelivery(orderId, DELIVERY_HASH, DELIVERY_URI);
    }

    function test_submitDelivery_revertsOnEmptyCommitment() public {
        uint256 orderId = _funded();
        vm.startPrank(sellerOwner);
        vm.expectRevert(ITaskEscrow.ZeroHash.selector);
        escrow.submitDelivery(orderId, bytes32(0), DELIVERY_URI);
        vm.expectRevert(ITaskEscrow.EmptyURI.selector);
        escrow.submitDelivery(orderId, DELIVERY_HASH, "");
        vm.stopPrank();
    }

    function test_submitDelivery_revertsTwice() public {
        uint256 orderId = _delivered();
        vm.prank(sellerOwner);
        vm.expectRevert(
            abi.encodeWithSelector(
                ITaskEscrow.InvalidStatus.selector, orderId, ITaskEscrow.Status.Delivered, ITaskEscrow.Status.Funded
            )
        );
        escrow.submitDelivery(orderId, keccak256("other"), "ipfs://other");
    }

    function test_submitDelivery_revertsAfterTimeoutRefund() public {
        uint256 orderId = _funded();
        vm.warp(deliverBy + 1);
        escrow.refundExpired(orderId);
        vm.prank(sellerOwner);
        vm.expectRevert(
            abi.encodeWithSelector(
                ITaskEscrow.InvalidStatus.selector, orderId, ITaskEscrow.Status.Refunded, ITaskEscrow.Status.Funded
            )
        );
        escrow.submitDelivery(orderId, DELIVERY_HASH, DELIVERY_URI);
    }

    // =====================================================================
    // Reputation
    // =====================================================================

    function test_reputation_summaryByRoleAndTaskType() public {
        // 3 design.logo orders (2 passed, 1 failed) and 1 translate order (passed).
        for (uint256 i; i < 3; ++i) {
            uint256 id = _delivered();
            vm.prank(verifier);
            if (i == 2) {
                escrow.fail(id, RESULT_HASH, RESULT_URI);
            } else {
                escrow.release(id, RESULT_HASH, RESULT_URI);
                vm.prank(buyer);
                escrow.approve(id);
            }
        }
        ITaskEscrow.OrderParams memory p = _params();
        p.taskType = "translate";
        p.approvalMode = ITaskEscrow.ApprovalMode.ApproveForMe;
        uint256 t = _delivered(p);
        vm.prank(verifier);
        escrow.release(t, RESULT_HASH, RESULT_URI);

        (uint64 count, int128 avg, uint8 dec) = reputation.getSummary(sellerAgentId, _clients(), "expert", "");
        assertEq(count, 4);
        assertEq(avg, 75);
        assertEq(dec, 0);

        (count, avg,) = reputation.getSummary(sellerAgentId, _clients(), "expert", TASK_TYPE);
        assertEq(count, 3);
        assertEq(avg, 66); // 200 / 3, truncated

        (count, avg,) = reputation.getSummary(sellerAgentId, _clients(), "", "translate");
        assertEq(count, 1);
        assertEq(avg, 100);

        (count, avg,) = reputation.getSummary(buyerAgentId, _clients(), "buyer", "");
        assertEq(count, 4);
        assertEq(avg, 100);
    }

    function test_reputation_writeFailureDoesNotBlockSettlement() public {
        uint256 orderId = _passed();
        // ERC-8004 forbids feedback from an operator of the agent, so this makes giveFeedback revert.
        vm.prank(sellerOwner);
        identity.setApprovalForAll(address(escrow), true);

        vm.expectEmit(address(escrow));
        emit ITaskEscrow.ReputationWriteFailed(
            orderId,
            sellerAgentId,
            ITaskEscrow.Role.Expert,
            abi.encodeWithSelector(ReputationRegistry.SelfFeedback.selector, sellerAgentId, address(escrow))
        );
        vm.prank(buyer);
        escrow.approve(orderId);

        assertEq(uint8(_status(orderId)), uint8(ITaskEscrow.Status.Released));
        assertEq(usdc.balanceOf(sellerOwner), PRICE);
        assertEq(escrow.getOrder(orderId).sellerFeedbackIndex, 0);
        assertEq(escrow.getOrder(orderId).buyerFeedbackIndex, 1);
        assertEq(reputation.getLastIndex(sellerAgentId, address(escrow)), 0);
    }

    function test_reputation_feedbackIndexLinksOrders() public {
        uint256 a = _passed();
        uint256 b = _passed();
        vm.startPrank(buyer);
        escrow.approve(b);
        escrow.approve(a);
        vm.stopPrank();
        assertEq(escrow.getOrder(b).sellerFeedbackIndex, 1);
        assertEq(escrow.getOrder(a).sellerFeedbackIndex, 2);
        assertEq(reputation.getClients(sellerAgentId)[0], address(escrow));
    }

    // =====================================================================
    // Misc
    // =====================================================================

    function test_disputedIsReservedOnly() public pure {
        assertEq(uint8(ITaskEscrow.Status.Disputed), 8);
    }

    function test_previewFeedback_revertsForUnknownOrder() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                ITaskEscrow.InvalidStatus.selector, 7, ITaskEscrow.Status.None, ITaskEscrow.Status.Created
            )
        );
        escrow.previewFeedback(7, ITaskEscrow.Role.Expert, true, true, true);
    }

    function test_reentrancy_isBlockedDuringRelease() public {
        ReentrantToken token = new ReentrantToken();
        TaskEscrow rEscrow = new TaskEscrow(IERC20(address(token)), identity, reputation, verifier);
        token.mint(buyer, PRICE);

        vm.startPrank(buyer);
        token.approve(address(rEscrow), PRICE);
        uint256 orderId = rEscrow.createOrder(_params());
        vm.stopPrank();
        vm.prank(sellerOwner);
        rEscrow.agree(orderId, SPEC_HASH);
        vm.prank(buyer);
        rEscrow.fund(orderId);
        vm.prank(sellerOwner);
        rEscrow.submitDelivery(orderId, DELIVERY_HASH, DELIVERY_URI);
        vm.prank(verifier);
        rEscrow.release(orderId, RESULT_HASH, RESULT_URI);

        token.arm(address(rEscrow), abi.encodeCall(rEscrow.refundExpired, (orderId)));
        vm.prank(buyer);
        rEscrow.approve(orderId);

        assertTrue(token.reentered());
        assertEq(token.lastRevertData(), abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector));
        assertEq(token.balanceOf(sellerOwner), PRICE);
        assertEq(token.balanceOf(buyer), 0);
    }

    function testFuzz_lifecycle(uint256 amount, uint64 deliverOffset, uint32 window, uint64 deliveredAfter, bool pass)
        public
    {
        amount = bound(amount, 1, BUYER_BALANCE);
        deliverOffset = uint64(bound(deliverOffset, 1, 365 days));
        window = uint32(bound(window, 1, 30 days));
        deliveredAfter = uint64(bound(deliveredAfter, 0, 2 * uint256(deliverOffset)));

        ITaskEscrow.OrderParams memory p = _params();
        p.amount = amount;
        p.deliverBy = uint64(vm.getBlockTimestamp()) + deliverOffset;
        p.reviewWindow = window;
        p.approvalMode = ITaskEscrow.ApprovalMode.ApproveForMe;
        uint256 orderId = _funded(p);

        vm.warp(vm.getBlockTimestamp() + deliveredAfter);
        vm.prank(sellerOwner);
        escrow.submitDelivery(orderId, DELIVERY_HASH, DELIVERY_URI);
        vm.warp(vm.getBlockTimestamp() + window);
        bool onTime = deliveredAfter <= deliverOffset;
        string memory json = escrow.previewFeedback(orderId, ITaskEscrow.Role.Expert, pass, onTime, pass);

        vm.prank(verifier);
        if (pass) escrow.release(orderId, RESULT_HASH, RESULT_URI);
        else escrow.fail(orderId, RESULT_HASH, RESULT_URI);

        assertEq(usdc.balanceOf(sellerOwner), pass ? amount : 0);
        assertEq(usdc.balanceOf(buyer), pass ? BUYER_BALANCE - amount : BUYER_BALANCE);
        assertEq(usdc.balanceOf(address(escrow)), 0);
        (int128 value,,) = _feedback(sellerAgentId, 1);
        assertEq(value, pass ? int128(100) : int128(0));
        assertEq(vm.parseJsonBool(json, ".on_time"), onTime);
        assertEq(vm.parseJsonBool(json, ".passed"), pass);
    }
}
