import { parseAbi } from "viem";

export const taskEscrowAbi = parseAbi([
  "function createOrder((uint256 sellerAgentId, uint256 buyerAgentId, address verifier, uint256 amount, bytes32 specHash, string specURI, string taskType, uint64 deliverBy, uint32 reviewWindow, uint8 approvalMode) params) external returns (uint256 orderId)",
  "function agree(uint256 orderId, bytes32 specHash) external",
  "function fund(uint256 orderId) external",
  "function submitDelivery(uint256 orderId, bytes32 deliveryHash, string deliveryURI) external",
  "function release(uint256 orderId, bytes32 resultHash, string resultURI) external",
  "function fail(uint256 orderId, bytes32 resultHash, string resultURI) external",
  "function approve(uint256 orderId) external",
  "function refundExpired(uint256 orderId) external",
  "function getOrder(uint256 orderId) external view returns ((address buyer, uint64 deliverBy, uint8 status, uint8 approvalMode, bool passed, address payee, uint64 deliveredAt, address verifier, uint64 verifiedAt, uint32 reviewWindow, uint64 sellerFeedbackIndex, uint64 buyerFeedbackIndex, uint256 sellerAgentId, uint256 buyerAgentId, uint256 amount, bytes32 specHash, bytes32 deliveryHash, bytes32 resultHash, string deliveryURI, string taskType))",
  "function hashSpec(bytes canonicalSpecJson) external pure returns (bytes32)",
  "function nextOrderId() external view returns (uint256)",
  "event OrderCreated(uint256 indexed orderId, address indexed buyer, uint256 indexed sellerAgentId, uint256 buyerAgentId, address payee, address verifier, uint256 amount, bytes32 specHash, string specURI, string taskType, uint64 deliverBy, uint32 reviewWindow, uint8 approvalMode)",
  "event OrderAgreed(uint256 indexed orderId, address indexed seller, bytes32 specHash)",
  "event OrderFunded(uint256 indexed orderId, address indexed buyer, uint256 amount)",
  "event OrderDelivered(uint256 indexed orderId, address indexed submitter, bytes32 deliveryHash, string deliveryURI, bool onTime)",
  "event OrderVerified(uint256 indexed orderId, address indexed verifier, bool passed, bytes32 resultHash, string resultURI)",
  "event OrderReleased(uint256 indexed orderId, address indexed payee, uint256 amount, address releasedBy)",
  "event OrderRefunded(uint256 indexed orderId, address indexed buyer, uint256 amount, uint8 reason)",
]);

export const identityRegistryAbi = parseAbi([
  "function register(string agentURI) external returns (uint256 agentId)",
  "function ownerOf(uint256 tokenId) external view returns (address)",
  "function getAgentWallet(uint256 agentId) external view returns (address)",
  "event Registered(uint256 indexed agentId, string agentURI, address indexed owner)",
]);

export const erc20Abi = parseAbi([
  "function approve(address spender, uint256 amount) external returns (bool)",
  "function balanceOf(address account) external view returns (uint256)",
  "function mint(address to, uint256 amount) external",
]);

export const reputationRegistryAbi = parseAbi([
  "function getSummary(uint256 agentId, address[] clientAddresses, string tag1, string tag2) external view returns (uint64 count, int128 summaryValue, uint8 decimals)",
]);
