// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface ITaskEscrow {
    /// @dev Happy path: Created -> Agreed -> Funded -> Delivered -> Verified -> Released.
    ///      Refunded is reachable from Funded / Delivered (timeout or failed verification).
    ///      `Disputed` is reserved for a future arbitration module and is never entered.
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

    enum RefundReason {
        Failed,
        NotDelivered,
        NotVerified
    }

    struct Order {
        address buyer;
        uint64 deliverBy;
        Status status;
        address payee;
        uint64 deliveredAt;
        address verifier;
        uint32 verifyWindow;
        uint64 feedbackIndex;
        uint256 sellerAgentId;
        uint256 amount;
        bytes32 specHash;
        bytes32 deliveryHash;
        bytes32 reportHash;
        string deliveryURI;
        string taskType;
    }

    event OrderCreated(
        uint256 indexed orderId,
        address indexed buyer,
        uint256 indexed sellerAgentId,
        address payee,
        address verifier,
        uint256 amount,
        bytes32 specHash,
        string specURI,
        string taskType,
        uint64 deliverBy,
        uint32 verifyWindow
    );
    event OrderAgreed(uint256 indexed orderId, address indexed seller);
    event OrderFunded(uint256 indexed orderId, address indexed buyer, uint256 amount);
    event OrderDelivered(
        uint256 indexed orderId, address indexed submitter, bytes32 deliveryHash, string deliveryURI, bool onTime
    );
    event OrderVerified(uint256 indexed orderId, address indexed verifier, bytes32 reportHash, string reportURI);
    event OrderReleased(uint256 indexed orderId, address indexed payee, uint256 amount);
    event OrderRefunded(
        uint256 indexed orderId,
        address indexed buyer,
        uint256 amount,
        RefundReason reason,
        bytes32 reportHash,
        string reportURI
    );
    /// @notice An ERC-8004 feedback entry was written for the seller agent.
    event FulfillmentRecorded(
        uint256 indexed orderId,
        uint256 indexed sellerAgentId,
        uint64 feedbackIndex,
        bool passed,
        bool onTime,
        bytes32 feedbackHash
    );
    /// @notice Settlement never blocks on reputation; a failed feedback write is surfaced here instead.
    event ReputationWriteFailed(uint256 indexed orderId, uint256 indexed sellerAgentId, bytes reason);

    error ZeroAddress();
    error ZeroAmount();
    error ZeroHash();
    error EmptyURI();
    error InvalidTaskType(string taskType);
    error InvalidDeadline(uint64 deliverBy);
    error InvalidVerifyWindow(uint32 verifyWindow);
    error InvalidVerifier(address verifier);
    error SelfDealing(address buyer);
    error InvalidStatus(uint256 orderId, Status current, Status expected);
    error NotBuyer(uint256 orderId, address caller);
    error NotSeller(uint256 orderId, address caller);
    error NotVerifier(uint256 orderId, address caller);
    error NotReleaser(uint256 orderId, address caller);
    error OrderExpired(uint256 orderId, uint64 deliverBy);
    error VerificationWindowClosed(uint256 orderId, uint64 verifyDeadline);
    error NotRefundable(uint256 orderId);
    error UnexpectedTransferAmount(uint256 expected, uint256 received);

    function createOrder(
        uint256 sellerAgentId,
        address verifier,
        uint256 amount,
        bytes32 specHash,
        string calldata specURI,
        string calldata taskType,
        uint64 deliverBy,
        uint32 verifyWindow
    ) external returns (uint256 orderId);

    function agree(uint256 orderId) external;

    function fund(uint256 orderId) external;

    function submitDelivery(uint256 orderId, bytes32 deliveryHash, string calldata deliveryURI) external;

    function verify(uint256 orderId, bytes32 reportHash, string calldata reportURI) external;

    function release(uint256 orderId) external;

    function fail(uint256 orderId, bytes32 reportHash, string calldata reportURI) external;

    function refundExpired(uint256 orderId) external;

    function getOrder(uint256 orderId) external view returns (Order memory);

    function verifyDeadline(uint256 orderId) external view returns (uint64);

    function isRefundable(uint256 orderId) external view returns (bool);
}
