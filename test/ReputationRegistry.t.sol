// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IReputationRegistry} from "../contracts/interfaces/IReputationRegistry.sol";
import {IdentityRegistry} from "../contracts/registries/IdentityRegistry.sol";
import {ReputationRegistry} from "../contracts/registries/ReputationRegistry.sol";
import {Test} from "forge-std/Test.sol";

contract ReputationRegistryTest is Test {
    IdentityRegistry internal identity;
    ReputationRegistry internal reputation;

    address internal agentOwner = makeAddr("agentOwner");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal responder = makeAddr("responder");
    uint256 internal agentId;

    function setUp() public {
        identity = new IdentityRegistry();
        reputation = new ReputationRegistry(address(identity));
        vm.prank(agentOwner);
        agentId = identity.register("ipfs://agent.json");
    }

    function _give(address client, int128 value, uint8 decimals, string memory tag1, string memory tag2) internal {
        vm.prank(client);
        reputation.giveFeedback(agentId, value, decimals, tag1, tag2, "", "", bytes32(0));
    }

    function _filter(address a) internal pure returns (address[] memory list) {
        list = new address[](1);
        list[0] = a;
    }

    function _filter(address a, address b) internal pure returns (address[] memory list) {
        list = new address[](2);
        list[0] = a;
        list[1] = b;
    }

    // ---------------------------------------------------------------------
    // Setup
    // ---------------------------------------------------------------------

    function test_constructor() public {
        assertEq(reputation.getIdentityRegistry(), address(identity));
        vm.expectRevert(ReputationRegistry.ZeroIdentityRegistry.selector);
        new ReputationRegistry(address(0));
    }

    // ---------------------------------------------------------------------
    // giveFeedback
    // ---------------------------------------------------------------------

    function test_giveFeedback_storesAndEmits() public {
        vm.expectEmit(address(reputation));
        emit IReputationRegistry.NewFeedback(
            agentId, alice, 1, 87, 0, "starred", "starred", "", "https://agent/x", "ipfs://fb", keccak256("fb")
        );
        vm.prank(alice);
        reputation.giveFeedback(agentId, 87, 0, "starred", "", "https://agent/x", "ipfs://fb", keccak256("fb"));

        (int128 value, uint8 decimals, string memory tag1, string memory tag2, bool revoked) =
            reputation.readFeedback(agentId, alice, 1);
        assertEq(value, 87);
        assertEq(decimals, 0);
        assertEq(tag1, "starred");
        assertEq(tag2, "");
        assertFalse(revoked);
        assertEq(reputation.getLastIndex(agentId, alice), 1);

        _give(alice, 90, 0, "starred", "");
        assertEq(reputation.getLastIndex(agentId, alice), 2);
        assertEq(reputation.getClients(agentId).length, 1);

        _give(bob, 1, 0, "reachable", "");
        address[] memory clients = reputation.getClients(agentId);
        assertEq(clients.length, 2);
        assertEq(clients[1], bob);
    }

    function test_giveFeedback_revertsForUnknownAgent() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ReputationRegistry.AgentNotFound.selector, 42));
        reputation.giveFeedback(42, 1, 0, "", "", "", "", bytes32(0));
    }

    function test_giveFeedback_revertsForOwnerAndOperators() public {
        vm.prank(agentOwner);
        vm.expectRevert(abi.encodeWithSelector(ReputationRegistry.SelfFeedback.selector, agentId, agentOwner));
        reputation.giveFeedback(agentId, 100, 0, "", "", "", "", bytes32(0));

        vm.prank(agentOwner);
        identity.setApprovalForAll(alice, true);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ReputationRegistry.SelfFeedback.selector, agentId, alice));
        reputation.giveFeedback(agentId, 100, 0, "", "", "", "", bytes32(0));

        vm.prank(agentOwner);
        identity.approve(bob, agentId);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(ReputationRegistry.SelfFeedback.selector, agentId, bob));
        reputation.giveFeedback(agentId, 100, 0, "", "", "", "", bytes32(0));
    }

    function test_giveFeedback_revertsOnTooManyDecimals() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ReputationRegistry.InvalidValueDecimals.selector, 19));
        reputation.giveFeedback(agentId, 1, 19, "", "", "", "", bytes32(0));
    }

    // ---------------------------------------------------------------------
    // revoke / respond
    // ---------------------------------------------------------------------

    function test_revokeFeedback() public {
        _give(alice, 10, 0, "", "");
        vm.expectEmit(address(reputation));
        emit IReputationRegistry.FeedbackRevoked(agentId, alice, 1);
        vm.prank(alice);
        reputation.revokeFeedback(agentId, 1);
        (,,,, bool revoked) = reputation.readFeedback(agentId, alice, 1);
        assertTrue(revoked);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ReputationRegistry.FeedbackAlreadyRevoked.selector, agentId, alice, 1));
        reputation.revokeFeedback(agentId, 1);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(ReputationRegistry.FeedbackNotFound.selector, agentId, bob, 1));
        reputation.revokeFeedback(agentId, 1);
    }

    function test_readFeedback_revertsOutOfRange() public {
        _give(alice, 10, 0, "", "");
        vm.expectRevert(abi.encodeWithSelector(ReputationRegistry.FeedbackNotFound.selector, agentId, alice, 0));
        reputation.readFeedback(agentId, alice, 0);
        vm.expectRevert(abi.encodeWithSelector(ReputationRegistry.FeedbackNotFound.selector, agentId, alice, 2));
        reputation.readFeedback(agentId, alice, 2);
    }

    function test_appendResponse_andCounts() public {
        _give(alice, 10, 0, "", "");
        _give(alice, 20, 0, "", "");
        _give(bob, 30, 0, "", "");

        vm.expectEmit(address(reputation));
        emit IReputationRegistry.ResponseAppended(agentId, alice, 1, responder, "ipfs://refund", keccak256("r"));
        vm.prank(responder);
        reputation.appendResponse(agentId, alice, 1, "ipfs://refund", keccak256("r"));
        vm.prank(agentOwner);
        reputation.appendResponse(agentId, alice, 2, "ipfs://reply", bytes32(0));
        vm.prank(responder);
        reputation.appendResponse(agentId, bob, 1, "ipfs://spam", bytes32(0));

        address[] memory none = new address[](0);
        assertEq(reputation.getResponseCount(agentId, address(0), 0, none), 3);
        assertEq(reputation.getResponseCount(agentId, alice, 0, none), 2);
        assertEq(reputation.getResponseCount(agentId, alice, 1, none), 1);
        assertEq(reputation.getResponseCount(agentId, address(0), 0, _filter(responder)), 2);
        assertEq(reputation.getResponseCount(agentId, alice, 0, _filter(agentOwner)), 1);

        vm.expectRevert(abi.encodeWithSelector(ReputationRegistry.FeedbackNotFound.selector, agentId, bob, 2));
        reputation.appendResponse(agentId, bob, 2, "x", bytes32(0));
    }

    // ---------------------------------------------------------------------
    // getSummary
    // ---------------------------------------------------------------------

    function test_getSummary_requiresClientFilter() public {
        vm.expectRevert(ReputationRegistry.EmptyClientFilter.selector);
        reputation.getSummary(agentId, new address[](0), "", "");
    }

    function test_getSummary_filtersByClientAndTags() public {
        _give(alice, 80, 0, "starred", "day");
        _give(alice, 100, 0, "starred", "week");
        _give(bob, 50, 0, "starred", "day");
        _give(bob, 1, 0, "reachable", "");

        (uint64 count, int128 value, uint8 decimals) = reputation.getSummary(agentId, _filter(alice), "", "");
        assertEq(count, 2);
        assertEq(value, 90);
        assertEq(decimals, 0);

        (count, value,) = reputation.getSummary(agentId, _filter(alice, bob), "starred", "");
        assertEq(count, 3);
        assertEq(value, 76); // 230 / 3

        (count, value,) = reputation.getSummary(agentId, _filter(alice, bob), "starred", "day");
        assertEq(count, 2);
        assertEq(value, 65);

        (count, value, decimals) = reputation.getSummary(agentId, _filter(alice), "missing", "");
        assertEq(count, 0);
        assertEq(value, 0);
        assertEq(decimals, 0);
    }

    function test_getSummary_rescalesDecimalsAndHandlesNegatives() public {
        _give(alice, 9977, 2, "uptime", ""); // 99.77
        _give(bob, 99, 0, "uptime", ""); // 99
        (uint64 count, int128 value, uint8 decimals) = reputation.getSummary(agentId, _filter(alice, bob), "uptime", "");
        assertEq(count, 2);
        assertEq(decimals, 2);
        assertEq(value, 9938); // (9977 + 9900) / 2, truncated

        _give(alice, -32, 1, "yield", "");
        _give(bob, -10, 1, "yield", "");
        (count, value, decimals) = reputation.getSummary(agentId, _filter(alice, bob), "yield", "");
        assertEq(value, -21);
        assertEq(decimals, 1);
    }

    function test_getSummary_excludesRevoked() public {
        _give(alice, 0, 0, "", "");
        _give(alice, 100, 0, "", "");
        vm.prank(alice);
        reputation.revokeFeedback(agentId, 1);
        (uint64 count, int128 value,) = reputation.getSummary(agentId, _filter(alice), "", "");
        assertEq(count, 1);
        assertEq(value, 100);
    }

    function testFuzz_getSummary_singleValueRoundTrips(int128 v, uint8 decimals) public {
        decimals = uint8(bound(decimals, 0, 18));
        _give(alice, v, decimals, "", "");
        (uint64 count, int128 value, uint8 d) = reputation.getSummary(agentId, _filter(alice), "", "");
        assertEq(count, 1);
        assertEq(value, v);
        assertEq(d, decimals);
    }
}
