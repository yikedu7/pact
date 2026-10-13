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

    uint256 internal constant PRICE = 25e6; // 25 mUSDC
    uint256 internal constant BUYER_BALANCE = 1_000e6;
    uint32 internal constant VERIFY_WINDOW = 1 hours;
    uint256 internal constant START_TIME = 1_700_000_000; // 2023-11-14T22:13:20Z

    /// @dev Canonical (RFC 8785 / JCS) form of the sample spec in docs/ARCHITECTURE.md.
    string internal constant SPEC_JSON = '{"acceptance":[{"id":"len","rule":"max_words","value":200},{"id":"lang","rule":"language","value":"en"}],'
        '"deliverable":{"format":"text/markdown"},"input":{"uri":"ipfs://bafyinput"},"task_type":"summarize",'
        '"version":"1"}';
    bytes32 internal SPEC_HASH = keccak256(bytes(SPEC_JSON));
    string internal constant SPEC_URI = "ipfs://bafyspec";
    string internal constant TASK_TYPE = "summarize";
    bytes32 internal constant DELIVERY_HASH = keccak256("delivery-manifest");
    string internal constant DELIVERY_URI = "ipfs://bafydelivery";
    bytes32 internal constant REPORT_HASH = keccak256("verification-report");
    string internal constant REPORT_URI = "ipfs://bafyreport";

    uint64 internal deliverBy;

    function setUp() public virtual {
        vm.warp(START_TIME);
        usdc = new MockUSDC();
        identity = new IdentityRegistry();
        reputation = new ReputationRegistry(address(identity));
        escrow = new TaskEscrow(
            IERC20(address(usdc)), IIdentityRegistry(address(identity)), IReputationRegistry(address(reputation))
        );

        (sellerOwner, sellerOwnerKey) = makeAddrAndKey("sellerOwner");
        vm.prank(sellerOwner);
        sellerAgentId = identity.register("ipfs://seller-agent.json");

        usdc.mint(buyer, BUYER_BALANCE);
        vm.prank(buyer);
        usdc.approve(address(escrow), type(uint256).max);

        deliverBy = uint64(vm.getBlockTimestamp() + 1 days);
    }

    // ---------------------------------------------------------------------
    // Lifecycle helpers
    // ---------------------------------------------------------------------

    function _create() internal returns (uint256 orderId) {
        vm.prank(buyer);
        orderId = escrow.createOrder(
            sellerAgentId, verifier, PRICE, SPEC_HASH, SPEC_URI, TASK_TYPE, deliverBy, VERIFY_WINDOW
        );
    }

    function _agreed() internal returns (uint256 orderId) {
        orderId = _create();
        vm.prank(sellerOwner);
        escrow.agree(orderId);
    }

    function _funded() internal returns (uint256 orderId) {
        orderId = _agreed();
        vm.prank(buyer);
        escrow.fund(orderId);
    }

    function _delivered() internal returns (uint256 orderId) {
        orderId = _funded();
        vm.prank(sellerOwner);
        escrow.submitDelivery(orderId, DELIVERY_HASH, DELIVERY_URI);
    }

    function _verified() internal returns (uint256 orderId) {
        orderId = _delivered();
        vm.prank(verifier);
        escrow.verify(orderId, REPORT_HASH, REPORT_URI);
    }

    function _status(uint256 orderId) internal view returns (ITaskEscrow.Status) {
        return escrow.getOrder(orderId).status;
    }

    function _clients() internal view returns (address[] memory clients) {
        clients = new address[](1);
        clients[0] = address(escrow);
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
