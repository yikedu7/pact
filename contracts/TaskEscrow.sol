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
/// @notice Agent-to-agent task escrow with ERC-8004 reputation (docs/PRODUCT_SPEC.md).
///
///         createOrder            buyer     -> Created
///         agree(specHash)        expert    Created   -> Agreed     (spec hash frozen)
///         fund                   buyer     Agreed    -> Funded
///         submitDelivery         expert    Funded    -> Delivered  (content hash + URI only)
///         release                verifier  Delivered -> Verified(pass) [-> Released if approve_for_me]
///         fail                   verifier  Delivered -> Verified(fail) -> Refunded
///         approve                buyer     Verified  -> Released   (approval_mode = user)
///         releaseExpired         anyone    Verified  -> Released   (buyer silent past review window)
///         refundExpired          anyone    Funded    -> Refunded   (nothing delivered by deliverBy)
///                                          Delivered -> Refunded   (verifier silent past review window)
///
///         Each settled order writes ERC-8004 feedback (task_type, amount, passed, on_time) for the
///         expert and, if registered, the buyer agent, with this contract as `clientAddress`.
/// @dev    TESTNET MVP. No admin, no fees, no upgradability. `Disputed` is reserved and never entered.
contract TaskEscrow is ITaskEscrow, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice ERC-8004 feedback `value` (0 decimals): `getSummary` then yields a pass rate in percent.
    int128 public constant PASSED_VALUE = 100;
    int128 public constant FAILED_VALUE = 0;

    IERC20 public immutable paymentToken;
    IIdentityRegistry public immutable identityRegistry;
    IReputationRegistry public immutable reputationRegistry;
    /// @notice Protocol-provided verifier bot used when an order does not designate its own.
    address public immutable defaultVerifier;

    uint256 public nextOrderId = 1;

    mapping(uint256 orderId => Order) private _orders;

    error RegistryMismatch(address expected, address actual);

    constructor(
        IERC20 paymentToken_,
        IIdentityRegistry identityRegistry_,
        IReputationRegistry reputationRegistry_,
        address defaultVerifier_
    ) {
        if (
            address(paymentToken_) == address(0) || address(identityRegistry_) == address(0)
                || address(reputationRegistry_) == address(0) || defaultVerifier_ == address(0)
        ) revert ZeroAddress();
        address linked = reputationRegistry_.getIdentityRegistry();
        if (linked != address(identityRegistry_)) revert RegistryMismatch(address(identityRegistry_), linked);

        paymentToken = paymentToken_;
        identityRegistry = identityRegistry_;
        reputationRegistry = reputationRegistry_;
        defaultVerifier = defaultVerifier_;
    }

    // ---------------------------------------------------------------------
    // Buyer
    // ---------------------------------------------------------------------

    /// @notice Proposes an order. Nothing is escrowed until the expert agrees and the buyer funds.
    /// @dev    `params.specHash` is keccak256 of the canonicalized (RFC 8785) delivery-criteria JSON.
    ///         `params.buyerAgentId` is optional (0 = unregistered buyer, no buyer-side feedback).
    ///         `params.verifier` is optional (0 = `defaultVerifier`).
    function createOrder(OrderParams calldata params) external returns (uint256 orderId) {
        if (params.amount == 0) revert ZeroAmount();
        if (params.specHash == bytes32(0)) revert ZeroHash();
        if (!FulfillmentFeedback.isValidTaskType(params.taskType)) revert InvalidTaskType(params.taskType);
        if (params.deliverBy <= block.timestamp) revert InvalidDeadline(params.deliverBy);
        if (params.reviewWindow == 0) revert InvalidReviewWindow(params.reviewWindow);

        address agentOwner = IERC721(address(identityRegistry)).ownerOf(params.sellerAgentId);
        address payee = identityRegistry.getAgentWallet(params.sellerAgentId);
        if (payee == address(0)) payee = agentOwner;
        if (msg.sender == payee || msg.sender == agentOwner) revert SelfDealing(msg.sender);

        if (
            params.buyerAgentId != 0
                && (params.buyerAgentId == params.sellerAgentId || !_controlsAgent(params.buyerAgentId, msg.sender))
        ) revert InvalidBuyerAgent(params.buyerAgentId);

        address verifier = params.verifier == address(0) ? defaultVerifier : params.verifier;
        if (verifier == msg.sender || verifier == payee || verifier == agentOwner) revert InvalidVerifier(verifier);

        orderId = nextOrderId++;
        Order storage o = _orders[orderId];
        o.buyer = msg.sender;
        o.deliverBy = params.deliverBy;
        o.status = Status.Created;
        o.approvalMode = params.approvalMode;
        o.payee = payee;
        o.verifier = verifier;
        o.reviewWindow = params.reviewWindow;
        o.sellerAgentId = params.sellerAgentId;
        o.buyerAgentId = params.buyerAgentId;
        o.amount = params.amount;
        o.specHash = params.specHash;
        o.taskType = params.taskType;

        emit OrderCreated(
            orderId,
            msg.sender,
            params.sellerAgentId,
            params.buyerAgentId,
            payee,
            verifier,
            params.amount,
            params.specHash,
            params.specURI,
            params.taskType,
            params.deliverBy,
            params.reviewWindow,
            params.approvalMode
        );
    }

    /// @notice Pulls `amount` of `paymentToken` from the buyer into escrow once the expert agreed.
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

    /// @notice User approval after a verifier pass (`approval_mode = user`). Approving after the review
    ///         window is still accepted but recorded as late for the buyer.
    function approve(uint256 orderId) external nonReentrant {
        Order storage o = _orders[orderId];
        _requireStatus(orderId, o, Status.Verified);
        if (msg.sender != o.buyer) revert NotBuyer(orderId, msg.sender);
        _release(orderId, o, block.timestamp <= o.verifiedAt + o.reviewWindow);
    }

    // ---------------------------------------------------------------------
    // Expert (seller)
    // ---------------------------------------------------------------------

    /// @notice Expert accepts the order terms. `specHash` must equal the proposed hash, which freezes it.
    function agree(uint256 orderId, bytes32 specHash) external {
        Order storage o = _orders[orderId];
        _requireStatus(orderId, o, Status.Created);
        if (!_isSeller(o, msg.sender)) revert NotSeller(orderId, msg.sender);
        if (specHash != o.specHash) revert SpecMismatch(o.specHash, specHash);
        if (block.timestamp > o.deliverBy) revert OrderExpired(orderId, o.deliverBy);

        o.status = Status.Agreed;
        emit OrderAgreed(orderId, msg.sender, specHash);
    }

    /// @notice Commits to a delivery by content hash + URI (the artifact itself stays off-chain).
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

    /// @notice Verdict: delivery passes every acceptance criterion. Releases immediately when the order
    ///         is `ApproveForMe`; otherwise waits in `Verified` for the buyer's `approve`.
    /// @param resultHash keccak256 of the structured per-criterion verification result JSON.
    function release(uint256 orderId, bytes32 resultHash, string calldata resultURI) external nonReentrant {
        Order storage o = _orders[orderId];
        _recordVerdict(orderId, o, true, resultHash, resultURI);
        if (o.approvalMode == ApprovalMode.ApproveForMe) _release(orderId, o, true);
    }

    /// @notice Verdict: delivery fails the spec. Refunds the buyer.
    function fail(uint256 orderId, bytes32 resultHash, string calldata resultURI) external nonReentrant {
        Order storage o = _orders[orderId];
        _recordVerdict(orderId, o, false, resultHash, resultURI);
        _refund(orderId, o, RefundReason.Failed);
    }

    // ---------------------------------------------------------------------
    // Anyone (keepers)
    // ---------------------------------------------------------------------

    /// @notice Pays the expert when a passed order was not approved within the review window.
    function releaseExpired(uint256 orderId) external nonReentrant {
        Order storage o = _orders[orderId];
        _requireStatus(orderId, o, Status.Verified);
        uint64 deadline = o.verifiedAt + o.reviewWindow;
        if (block.timestamp <= deadline) revert ReviewWindowOpen(orderId, deadline);
        _release(orderId, o, false);
    }

    /// @notice Timeout refund to the buyer:
    ///         - Funded past `deliverBy`: the expert never delivered (expert feedback: failed, late).
    ///         - Delivered past the review window: the verifier never ruled (no expert feedback, since
    ///           the expert is not at fault).
    function refundExpired(uint256 orderId) external nonReentrant {
        Order storage o = _orders[orderId];
        if (o.status == Status.Funded && block.timestamp > o.deliverBy) {
            _refund(orderId, o, RefundReason.NotDelivered);
        } else if (o.status == Status.Delivered && block.timestamp > o.deliveredAt + o.reviewWindow) {
            _refund(orderId, o, RefundReason.NotVerified);
        } else {
            revert NotRefundable(orderId);
        }
    }

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    function getOrder(uint256 orderId) external view returns (Order memory) {
        return _orders[orderId];
    }

    /// @notice End of the current review window: the verifier's (Delivered) or the buyer's (Verified).
    ///         0 in any other state.
    function reviewDeadline(uint256 orderId) public view returns (uint64) {
        Order storage o = _orders[orderId];
        if (o.status == Status.Delivered) return o.deliveredAt + o.reviewWindow;
        if (o.status == Status.Verified) return o.verifiedAt + o.reviewWindow;
        return 0;
    }

    function isRefundable(uint256 orderId) external view returns (bool) {
        Order storage o = _orders[orderId];
        return (o.status == Status.Funded && block.timestamp > o.deliverBy)
            || (o.status == Status.Delivered && block.timestamp > reviewDeadline(orderId));
    }

    function isReleasable(uint256 orderId) external view returns (bool) {
        return _orders[orderId].status == Status.Verified && block.timestamp > reviewDeadline(orderId);
    }

    /// @notice Hash helper so on-chain and off-chain code agree on the spec commitment.
    function hashSpec(bytes calldata canonicalSpecJson) external pure returns (bytes32) {
        return keccak256(canonicalSpecJson);
    }

    /// @notice The ERC-8004 feedback file this escrow would publish right now for `orderId`.
    function previewFeedback(uint256 orderId, Role role, bool passed, bool onTime, bool released)
        external
        view
        returns (string memory json)
    {
        Order storage o = _orders[orderId];
        if (o.status == Status.None) revert InvalidStatus(orderId, Status.None, Status.Created);
        uint256 agentId = role == Role.Expert ? o.sellerAgentId : o.buyerAgentId;
        return FulfillmentFeedback.toJson(_feedbackData(orderId, o, agentId, role, passed, onTime, released));
    }

    // ---------------------------------------------------------------------
    // Internals: transitions
    // ---------------------------------------------------------------------

    function _recordVerdict(
        uint256 orderId,
        Order storage o,
        bool passed,
        bytes32 resultHash,
        string calldata resultURI
    ) private {
        _requireStatus(orderId, o, Status.Delivered);
        if (msg.sender != o.verifier) revert NotVerifier(orderId, msg.sender);
        uint64 deadline = o.deliveredAt + o.reviewWindow;
        if (block.timestamp > deadline) revert ReviewWindowClosed(orderId, deadline);
        if (resultHash == bytes32(0)) revert ZeroHash();

        o.status = Status.Verified;
        o.passed = passed;
        // forge-lint: disable-next-line(unsafe-typecast)
        o.verifiedAt = uint64(block.timestamp);
        o.resultHash = resultHash;
        emit OrderVerified(orderId, msg.sender, passed, resultHash, resultURI);
    }

    function _release(uint256 orderId, Order storage o, bool buyerOnTime) private {
        o.status = Status.Released;
        _recordFulfillment(orderId, o, Role.Expert, true, o.deliveredAt <= o.deliverBy, true);
        _recordFulfillment(orderId, o, Role.Buyer, true, buyerOnTime, true);
        // forge-lint: disable-next-line(reentrancy-events)
        emit OrderReleased(orderId, o.payee, o.amount, msg.sender);

        paymentToken.safeTransfer(o.payee, o.amount);
    }

    function _refund(uint256 orderId, Order storage o, RefundReason reason) private {
        o.status = Status.Refunded;
        if (reason == RefundReason.Failed) {
            _recordFulfillment(orderId, o, Role.Expert, false, o.deliveredAt <= o.deliverBy, false);
        } else if (reason == RefundReason.NotDelivered) {
            _recordFulfillment(orderId, o, Role.Expert, false, false, false);
        }
        _recordFulfillment(orderId, o, Role.Buyer, true, true, false);
        // forge-lint: disable-next-line(reentrancy-events)
        emit OrderRefunded(orderId, o.buyer, o.amount, reason);

        paymentToken.safeTransfer(o.buyer, o.amount);
    }

    // ---------------------------------------------------------------------
    // Internals: reputation
    // ---------------------------------------------------------------------

    /// @dev Writes ERC-8004 feedback with value = passed ? 100 : 0, tag1 = role ("expert" | "buyer"),
    ///      tag2 = task_type, and feedbackURI = on-chain JSON (data URI) carrying task_type, amount,
    ///      passed and on_time. Reputation must never block settlement (e.g. if an agent approves this
    ///      contract as an operator, ERC-8004 forbids it from leaving feedback), so failures are caught
    ///      and emitted. The registry is immutable and set at deployment, and every caller holds
    ///      `nonReentrant`.
    function _recordFulfillment(uint256 orderId, Order storage o, Role role, bool passed, bool onTime, bool released)
        private
    {
        uint256 agentId = role == Role.Expert ? o.sellerAgentId : o.buyerAgentId;
        if (agentId == 0) return;

        FulfillmentFeedback.Data memory data = _feedbackData(orderId, o, agentId, role, passed, onTime, released);
        string memory json = FulfillmentFeedback.toJson(data);
        bytes32 feedbackHash = keccak256(bytes(json));

        // forge-lint: disable-next-item(reentrancy-no-eth)
        try reputationRegistry.giveFeedback(
            agentId, data.value, 0, data.role, o.taskType, "", FulfillmentFeedback.toDataURI(json), feedbackHash
        ) {
            // forge-lint: disable-next-line(reentrancy-no-eth)
            uint64 feedbackIndex = reputationRegistry.getLastIndex(agentId, address(this));
            if (role == Role.Expert) o.sellerFeedbackIndex = feedbackIndex;
            else o.buyerFeedbackIndex = feedbackIndex;
            // forge-lint: disable-next-line(reentrancy-events)
            emit FulfillmentRecorded(orderId, agentId, role, feedbackIndex, passed, onTime, feedbackHash);
        } catch (bytes memory reason) {
            // forge-lint: disable-next-line(reentrancy-events)
            emit ReputationWriteFailed(orderId, agentId, role, reason);
        }
    }

    function _feedbackData(
        uint256 orderId,
        Order storage o,
        uint256 agentId,
        Role role,
        bool passed,
        bool onTime,
        bool released
    ) private view returns (FulfillmentFeedback.Data memory) {
        return FulfillmentFeedback.Data({
            chainId: block.chainid,
            identityRegistry: address(identityRegistry),
            agentId: agentId,
            clientAddress: address(this),
            createdAt: block.timestamp,
            value: passed ? PASSED_VALUE : FAILED_VALUE,
            role: role == Role.Expert ? "expert" : "buyer",
            taskType: o.taskType,
            outcome: released ? "released" : "refunded",
            passed: passed,
            onTime: onTime,
            orderId: orderId,
            token: address(paymentToken),
            amount: o.amount,
            specHash: o.specHash,
            deliveryHash: o.deliveryHash,
            resultHash: o.resultHash
        });
    }

    // ---------------------------------------------------------------------
    // Internals: access
    // ---------------------------------------------------------------------

    function _requireStatus(uint256 orderId, Order storage o, Status expected) private view {
        if (o.status != expected) revert InvalidStatus(orderId, o.status, expected);
    }

    function _isSeller(Order storage o, address account) private view returns (bool) {
        return account == o.payee || _controlsAgent(o.sellerAgentId, account);
    }

    /// @dev Agent wallet, owner, or an ERC-721 approved operator of `agentId`.
    function _controlsAgent(uint256 agentId, address account) private view returns (bool) {
        if (account == identityRegistry.getAgentWallet(agentId)) return true;
        IERC721 identity = IERC721(address(identityRegistry));
        address owner = identity.ownerOf(agentId);
        return account == owner || identity.isApprovedForAll(owner, account) || identity.getApproved(agentId) == account;
    }
}
