// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IIdentityRegistry} from "./interfaces/IIdentityRegistry.sol";
import {IReputationRegistry} from "./interfaces/IReputationRegistry.sol";
import {ITaskEscrow} from "./interfaces/ITaskEscrow.sol";
import {FulfillmentFeedback} from "./libraries/FulfillmentFeedback.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title TaskEscrow
/// @notice Agent-to-agent task escrow with ERC-8004 reputation.
///
///         Created --agree--> Agreed --fund--> Funded --submitDelivery--> Delivered --verify--> Verified
///         Verified --release--> Released
///         Delivered --fail--> Refunded                       (verifier: delivery does not meet spec)
///         Funded --refundExpired--> Refunded                 (after deliverBy, nothing delivered)
///         Delivered --refundExpired--> Refunded              (verifier silent past the verify window)
///
///         The buyer freezes `specHash` (keccak256 of the canonical delivery-criteria JSON) at creation
///         and designates a verifier address. Outcomes attributable to the seller are written to the
///         ERC-8004 reputation registry with this contract as `clientAddress`, so readers can filter for
///         payment-backed feedback.
/// @dev    TESTNET MVP. No admin, no fees, no upgradability, no dispute resolution.
contract TaskEscrow is ITaskEscrow, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice ERC-8004 feedback `value` (0 decimals): `getSummary` then yields a pass rate in percent.
    int128 public constant PASSED_VALUE = 100;
    int128 public constant FAILED_VALUE = 0;

    IERC20 public immutable paymentToken;
    IIdentityRegistry public immutable identityRegistry;
    IReputationRegistry public immutable reputationRegistry;

    uint256 public nextOrderId = 1;

    mapping(uint256 orderId => Order) private _orders;

    error RegistryMismatch(address expected, address actual);

    constructor(IERC20 paymentToken_, IIdentityRegistry identityRegistry_, IReputationRegistry reputationRegistry_) {
        if (
            address(paymentToken_) == address(0) || address(identityRegistry_) == address(0)
                || address(reputationRegistry_) == address(0)
        ) revert ZeroAddress();
        address linked = reputationRegistry_.getIdentityRegistry();
        if (linked != address(identityRegistry_)) revert RegistryMismatch(address(identityRegistry_), linked);

        paymentToken = paymentToken_;
        identityRegistry = identityRegistry_;
        reputationRegistry = reputationRegistry_;
    }

    // ---------------------------------------------------------------------
    // Buyer
    // ---------------------------------------------------------------------

    /// @notice Opens an order and freezes its delivery criteria.
    /// @param sellerAgentId ERC-8004 agent id of the seller. Payee is its `agentWallet` (or owner) now.
    /// @param verifier Designated address allowed to `verify` / `fail` the delivery.
    /// @param specHash keccak256 of the canonicalized delivery-criteria JSON (see docs/ARCHITECTURE.md).
    /// @param specURI Where the criteria JSON can be fetched. Emitted only.
    /// @param taskType Category used as ERC-8004 `tag1` / `task_type`; 1-32 chars of `[a-z0-9_.-]`.
    /// @param deliverBy On-time cutoff. After it, the buyer may reclaim an undelivered order.
    /// @param verifyWindow Seconds the verifier has after delivery to `verify` or `fail`.
    function createOrder(
        uint256 sellerAgentId,
        address verifier,
        uint256 amount,
        bytes32 specHash,
        string calldata specURI,
        string calldata taskType,
        uint64 deliverBy,
        uint32 verifyWindow
    ) external returns (uint256 orderId) {
        if (amount == 0) revert ZeroAmount();
        if (specHash == bytes32(0)) revert ZeroHash();
        if (!FulfillmentFeedback.isValidTaskType(taskType)) revert InvalidTaskType(taskType);
        if (deliverBy <= block.timestamp) revert InvalidDeadline(deliverBy);
        if (verifyWindow == 0) revert InvalidVerifyWindow(verifyWindow);

        address agentOwner = IERC721(address(identityRegistry)).ownerOf(sellerAgentId);
        address payee = identityRegistry.getAgentWallet(sellerAgentId);
        if (payee == address(0)) payee = agentOwner;

        if (msg.sender == payee || msg.sender == agentOwner) revert SelfDealing(msg.sender);
        if (verifier == address(0) || verifier == msg.sender || verifier == payee || verifier == agentOwner) {
            revert InvalidVerifier(verifier);
        }

        orderId = nextOrderId++;
        Order storage o = _orders[orderId];
        o.buyer = msg.sender;
        o.deliverBy = deliverBy;
        o.status = Status.Created;
        o.payee = payee;
        o.verifier = verifier;
        o.verifyWindow = verifyWindow;
        o.sellerAgentId = sellerAgentId;
        o.amount = amount;
        o.specHash = specHash;
        o.taskType = taskType;

        emit OrderCreated(
            orderId,
            msg.sender,
            sellerAgentId,
            payee,
            verifier,
            amount,
            specHash,
            specURI,
            taskType,
            deliverBy,
            verifyWindow
        );
    }

    /// @notice Pulls `amount` of `paymentToken` from the buyer into escrow once the seller agreed.
    function fund(uint256 orderId) external nonReentrant {
        Order storage o = _orders[orderId];
        _requireStatus(orderId, o, Status.Agreed);
        if (msg.sender != o.buyer) revert NotBuyer(orderId, msg.sender);
        if (block.timestamp > o.deliverBy) revert OrderExpired(orderId, o.deliverBy);

        o.status = Status.Funded;
        uint256 balanceBefore = paymentToken.balanceOf(address(this));
        paymentToken.safeTransferFrom(msg.sender, address(this), o.amount);
        uint256 received = paymentToken.balanceOf(address(this)) - balanceBefore;
        if (received != o.amount) revert UnexpectedTransferAmount(o.amount, received);

        // forge-lint: disable-next-line(reentrancy-events)
        emit OrderFunded(orderId, msg.sender, o.amount);
    }

    // ---------------------------------------------------------------------
    // Seller
    // ---------------------------------------------------------------------

    /// @notice Seller accepts the frozen spec, price, verifier and deadline.
    function agree(uint256 orderId) external {
        Order storage o = _orders[orderId];
        _requireStatus(orderId, o, Status.Created);
        if (!_isSeller(o, msg.sender)) revert NotSeller(orderId, msg.sender);
        if (block.timestamp > o.deliverBy) revert OrderExpired(orderId, o.deliverBy);

        o.status = Status.Agreed;
        emit OrderAgreed(orderId, msg.sender);
    }

    /// @notice Commits to a delivery by content hash + URI (the payload itself stays off-chain).
    ///         Late delivery is accepted until someone calls `refundExpired`, and is recorded as late.
    function submitDelivery(uint256 orderId, bytes32 deliveryHash, string calldata deliveryURI) external {
        Order storage o = _orders[orderId];
        _requireStatus(orderId, o, Status.Funded);
        if (deliveryHash == bytes32(0)) revert ZeroHash();
        if (bytes(deliveryURI).length == 0) revert EmptyURI();
        if (!_isSeller(o, msg.sender)) revert NotSeller(orderId, msg.sender);

        o.status = Status.Delivered;
        // forge-lint: disable-next-line(unsafe-typecast)
        o.deliveredAt = uint64(block.timestamp);
        o.deliveryHash = deliveryHash;
        o.deliveryURI = deliveryURI;
        emit OrderDelivered(orderId, msg.sender, deliveryHash, deliveryURI, block.timestamp <= o.deliverBy);
    }

    // ---------------------------------------------------------------------
    // Verifier
    // ---------------------------------------------------------------------

    /// @notice Delivery meets the spec. Funds become releasable and can no longer be refunded.
    function verify(uint256 orderId, bytes32 reportHash, string calldata reportURI) external {
        Order storage o = _orders[orderId];
        _requireVerifiable(orderId, o);

        o.status = Status.Verified;
        o.reportHash = reportHash;
        emit OrderVerified(orderId, msg.sender, reportHash, reportURI);
    }

    /// @notice Pays the seller and records `passed = true` feedback. Callable by the verifier, or by
    ///         the payee so settlement does not depend on verifier liveness once verified.
    function release(uint256 orderId) external nonReentrant {
        Order storage o = _orders[orderId];
        _requireStatus(orderId, o, Status.Verified);
        if (msg.sender != o.verifier && msg.sender != o.payee) revert NotReleaser(orderId, msg.sender);

        o.status = Status.Released;
        _recordFulfillment(orderId, o, true, o.deliveredAt <= o.deliverBy);
        // forge-lint: disable-next-line(reentrancy-events)
        emit OrderReleased(orderId, o.payee, o.amount);

        paymentToken.safeTransfer(o.payee, o.amount);
    }

    /// @notice Delivery does not meet the spec: refund the buyer and record `passed = false` feedback.
    function fail(uint256 orderId, bytes32 reportHash, string calldata reportURI) external nonReentrant {
        Order storage o = _orders[orderId];
        _requireVerifiable(orderId, o);

        o.status = Status.Refunded;
        o.reportHash = reportHash;
        _recordFulfillment(orderId, o, false, o.deliveredAt <= o.deliverBy);
        // forge-lint: disable-next-line(reentrancy-events)
        emit OrderRefunded(orderId, o.buyer, o.amount, RefundReason.Failed, reportHash, reportURI);

        paymentToken.safeTransfer(o.buyer, o.amount);
    }

    // ---------------------------------------------------------------------
    // Anyone
    // ---------------------------------------------------------------------

    /// @notice Timeout refund to the buyer.
    ///         - Funded past `deliverBy`: the seller agreed but never delivered -> `passed = false,
    ///           on_time = false` feedback.
    ///         - Delivered past the verify window: the verifier never ruled -> no feedback, since the
    ///           seller is not at fault.
    function refundExpired(uint256 orderId) external nonReentrant {
        Order storage o = _orders[orderId];
        RefundReason reason;
        if (o.status == Status.Funded && block.timestamp > o.deliverBy) {
            reason = RefundReason.NotDelivered;
        } else if (o.status == Status.Delivered && block.timestamp > _verifyDeadline(o)) {
            reason = RefundReason.NotVerified;
        } else {
            revert NotRefundable(orderId);
        }

        o.status = Status.Refunded;
        if (reason == RefundReason.NotDelivered) _recordFulfillment(orderId, o, false, false);
        // forge-lint: disable-next-line(reentrancy-events)
        emit OrderRefunded(orderId, o.buyer, o.amount, reason, bytes32(0), "");

        paymentToken.safeTransfer(o.buyer, o.amount);
    }

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    function getOrder(uint256 orderId) external view returns (Order memory) {
        return _orders[orderId];
    }

    /// @notice Last timestamp at which the verifier may act; 0 until delivered.
    function verifyDeadline(uint256 orderId) external view returns (uint64) {
        Order storage o = _orders[orderId];
        return o.deliveredAt == 0 ? 0 : _verifyDeadline(o);
    }

    function isRefundable(uint256 orderId) external view returns (bool) {
        Order storage o = _orders[orderId];
        return (o.status == Status.Funded && block.timestamp > o.deliverBy)
            || (o.status == Status.Delivered && block.timestamp > _verifyDeadline(o));
    }

    /// @notice Hash helper so on-chain and off-chain code agree on the spec commitment.
    function hashSpec(bytes calldata canonicalSpecJson) external pure returns (bytes32) {
        return keccak256(canonicalSpecJson);
    }

    /// @notice The ERC-8004 feedback file this escrow would publish for `orderId` with the given outcome.
    function previewFeedback(uint256 orderId, bool passed, bool onTime) external view returns (string memory json) {
        Order storage o = _orders[orderId];
        _requireExists(orderId, o);
        return FulfillmentFeedback.toJson(_feedbackData(orderId, o, passed, onTime));
    }

    // ---------------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------------

    function _verifyDeadline(Order storage o) private view returns (uint64) {
        return o.deliveredAt + o.verifyWindow;
    }

    function _requireVerifiable(uint256 orderId, Order storage o) private view {
        _requireStatus(orderId, o, Status.Delivered);
        if (msg.sender != o.verifier) revert NotVerifier(orderId, msg.sender);
        uint64 deadline = _verifyDeadline(o);
        if (block.timestamp > deadline) revert VerificationWindowClosed(orderId, deadline);
    }

    function _requireStatus(uint256 orderId, Order storage o, Status expected) private view {
        if (o.status != expected) revert InvalidStatus(orderId, o.status, expected);
    }

    function _requireExists(uint256 orderId, Order storage o) private view {
        if (o.status == Status.None) revert InvalidStatus(orderId, Status.None, Status.Created);
    }

    function _isSeller(Order storage o, address account) private view returns (bool) {
        if (account == o.payee) return true;
        IERC721 identity = IERC721(address(identityRegistry));
        address owner = identity.ownerOf(o.sellerAgentId);
        return account == owner || identity.isApprovedForAll(owner, account)
            || identity.getApproved(o.sellerAgentId) == account;
    }

    function _feedbackData(uint256 orderId, Order storage o, bool passed, bool onTime)
        private
        view
        returns (FulfillmentFeedback.Data memory)
    {
        return FulfillmentFeedback.Data({
            chainId: block.chainid,
            identityRegistry: address(identityRegistry),
            agentId: o.sellerAgentId,
            clientAddress: address(this),
            createdAt: block.timestamp,
            value: passed ? PASSED_VALUE : FAILED_VALUE,
            taskType: o.taskType,
            onTime: onTime,
            passed: passed,
            orderId: orderId,
            token: address(paymentToken),
            amount: o.amount,
            specHash: o.specHash,
            deliveryHash: o.deliveryHash,
            reportHash: o.reportHash
        });
    }

    /// @dev Writes ERC-8004 feedback: value = passed ? 100 : 0, tag1 = task_type, tag2 = on_time|late,
    ///      feedbackURI = on-chain JSON (data URI) carrying task_type, amount, passed, on_time.
    ///      Reputation must never block settlement (e.g. if the seller approves this contract as an
    ///      operator, ERC-8004 forbids it from leaving feedback), so failures are caught and emitted.
    ///      The registry is immutable and set at deployment, and every caller holds `nonReentrant`.
    function _recordFulfillment(uint256 orderId, Order storage o, bool passed, bool onTime) private {
        FulfillmentFeedback.Data memory data = _feedbackData(orderId, o, passed, onTime);
        string memory json = FulfillmentFeedback.toJson(data);
        bytes32 feedbackHash = keccak256(bytes(json));
        uint256 agentId = o.sellerAgentId;

        // forge-lint: disable-next-item(reentrancy-no-eth)
        try reputationRegistry.giveFeedback(
            agentId,
            data.value,
            0,
            o.taskType,
            FulfillmentFeedback.onTimeTag(onTime),
            "",
            FulfillmentFeedback.toDataURI(json),
            feedbackHash
        ) {
            // forge-lint: disable-next-line(reentrancy-no-eth)
            uint64 feedbackIndex = reputationRegistry.getLastIndex(agentId, address(this));
            o.feedbackIndex = feedbackIndex;
            // forge-lint: disable-next-line(reentrancy-events)
            emit FulfillmentRecorded(orderId, agentId, feedbackIndex, passed, onTime, feedbackHash);
        } catch (bytes memory reason) {
            // forge-lint: disable-next-line(reentrancy-events)
            emit ReputationWriteFailed(orderId, agentId, reason);
        }
    }
}
