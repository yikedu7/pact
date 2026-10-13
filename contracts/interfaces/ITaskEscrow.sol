// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice State machine (docs/PRODUCT_SPEC.md):
///         Created -> Agreed (spec frozen) -> Funded -> Delivered -> Verified(pass/fail) -> Released / Refunded
///         plus timeout refunds. `Disputed` is reserved for a future arbitration module and is never entered.
interface ITaskEscrow {
    enum Status {
        None,
        Created,
        Agreed,
        Funded,
        Delivered,
        Verified,
        Released,
        Refunded,
        Disputed
    }

    /// @dev `User`: after a pass the buyer must `approve` (or the review window lapses).
    ///      `ApproveForMe`: a pass from the verifier releases funds immediately.
    enum ApprovalMode {
        User,
        ApproveForMe
    }

    enum RefundReason {
        Failed,
        NotDelivered,
        NotVerified
    }

    enum Role {
        Expert,
        Buyer
    }

    struct OrderParams {
        uint256 sellerAgentId;
        uint256 buyerAgentId;
        address verifier;
        uint256 amount;
        bytes32 specHash;
        string specURI;
        string taskType;
        uint64 deliverBy;
        uint32 reviewWindow;
        ApprovalMode approvalMode;
    }

    struct Order {
        address buyer;
        uint64 deliverBy;
        Status status;
        ApprovalMode approvalMode;
        bool passed;
        address payee;
        uint64 deliveredAt;
        address verifier;
        uint64 verifiedAt;
        uint32 reviewWindow;
        uint64 sellerFeedbackIndex;
        uint64 buyerFeedbackIndex;
        uint256 sellerAgentId;
        uint256 buyerAgentId;
        uint256 amount;
        bytes32 specHash;
        bytes32 deliveryHash;
        bytes32 resultHash;
        string deliveryURI;
        string taskType;
    }

    event OrderCreated(
        uint256 indexed orderId,
        address indexed buyer,
        uint256 indexed sellerAgentId,
        uint256 buyerAgentId,
        address payee,
        address verifier,
        uint256 amount,
        bytes32 specHash,
        string specURI,
        string taskType,
        uint64 deliverBy,
        uint32 reviewWindow,
        ApprovalMode approvalMode
    );
    event OrderAgreed(uint256 indexed orderId, address indexed seller, bytes32 specHash);
    event OrderFunded(uint256 indexed orderId, address indexed buyer, uint256 amount);
    event OrderDelivered(
        uint256 indexed orderId, address indexed submitter, bytes32 deliveryHash, string deliveryURI, bool onTime
    );
    event OrderVerified(
        uint256 indexed orderId, address indexed verifier, bool passed, bytes32 resultHash, string resultURI
    );
    event OrderReleased(uint256 indexed orderId, address indexed payee, uint256 amount, address releasedBy);
    event OrderRefunded(uint256 indexed orderId, address indexed buyer, uint256 amount, RefundReason reason);
    /// @notice An ERC-8004 feedback entry was written for `agentId` acting as `role` in this order.
    event FulfillmentRecorded(
        uint256 indexed orderId,
        uint256 indexed agentId,
        Role role,
        uint64 feedbackIndex,
        bool passed,
        bool onTime,
        bytes32 feedbackHash
    );
    /// @notice Settlement never blocks on reputation; a failed feedback write is surfaced here instead.
    event ReputationWriteFailed(uint256 indexed orderId, uint256 indexed agentId, Role role, bytes reason);

    error ZeroAddress();
    error ZeroAmount();
    error ZeroHash();
    error EmptyURI();
    error InvalidTaskType(string taskType);
    error InvalidDeadline(uint64 deliverBy);
    error InvalidReviewWindow(uint32 reviewWindow);
    error InvalidVerifier(address verifier);
    error InvalidBuyerAgent(uint256 buyerAgentId);
    error SelfDealing(address buyer);
    error SpecMismatch(bytes32 expected, bytes32 provided);
    error InvalidStatus(uint256 orderId, Status current, Status expected);
    error NotBuyer(uint256 orderId, address caller);
    error NotSeller(uint256 orderId, address caller);
    error NotVerifier(uint256 orderId, address caller);
    error OrderExpired(uint256 orderId, uint64 deliverBy);
    error ReviewWindowClosed(uint256 orderId, uint64 deadline);
    error ReviewWindowOpen(uint256 orderId, uint64 deadline);
    error NotRefundable(uint256 orderId);
    error UnexpectedTransferAmount(uint256 expected, uint256 received);

    function createOrder(OrderParams calldata params) external returns (uint256 orderId);

    function agree(uint256 orderId, bytes32 specHash) external;

    function fund(uint256 orderId) external;

    function submitDelivery(uint256 orderId, bytes32 deliveryHash, string calldata deliveryURI) external;

    function release(uint256 orderId, bytes32 resultHash, string calldata resultURI) external;

    function fail(uint256 orderId, bytes32 resultHash, string calldata resultURI) external;

    function approve(uint256 orderId) external;

    function releaseExpired(uint256 orderId) external;

    function refundExpired(uint256 orderId) external;

    function getOrder(uint256 orderId) external view returns (Order memory);

    function reviewDeadline(uint256 orderId) external view returns (uint64);

    function isRefundable(uint256 orderId) external view returns (bool);
}
