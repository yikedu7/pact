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
    // =====================================================================
    // Constructor
    // =====================================================================

    function test_constructor_wiresDependencies() public view {
        assertEq(address(escrow.paymentToken()), address(usdc));
        assertEq(address(escrow.identityRegistry()), address(identity));
        assertEq(address(escrow.reputationRegistry()), address(reputation));
        assertEq(escrow.nextOrderId(), 1);
    }

    function test_constructor_revertsOnZeroAddress() public {
        vm.expectRevert(ITaskEscrow.ZeroAddress.selector);
        new TaskEscrow(IERC20(address(0)), identity, IReputationRegistry(address(reputation)));
    }

    function test_constructor_revertsOnRegistryMismatch() public {
        IdentityRegistry other = new IdentityRegistry();
        vm.expectRevert(abi.encodeWithSelector(TaskEscrow.RegistryMismatch.selector, address(other), address(identity)));
        new TaskEscrow(IERC20(address(usdc)), IIdentityRegistry(address(other)), reputation);
    }

    // =====================================================================
    // Happy path: Created -> Agreed -> Funded -> Delivered -> Verified -> Released
    // =====================================================================

    function test_happyPath_endToEnd() public {
        vm.expectEmit(address(escrow));
        emit ITaskEscrow.OrderCreated(
            1,
            buyer,
            sellerAgentId,
            sellerOwner,
            verifier,
            PRICE,
            SPEC_HASH,
            SPEC_URI,
            TASK_TYPE,
            deliverBy,
            VERIFY_WINDOW
        );
        uint256 orderId = _create();
        assertEq(uint8(_status(orderId)), uint8(ITaskEscrow.Status.Created));

        vm.expectEmit(address(escrow));
        emit ITaskEscrow.OrderAgreed(orderId, sellerOwner);
        vm.prank(sellerOwner);
        escrow.agree(orderId);
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
        assertEq(escrow.verifyDeadline(orderId), vm.getBlockTimestamp() + VERIFY_WINDOW);

        vm.warp(vm.getBlockTimestamp() + 10 minutes);
        vm.expectEmit(address(escrow));
        emit ITaskEscrow.OrderVerified(orderId, verifier, REPORT_HASH, REPORT_URI);
        vm.prank(verifier);
        escrow.verify(orderId, REPORT_HASH, REPORT_URI);
        assertEq(uint8(_status(orderId)), uint8(ITaskEscrow.Status.Verified));

        string memory expectedJson = escrow.previewFeedback(orderId, true, true);
        vm.expectEmit(address(reputation));
        emit IReputationRegistry.NewFeedback(
            sellerAgentId,
            address(escrow),
            1,
            100,
            0,
            TASK_TYPE,
            TASK_TYPE,
            "on_time",
            "",
            FulfillmentFeedback.toDataURI(expectedJson),
            keccak256(bytes(expectedJson))
        );
        vm.expectEmit(address(escrow));
        emit ITaskEscrow.FulfillmentRecorded(orderId, sellerAgentId, 1, true, true, keccak256(bytes(expectedJson)));
        vm.expectEmit(address(escrow));
        emit ITaskEscrow.OrderReleased(orderId, sellerOwner, PRICE);
        vm.prank(verifier);
        escrow.release(orderId);

        ITaskEscrow.Order memory o = escrow.getOrder(orderId);
        assertEq(uint8(o.status), uint8(ITaskEscrow.Status.Released));
        assertEq(o.buyer, buyer);
        assertEq(o.payee, sellerOwner);
        assertEq(o.verifier, verifier);
        assertEq(o.amount, PRICE);
        assertEq(o.specHash, SPEC_HASH);
        assertEq(o.deliveryHash, DELIVERY_HASH);
        assertEq(o.deliveryURI, DELIVERY_URI);
        assertEq(o.reportHash, REPORT_HASH);
        assertEq(o.taskType, TASK_TYPE);
        assertEq(o.feedbackIndex, 1);

        assertEq(usdc.balanceOf(address(escrow)), 0);
        assertEq(usdc.balanceOf(sellerOwner), PRICE);
        assertEq(usdc.balanceOf(buyer), BUYER_BALANCE - PRICE);

        (int128 value, uint8 decimals, string memory tag1, string memory tag2, bool revoked) =
            reputation.readFeedback(sellerAgentId, address(escrow), 1);
        assertEq(value, 100);
        assertEq(decimals, 0);
        assertEq(tag1, TASK_TYPE);
        assertEq(tag2, "on_time");
        assertFalse(revoked);
    }

    function test_feedbackFile_containsRequiredProductFields() public {
        uint256 orderId = _verified();
        string memory json = escrow.previewFeedback(orderId, true, true);

        assertEq(vm.parseJsonString(json, ".task_type"), TASK_TYPE);
        assertEq(vm.parseJsonString(json, ".amount"), vm.toString(PRICE));
        assertTrue(vm.parseJsonBool(json, ".passed"));
        assertTrue(vm.parseJsonBool(json, ".on_time"));

        assertEq(vm.parseJsonString(json, ".token"), vm.toString(address(usdc)));
        assertEq(vm.parseJsonString(json, ".orderId"), vm.toString(orderId));
        assertEq(vm.parseJsonBytes32(json, ".specHash"), SPEC_HASH);
        assertEq(vm.parseJsonBytes32(json, ".deliveryHash"), DELIVERY_HASH);
        assertEq(vm.parseJsonBytes32(json, ".reportHash"), REPORT_HASH);

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
    }

    function test_release_byPayee() public {
        uint256 orderId = _verified();
        vm.prank(sellerOwner);
        escrow.release(orderId);
        assertEq(uint8(_status(orderId)), uint8(ITaskEscrow.Status.Released));
        assertEq(usdc.balanceOf(sellerOwner), PRICE);
    }

    function test_release_lateDeliveryRecordsOnTimeFalse() public {
        uint256 orderId = _funded();
        vm.warp(deliverBy + 1);

        vm.expectEmit(address(escrow));
        emit ITaskEscrow.OrderDelivered(orderId, sellerOwner, DELIVERY_HASH, DELIVERY_URI, false);
        vm.prank(sellerOwner);
        escrow.submitDelivery(orderId, DELIVERY_HASH, DELIVERY_URI);

        vm.startPrank(verifier);
        escrow.verify(orderId, REPORT_HASH, REPORT_URI);
        escrow.release(orderId);
        vm.stopPrank();

        (int128 value,,, string memory tag2,) = reputation.readFeedback(sellerAgentId, address(escrow), 1);
        assertEq(value, 100);
        assertEq(tag2, "late");
        assertEq(usdc.balanceOf(sellerOwner), PRICE);
    }

    function test_release_deliveryExactlyAtDeadlineIsOnTime() public {
        uint256 orderId = _funded();
        vm.warp(deliverBy);
        vm.prank(sellerOwner);
        escrow.submitDelivery(orderId, DELIVERY_HASH, DELIVERY_URI);
        vm.startPrank(verifier);
        escrow.verify(orderId, REPORT_HASH, REPORT_URI);
        escrow.release(orderId);
        vm.stopPrank();
        (,,, string memory tag2,) = reputation.readFeedback(sellerAgentId, address(escrow), 1);
        assertEq(tag2, "on_time");
    }

    function test_verified_isNeverRefundable() public {
        uint256 orderId = _verified();
        vm.warp(vm.getBlockTimestamp() + 365 days);
        assertFalse(escrow.isRefundable(orderId));
        vm.expectRevert(abi.encodeWithSelector(ITaskEscrow.NotRefundable.selector, orderId));
        escrow.refundExpired(orderId);

        vm.prank(sellerOwner);
        escrow.release(orderId);
        assertEq(usdc.balanceOf(sellerOwner), PRICE);
    }

    // =====================================================================
    // Unauthorized / double release
    // =====================================================================

    function test_release_revertsForUnauthorizedCallers() public {
        uint256 orderId = _verified();
        address[2] memory callers = [buyer, stranger];
        for (uint256 i; i < callers.length; ++i) {
            vm.prank(callers[i]);
            vm.expectRevert(abi.encodeWithSelector(ITaskEscrow.NotReleaser.selector, orderId, callers[i]));
            escrow.release(orderId);
        }
        assertEq(uint8(_status(orderId)), uint8(ITaskEscrow.Status.Verified));
        assertEq(usdc.balanceOf(address(escrow)), PRICE);
    }

    function testFuzz_release_onlyVerifierOrPayee(address caller) public {
        vm.assume(caller != verifier && caller != sellerOwner);
        uint256 orderId = _verified();
        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(ITaskEscrow.NotReleaser.selector, orderId, caller));
        escrow.release(orderId);
    }

    function testFuzz_verify_onlyVerifier(address caller) public {
        vm.assume(caller != verifier);
        uint256 orderId = _delivered();
        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(ITaskEscrow.NotVerifier.selector, orderId, caller));
        escrow.verify(orderId, REPORT_HASH, REPORT_URI);
    }

    function testFuzz_fail_onlyVerifier(address caller) public {
        vm.assume(caller != verifier);
        uint256 orderId = _delivered();
        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(ITaskEscrow.NotVerifier.selector, orderId, caller));
        escrow.fail(orderId, REPORT_HASH, REPORT_URI);
    }

    function test_release_revertsOnDoubleRelease() public {
        uint256 orderId = _verified();
        vm.prank(verifier);
        escrow.release(orderId);

        vm.prank(verifier);
        vm.expectRevert(
            abi.encodeWithSelector(
                ITaskEscrow.InvalidStatus.selector, orderId, ITaskEscrow.Status.Released, ITaskEscrow.Status.Verified
            )
        );
        escrow.release(orderId);
        assertEq(usdc.balanceOf(sellerOwner), PRICE);
        assertEq(reputation.getLastIndex(sellerAgentId, address(escrow)), 1);
    }

    function test_release_revertsBeforeVerification() public {
        uint256 orderId = _delivered();
        vm.prank(verifier);
        vm.expectRevert(
            abi.encodeWithSelector(
                ITaskEscrow.InvalidStatus.selector, orderId, ITaskEscrow.Status.Delivered, ITaskEscrow.Status.Verified
            )
        );
        escrow.release(orderId);
    }

    function test_release_revertsAfterRefund() public {
        uint256 orderId = _funded();
        vm.warp(deliverBy + 1);
        escrow.refundExpired(orderId);
        vm.prank(verifier);
        vm.expectRevert(
            abi.encodeWithSelector(
                ITaskEscrow.InvalidStatus.selector, orderId, ITaskEscrow.Status.Refunded, ITaskEscrow.Status.Verified
            )
        );
        escrow.release(orderId);
    }

    function test_release_revertsForUnknownOrder() public {
        vm.prank(verifier);
        vm.expectRevert(
            abi.encodeWithSelector(
                ITaskEscrow.InvalidStatus.selector, 42, ITaskEscrow.Status.None, ITaskEscrow.Status.Verified
            )
        );
        escrow.release(42);
    }

    // =====================================================================
    // createOrder
    // =====================================================================

    function test_createOrder_incrementsIds() public {
        assertEq(_create(), 1);
        assertEq(_create(), 2);
        assertEq(escrow.nextOrderId(), 3);
    }

    function test_createOrder_freezesSpecHash() public {
        uint256 orderId = _create();
        assertEq(escrow.getOrder(orderId).specHash, keccak256(bytes(SPEC_JSON)));
        assertEq(escrow.hashSpec(bytes(SPEC_JSON)), SPEC_HASH);
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
        escrow.agree(orderId);
        vm.prank(buyer);
        escrow.fund(orderId);
        vm.prank(wallet);
        escrow.submitDelivery(orderId, DELIVERY_HASH, DELIVERY_URI);
        vm.startPrank(verifier);
        escrow.verify(orderId, REPORT_HASH, REPORT_URI);
        escrow.release(orderId);
        vm.stopPrank();
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

    function test_createOrder_revertsOnZeroAmount() public {
        vm.prank(buyer);
        vm.expectRevert(ITaskEscrow.ZeroAmount.selector);
        escrow.createOrder(sellerAgentId, verifier, 0, SPEC_HASH, SPEC_URI, TASK_TYPE, deliverBy, VERIFY_WINDOW);
    }

    function test_createOrder_revertsOnZeroSpecHash() public {
        vm.prank(buyer);
        vm.expectRevert(ITaskEscrow.ZeroHash.selector);
        escrow.createOrder(sellerAgentId, verifier, PRICE, bytes32(0), SPEC_URI, TASK_TYPE, deliverBy, VERIFY_WINDOW);
    }

    function test_createOrder_revertsOnInvalidTaskType() public {
        string[5] memory bad = ["", "Summarize", "has space", 'quo"te', "abcdefghijklmnopqrstuvwxyz0123456"];
        for (uint256 i; i < bad.length; ++i) {
            vm.prank(buyer);
            vm.expectRevert(abi.encodeWithSelector(ITaskEscrow.InvalidTaskType.selector, bad[i]));
            escrow.createOrder(sellerAgentId, verifier, PRICE, SPEC_HASH, SPEC_URI, bad[i], deliverBy, VERIFY_WINDOW);
        }
    }

    function test_createOrder_acceptsTaskTypeCharset() public {
        vm.prank(buyer);
        escrow.createOrder(
            sellerAgentId, verifier, PRICE, SPEC_HASH, SPEC_URI, "code-review_v2.1", deliverBy, VERIFY_WINDOW
        );
    }

    function test_createOrder_revertsOnPastDeadline() public {
        uint64 nowTs = uint64(vm.getBlockTimestamp());
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(ITaskEscrow.InvalidDeadline.selector, nowTs));
        escrow.createOrder(sellerAgentId, verifier, PRICE, SPEC_HASH, SPEC_URI, TASK_TYPE, nowTs, VERIFY_WINDOW);
    }

    function test_createOrder_revertsOnZeroVerifyWindow() public {
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(ITaskEscrow.InvalidVerifyWindow.selector, 0));
        escrow.createOrder(sellerAgentId, verifier, PRICE, SPEC_HASH, SPEC_URI, TASK_TYPE, deliverBy, 0);
    }

    function test_createOrder_revertsOnUnknownAgent() public {
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 999));
        escrow.createOrder(999, verifier, PRICE, SPEC_HASH, SPEC_URI, TASK_TYPE, deliverBy, VERIFY_WINDOW);
    }

    function test_createOrder_revertsOnInvalidVerifier() public {
        address[3] memory bad = [address(0), buyer, sellerOwner];
        for (uint256 i; i < bad.length; ++i) {
            vm.prank(buyer);
            vm.expectRevert(abi.encodeWithSelector(ITaskEscrow.InvalidVerifier.selector, bad[i]));
            escrow.createOrder(sellerAgentId, bad[i], PRICE, SPEC_HASH, SPEC_URI, TASK_TYPE, deliverBy, VERIFY_WINDOW);
        }
    }

    function test_createOrder_revertsOnSelfDealing() public {
        vm.prank(sellerOwner);
        vm.expectRevert(abi.encodeWithSelector(ITaskEscrow.SelfDealing.selector, sellerOwner));
        escrow.createOrder(sellerAgentId, verifier, PRICE, SPEC_HASH, SPEC_URI, TASK_TYPE, deliverBy, VERIFY_WINDOW);
    }

    // =====================================================================
    // agree
    // =====================================================================

    function test_agree_byOperator() public {
        address operator = makeAddr("operator");
        vm.prank(sellerOwner);
        identity.setApprovalForAll(operator, true);
        uint256 orderId = _create();
        vm.prank(operator);
        escrow.agree(orderId);
        assertEq(uint8(_status(orderId)), uint8(ITaskEscrow.Status.Agreed));
    }

    function test_agree_revertsForNonSeller() public {
        uint256 orderId = _create();
        address[3] memory callers = [buyer, stranger, verifier];
        for (uint256 i; i < callers.length; ++i) {
            vm.prank(callers[i]);
            vm.expectRevert(abi.encodeWithSelector(ITaskEscrow.NotSeller.selector, orderId, callers[i]));
            escrow.agree(orderId);
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
        escrow.agree(orderId);
    }

    function test_agree_revertsAfterDeadline() public {
        uint256 orderId = _create();
        vm.warp(deliverBy + 1);
        vm.prank(sellerOwner);
        vm.expectRevert(abi.encodeWithSelector(ITaskEscrow.OrderExpired.selector, orderId, deliverBy));
        escrow.agree(orderId);
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
        TaskEscrow fotEscrow = new TaskEscrow(IERC20(address(fot)), identity, reputation);
        fot.mint(buyer, PRICE);

        vm.startPrank(buyer);
        fot.approve(address(fotEscrow), PRICE);
        uint256 orderId = fotEscrow.createOrder(
            sellerAgentId, verifier, PRICE, SPEC_HASH, SPEC_URI, TASK_TYPE, deliverBy, VERIFY_WINDOW
        );
        vm.stopPrank();
        vm.prank(sellerOwner);
        fotEscrow.agree(orderId);

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
    // verify / fail
    // =====================================================================

    function test_verify_revertsTwice() public {
        uint256 orderId = _verified();
        vm.prank(verifier);
        vm.expectRevert(
            abi.encodeWithSelector(
                ITaskEscrow.InvalidStatus.selector, orderId, ITaskEscrow.Status.Verified, ITaskEscrow.Status.Delivered
            )
        );
        escrow.verify(orderId, REPORT_HASH, REPORT_URI);
    }

    function test_verify_revertsAfterWindow() public {
        uint256 orderId = _delivered();
        uint64 deadline = escrow.verifyDeadline(orderId);
        vm.warp(deadline + 1);
        vm.prank(verifier);
        vm.expectRevert(abi.encodeWithSelector(ITaskEscrow.VerificationWindowClosed.selector, orderId, deadline));
        escrow.verify(orderId, REPORT_HASH, REPORT_URI);
    }

    function test_verify_allowedAtWindowEnd() public {
        uint256 orderId = _delivered();
        vm.warp(escrow.verifyDeadline(orderId));
        vm.prank(verifier);
        escrow.verify(orderId, REPORT_HASH, REPORT_URI);
        assertEq(uint8(_status(orderId)), uint8(ITaskEscrow.Status.Verified));
    }

    function test_fail_refundsBuyerAndRecordsFailure() public {
        uint256 orderId = _delivered();

        vm.expectEmit(address(escrow));
        emit ITaskEscrow.OrderRefunded(orderId, buyer, PRICE, ITaskEscrow.RefundReason.Failed, REPORT_HASH, REPORT_URI);
        vm.recordLogs();
        vm.prank(verifier);
        escrow.fail(orderId, REPORT_HASH, REPORT_URI);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        // Same block, so the preview reproduces exactly the file that was published.
        string memory json = escrow.previewFeedback(orderId, false, true);
        bool found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(escrow) && logs[i].topics[0] == ITaskEscrow.FulfillmentRecorded.selector) {
                (uint64 idx, bool passed, bool onTime, bytes32 feedbackHash) =
                    abi.decode(logs[i].data, (uint64, bool, bool, bytes32));
                assertEq(idx, 1);
                assertFalse(passed);
                assertTrue(onTime);
                assertEq(feedbackHash, keccak256(bytes(json)));
                found = true;
            }
        }
        assertTrue(found, "FulfillmentRecorded not emitted");
        assertEq(vm.parseJsonBytes32(json, ".reportHash"), REPORT_HASH);
        assertFalse(vm.parseJsonBool(json, ".passed"));
        assertTrue(vm.parseJsonBool(json, ".on_time"));

        assertEq(uint8(_status(orderId)), uint8(ITaskEscrow.Status.Refunded));
        assertEq(usdc.balanceOf(buyer), BUYER_BALANCE);
        assertEq(usdc.balanceOf(sellerOwner), 0);
        assertEq(usdc.balanceOf(address(escrow)), 0);

        (int128 value,, string memory tag1, string memory tag2,) =
            reputation.readFeedback(sellerAgentId, address(escrow), 1);
        assertEq(value, 0);
        assertEq(tag1, TASK_TYPE);
        assertEq(tag2, "on_time");
    }

    function test_fail_revertsAfterVerify() public {
        uint256 orderId = _verified();
        vm.prank(verifier);
        vm.expectRevert(
            abi.encodeWithSelector(
                ITaskEscrow.InvalidStatus.selector, orderId, ITaskEscrow.Status.Verified, ITaskEscrow.Status.Delivered
            )
        );
        escrow.fail(orderId, REPORT_HASH, REPORT_URI);
    }

    function test_fail_revertsAfterWindow() public {
        uint256 orderId = _delivered();
        uint64 deadline = escrow.verifyDeadline(orderId);
        vm.warp(deadline + 1);
        vm.prank(verifier);
        vm.expectRevert(abi.encodeWithSelector(ITaskEscrow.VerificationWindowClosed.selector, orderId, deadline));
        escrow.fail(orderId, REPORT_HASH, REPORT_URI);
    }

    // =====================================================================
    // Timeout refunds
    // =====================================================================

    function test_refundExpired_notDelivered_refundsAndRecordsLateFailure() public {
        uint256 orderId = _funded();
        assertFalse(escrow.isRefundable(orderId));

        vm.warp(deliverBy + 1);
        assertTrue(escrow.isRefundable(orderId));
        string memory expectedJson = escrow.previewFeedback(orderId, false, false);

        vm.expectEmit(address(escrow));
        emit ITaskEscrow.FulfillmentRecorded(orderId, sellerAgentId, 1, false, false, keccak256(bytes(expectedJson)));
        vm.expectEmit(address(escrow));
        emit ITaskEscrow.OrderRefunded(orderId, buyer, PRICE, ITaskEscrow.RefundReason.NotDelivered, bytes32(0), "");
        vm.prank(stranger);
        escrow.refundExpired(orderId);

        assertEq(uint8(_status(orderId)), uint8(ITaskEscrow.Status.Refunded));
        assertEq(usdc.balanceOf(buyer), BUYER_BALANCE);
        assertEq(usdc.balanceOf(stranger), 0);
        assertEq(usdc.balanceOf(address(escrow)), 0);

        (int128 value,,, string memory tag2,) = reputation.readFeedback(sellerAgentId, address(escrow), 1);
        assertEq(value, 0);
        assertEq(tag2, "late");
    }

    function test_refundExpired_notVerified_refundsWithoutFeedback() public {
        uint256 orderId = _delivered();
        uint64 deadline = escrow.verifyDeadline(orderId);

        vm.warp(deadline);
        assertFalse(escrow.isRefundable(orderId));
        vm.expectRevert(abi.encodeWithSelector(ITaskEscrow.NotRefundable.selector, orderId));
        escrow.refundExpired(orderId);

        vm.warp(deadline + 1);
        vm.recordLogs();
        escrow.refundExpired(orderId);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            assertTrue(logs[i].emitter != address(reputation), "no feedback on verifier timeout");
        }

        assertEq(uint8(_status(orderId)), uint8(ITaskEscrow.Status.Refunded));
        assertEq(usdc.balanceOf(buyer), BUYER_BALANCE);
        assertEq(reputation.getLastIndex(sellerAgentId, address(escrow)), 0);
        assertEq(escrow.getOrder(orderId).feedbackIndex, 0);
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
        uint256 orderId = _verified();
        vm.prank(verifier);
        escrow.release(orderId);
        vm.warp(vm.getBlockTimestamp() + 30 days);
        vm.expectRevert(abi.encodeWithSelector(ITaskEscrow.NotRefundable.selector, orderId));
        escrow.refundExpired(orderId);
    }

    // =====================================================================
    // Reputation
    // =====================================================================

    function test_reputation_summaryByTaskType() public {
        // 3 summarize orders (2 passed, 1 failed) and 1 translate order (passed).
        for (uint256 i; i < 3; ++i) {
            uint256 id = _delivered();
            vm.startPrank(verifier);
            if (i == 2) {
                escrow.fail(id, REPORT_HASH, REPORT_URI);
            } else {
                escrow.verify(id, REPORT_HASH, REPORT_URI);
                escrow.release(id);
            }
            vm.stopPrank();
        }
        vm.prank(buyer);
        uint256 t = escrow.createOrder(
            sellerAgentId, verifier, PRICE, SPEC_HASH, SPEC_URI, "translate", deliverBy, VERIFY_WINDOW
        );
        vm.prank(sellerOwner);
        escrow.agree(t);
        vm.prank(buyer);
        escrow.fund(t);
        vm.prank(sellerOwner);
        escrow.submitDelivery(t, DELIVERY_HASH, DELIVERY_URI);
        vm.startPrank(verifier);
        escrow.verify(t, REPORT_HASH, REPORT_URI);
        escrow.release(t);
        vm.stopPrank();

        (uint64 count, int128 avg, uint8 dec) = reputation.getSummary(sellerAgentId, _clients(), "", "");
        assertEq(count, 4);
        assertEq(avg, 75);
        assertEq(dec, 0);

        (count, avg,) = reputation.getSummary(sellerAgentId, _clients(), TASK_TYPE, "");
        assertEq(count, 3);
        assertEq(avg, 66); // 200 / 3, truncated

        (count, avg,) = reputation.getSummary(sellerAgentId, _clients(), "translate", "on_time");
        assertEq(count, 1);
        assertEq(avg, 100);
    }

    function test_reputation_writeFailureDoesNotBlockSettlement() public {
        uint256 orderId = _verified();
        // ERC-8004 forbids feedback from an operator of the agent, so this makes giveFeedback revert.
        vm.prank(sellerOwner);
        identity.setApprovalForAll(address(escrow), true);

        vm.expectEmit(address(escrow));
        emit ITaskEscrow.ReputationWriteFailed(
            orderId,
            sellerAgentId,
            abi.encodeWithSelector(ReputationRegistry.SelfFeedback.selector, sellerAgentId, address(escrow))
        );
        vm.prank(verifier);
        escrow.release(orderId);

        assertEq(uint8(_status(orderId)), uint8(ITaskEscrow.Status.Released));
        assertEq(usdc.balanceOf(sellerOwner), PRICE);
        assertEq(escrow.getOrder(orderId).feedbackIndex, 0);
        assertEq(reputation.getLastIndex(sellerAgentId, address(escrow)), 0);
    }

    function test_reputation_feedbackIndexLinksOrders() public {
        uint256 a = _verified();
        uint256 b = _verified();
        vm.startPrank(verifier);
        escrow.release(b);
        escrow.release(a);
        vm.stopPrank();
        assertEq(escrow.getOrder(b).feedbackIndex, 1);
        assertEq(escrow.getOrder(a).feedbackIndex, 2);
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
        escrow.previewFeedback(7, true, true);
    }

    function test_reentrancy_isBlockedDuringRelease() public {
        ReentrantToken token = new ReentrantToken();
        TaskEscrow rEscrow = new TaskEscrow(IERC20(address(token)), identity, reputation);
        token.mint(buyer, PRICE);

        vm.startPrank(buyer);
        token.approve(address(rEscrow), PRICE);
        uint256 orderId = rEscrow.createOrder(
            sellerAgentId, verifier, PRICE, SPEC_HASH, SPEC_URI, TASK_TYPE, deliverBy, VERIFY_WINDOW
        );
        vm.stopPrank();
        vm.prank(sellerOwner);
        rEscrow.agree(orderId);
        vm.prank(buyer);
        rEscrow.fund(orderId);
        vm.prank(sellerOwner);
        rEscrow.submitDelivery(orderId, DELIVERY_HASH, DELIVERY_URI);
        vm.prank(verifier);
        rEscrow.verify(orderId, REPORT_HASH, REPORT_URI);

        token.arm(address(rEscrow), abi.encodeCall(rEscrow.refundExpired, (orderId)));
        vm.prank(verifier);
        rEscrow.release(orderId);

        assertTrue(token.reentered());
        assertEq(token.lastRevertData(), abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector));
        assertEq(token.balanceOf(sellerOwner), PRICE);
        assertEq(token.balanceOf(buyer), 0);
    }

    function testFuzz_happyPath(uint256 amount, uint64 deliverOffset, uint32 window, uint64 deliveredAfter) public {
        amount = bound(amount, 1, BUYER_BALANCE);
        deliverOffset = uint64(bound(deliverOffset, 1, 365 days));
        window = uint32(bound(window, 1, 30 days));
        deliveredAfter = uint64(bound(deliveredAfter, 0, 2 * uint256(deliverOffset)));
        uint64 due = uint64(vm.getBlockTimestamp()) + deliverOffset;

        vm.prank(buyer);
        uint256 orderId =
            escrow.createOrder(sellerAgentId, verifier, amount, SPEC_HASH, SPEC_URI, TASK_TYPE, due, window);
        vm.prank(sellerOwner);
        escrow.agree(orderId);
        vm.prank(buyer);
        escrow.fund(orderId);

        vm.warp(vm.getBlockTimestamp() + deliveredAfter);
        vm.prank(sellerOwner);
        escrow.submitDelivery(orderId, DELIVERY_HASH, DELIVERY_URI);
        vm.warp(vm.getBlockTimestamp() + window);
        vm.startPrank(verifier);
        escrow.verify(orderId, REPORT_HASH, REPORT_URI);
        escrow.release(orderId);
        vm.stopPrank();

        assertEq(usdc.balanceOf(sellerOwner), amount);
        assertEq(usdc.balanceOf(buyer), BUYER_BALANCE - amount);
        (,,, string memory tag2,) = reputation.readFeedback(sellerAgentId, address(escrow), 1);
        assertEq(tag2, deliveredAfter <= deliverOffset ? "on_time" : "late");
    }
}
