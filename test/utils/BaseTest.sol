// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {TaskEscrow} from "../../contracts/TaskEscrow.sol";
import {IIdentityRegistry} from "../../contracts/interfaces/IIdentityRegistry.sol";
import {IReputationRegistry} from "../../contracts/interfaces/IReputationRegistry.sol";
import {ITaskEscrow} from "../../contracts/interfaces/ITaskEscrow.sol";
import {MockUSDC} from "../../contracts/mocks/MockUSDC.sol";
import {IdentityRegistry} from "../../contracts/registries/IdentityRegistry.sol";
import {ReputationRegistry} from "../../contracts/registries/ReputationRegistry.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test} from "forge-std/Test.sol";

abstract contract BaseTest is Test {
    MockUSDC internal usdc;
    IdentityRegistry internal identity;
    ReputationRegistry internal reputation;
    TaskEscrow internal escrow;

    address internal buyer = makeAddr("buyer");
    address internal verifier = makeAddr("verifier");
    address internal stranger = makeAddr("stranger");
    address internal sellerOwner;
    uint256 internal sellerOwnerKey;
    uint256 internal sellerAgentId;
    uint256 internal buyerAgentId;

    uint256 internal constant PRICE = 5e6; // 5 mUSDC, as in the PRODUCT_SPEC demo
    uint256 internal constant BUYER_BALANCE = 1_000e6;
    uint32 internal constant REVIEW_WINDOW = 1 hours;
    uint256 internal constant START_TIME = 1_700_000_000; // 2023-11-14T22:13:20Z

    /// @dev RFC 8785 (JCS) canonical form of the PRODUCT_SPEC criteria template for the logo demo.
    string internal constant SPEC_JSON = unicode'{"acceptance_criteria":[{"check":"file_format == png && size >= 1024",'
        unicode'"id":"c1","type":"auto"},{"check":"包含文字 \'Guild\'，风格简洁","id":"c2","type":"llm"}],'
        unicode'"approval_mode":"user","deadline":"2023-11-15T22:13:20Z","deliverables":[{"count":3,'
        unicode'"kind":"image/png","min_size":"1024x1024"}],"price":{"amount":"5","token":"USDC"},"revisions":1,'
        unicode'"task_type":"design.logo","title":"Guild logo"}';
    bytes32 internal SPEC_HASH = keccak256(bytes(SPEC_JSON));
    string internal constant SPEC_URI = "ipfs://bafyspec";
    string internal constant TASK_TYPE = "design.logo";
    bytes32 internal constant DELIVERY_HASH = keccak256("delivery-manifest");
    string internal constant DELIVERY_URI = "ipfs://bafydelivery";
    bytes32 internal constant RESULT_HASH = keccak256("verification-result");
    string internal constant RESULT_URI = "ipfs://bafyresult";

    uint64 internal deliverBy;

    function setUp() public virtual {
        vm.warp(START_TIME);
        usdc = new MockUSDC();
        identity = new IdentityRegistry();
        reputation = new ReputationRegistry(address(identity));
        escrow = new TaskEscrow(
            IERC20(address(usdc)),
            IIdentityRegistry(address(identity)),
            IReputationRegistry(address(reputation)),
            verifier
        );

        (sellerOwner, sellerOwnerKey) = makeAddrAndKey("sellerOwner");
        vm.prank(sellerOwner);
        sellerAgentId = identity.register("ipfs://expert-agent.json");
        vm.prank(buyer);
        buyerAgentId = identity.register("ipfs://buyer-agent.json");

        usdc.mint(buyer, BUYER_BALANCE);
        vm.prank(buyer);
        usdc.approve(address(escrow), type(uint256).max);

        deliverBy = uint64(vm.getBlockTimestamp() + 24 hours);
    }

    // ---------------------------------------------------------------------
    // Lifecycle helpers
    // ---------------------------------------------------------------------

    function _params() internal view returns (ITaskEscrow.OrderParams memory) {
        return ITaskEscrow.OrderParams({
            sellerAgentId: sellerAgentId,
            buyerAgentId: buyerAgentId,
            verifier: address(0),
            amount: PRICE,
            specHash: SPEC_HASH,
            specURI: SPEC_URI,
            taskType: TASK_TYPE,
            deliverBy: deliverBy,
            reviewWindow: REVIEW_WINDOW,
            approvalMode: ITaskEscrow.ApprovalMode.User
        });
    }

    function _create(ITaskEscrow.OrderParams memory p) internal returns (uint256 orderId) {
        vm.prank(buyer);
        orderId = escrow.createOrder(p);
    }

    function _create() internal returns (uint256) {
        return _create(_params());
    }

    function _agreed(ITaskEscrow.OrderParams memory p) internal returns (uint256 orderId) {
        orderId = _create(p);
        vm.prank(sellerOwner);
        escrow.agree(orderId, p.specHash);
    }

    function _funded(ITaskEscrow.OrderParams memory p) internal returns (uint256 orderId) {
        orderId = _agreed(p);
        vm.prank(buyer);
        escrow.fund(orderId);
    }

    function _delivered(ITaskEscrow.OrderParams memory p) internal returns (uint256 orderId) {
        orderId = _funded(p);
        vm.prank(sellerOwner);
        escrow.submitDelivery(orderId, DELIVERY_HASH, DELIVERY_URI);
    }

    function _agreed() internal returns (uint256) {
        return _agreed(_params());
    }

    function _funded() internal returns (uint256) {
        return _funded(_params());
    }

    function _delivered() internal returns (uint256) {
        return _delivered(_params());
    }

    /// @dev User approval mode: verifier passed, awaiting the buyer's approval.
    function _passed() internal returns (uint256 orderId) {
        orderId = _delivered();
        vm.prank(verifier);
        escrow.release(orderId, RESULT_HASH, RESULT_URI);
    }

    function _status(uint256 orderId) internal view returns (ITaskEscrow.Status) {
        return escrow.getOrder(orderId).status;
    }

    function _clients() internal view returns (address[] memory clients) {
        clients = new address[](1);
        clients[0] = address(escrow);
    }

    function _feedback(uint256 agentId, uint64 index)
        internal
        view
        returns (int128 value, string memory tag1, string memory tag2)
    {
        (value,, tag1, tag2,) = reputation.readFeedback(agentId, address(escrow), index);
    }

    function _signAgentWallet(uint256 walletKey, uint256 agentId, address wallet, address owner, uint256 deadline)
        internal
        view
        returns (bytes memory)
    {
        bytes32 digest = identity.agentWalletDigest(agentId, wallet, owner, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(walletKey, digest);
        return abi.encodePacked(r, s, v);
    }
}
