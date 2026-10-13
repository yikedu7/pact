// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IIdentityRegistry} from "../contracts/interfaces/IIdentityRegistry.sol";
import {IdentityRegistry} from "../contracts/registries/IdentityRegistry.sol";
import {ERC1271Wallet} from "./mocks/ERC1271Wallet.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {Test} from "forge-std/Test.sol";

contract IdentityRegistryTest is Test {
    IdentityRegistry internal identity;

    address internal owner;
    uint256 internal ownerKey;
    address internal stranger = makeAddr("stranger");
    address internal wallet;
    uint256 internal walletKey;

    function setUp() public {
        identity = new IdentityRegistry();
        (owner, ownerKey) = makeAddrAndKey("owner");
        (wallet, walletKey) = makeAddrAndKey("wallet");
    }

    function _register() internal returns (uint256 agentId) {
        vm.prank(owner);
        agentId = identity.register("ipfs://agent.json");
    }

    function _sign(uint256 key, uint256 agentId, address newWallet, address agentOwner, uint256 deadline)
        internal
        view
        returns (bytes memory)
    {
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(key, identity.agentWalletDigest(agentId, newWallet, agentOwner, deadline));
        return abi.encodePacked(r, s, v);
    }

    // ---------------------------------------------------------------------
    // register
    // ---------------------------------------------------------------------

    function test_register_mintsSequentialIdsFromOne() public {
        vm.expectEmit(address(identity));
        emit IIdentityRegistry.MetadataSet(1, "agentWallet", "agentWallet", abi.encodePacked(owner));
        vm.expectEmit(address(identity));
        emit IIdentityRegistry.Registered(1, "ipfs://agent.json", owner);
        assertEq(_register(), 1);

        vm.prank(stranger);
        assertEq(identity.register(), 2);

        assertEq(identity.ownerOf(1), owner);
        assertEq(identity.tokenURI(1), "ipfs://agent.json");
        assertEq(identity.ownerOf(2), stranger);
        assertEq(identity.tokenURI(2), "");
        assertEq(identity.totalAgents(), 2);
    }

    function test_register_defaultsAgentWalletToOwner() public {
        uint256 agentId = _register();
        assertEq(identity.getAgentWallet(agentId), owner);
        assertEq(identity.getMetadata(agentId, "agentWallet"), abi.encodePacked(owner));
    }

    function test_register_withMetadata() public {
        IIdentityRegistry.MetadataEntry[] memory md = new IIdentityRegistry.MetadataEntry[](2);
        md[0] = IIdentityRegistry.MetadataEntry("skills", bytes("summarize,translate"));
        md[1] = IIdentityRegistry.MetadataEntry("x402", hex"01");

        vm.prank(owner);
        uint256 agentId = identity.register("ipfs://agent.json", md);
        assertEq(identity.getMetadata(agentId, "skills"), bytes("summarize,translate"));
        assertEq(identity.getMetadata(agentId, "x402"), hex"01");
    }

    function test_register_revertsOnReservedMetadataKey() public {
        IIdentityRegistry.MetadataEntry[] memory md = new IIdentityRegistry.MetadataEntry[](1);
        md[0] = IIdentityRegistry.MetadataEntry("agentWallet", abi.encodePacked(stranger));
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IdentityRegistry.ReservedMetadataKey.selector, "agentWallet"));
        identity.register("ipfs://agent.json", md);
    }

    // ---------------------------------------------------------------------
    // URI / metadata
    // ---------------------------------------------------------------------

    function test_setAgentURI_byOwner() public {
        uint256 agentId = _register();
        vm.expectEmit(address(identity));
        emit IIdentityRegistry.URIUpdated(agentId, "ipfs://v2.json", owner);
        vm.prank(owner);
        identity.setAgentURI(agentId, "ipfs://v2.json");
        assertEq(identity.tokenURI(agentId), "ipfs://v2.json");
    }

    function test_setAgentURI_byOperator() public {
        uint256 agentId = _register();
        vm.prank(owner);
        identity.setApprovalForAll(stranger, true);
        vm.prank(stranger);
        identity.setAgentURI(agentId, "ipfs://v2.json");
        assertEq(identity.tokenURI(agentId), "ipfs://v2.json");
        assertTrue(identity.isOwnerOrOperator(agentId, stranger));
    }

    function test_setAgentURI_revertsForStranger() public {
        uint256 agentId = _register();
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IdentityRegistry.NotAgentOwnerOrOperator.selector, agentId, stranger));
        identity.setAgentURI(agentId, "ipfs://evil.json");
    }

    function test_setMetadata_byOwner() public {
        uint256 agentId = _register();
        vm.expectEmit(address(identity));
        emit IIdentityRegistry.MetadataSet(agentId, "endpoint", "endpoint", bytes("https://agent.example"));
        vm.prank(owner);
        identity.setMetadata(agentId, "endpoint", bytes("https://agent.example"));
        assertEq(identity.getMetadata(agentId, "endpoint"), bytes("https://agent.example"));
    }

    function test_setMetadata_revertsForReservedKeyAndStranger() public {
        uint256 agentId = _register();
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IdentityRegistry.ReservedMetadataKey.selector, "agentWallet"));
        identity.setMetadata(agentId, "agentWallet", abi.encodePacked(stranger));

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IdentityRegistry.NotAgentOwnerOrOperator.selector, agentId, stranger));
        identity.setMetadata(agentId, "endpoint", "x");
    }

    function test_revertsForNonexistentAgent() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 99));
        identity.setAgentURI(99, "x");
        assertEq(identity.getAgentWallet(99), address(0));
    }

    // ---------------------------------------------------------------------
    // agentWallet
    // ---------------------------------------------------------------------

    function test_setAgentWallet_withEoaSignature() public {
        uint256 agentId = _register();
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        bytes memory sig = _sign(walletKey, agentId, wallet, owner, deadline);

        vm.expectEmit(address(identity));
        emit IIdentityRegistry.MetadataSet(agentId, "agentWallet", "agentWallet", abi.encodePacked(wallet));
        vm.prank(owner);
        identity.setAgentWallet(agentId, wallet, deadline, sig);
        assertEq(identity.getAgentWallet(agentId), wallet);
    }

    function test_setAgentWallet_withErc1271Wallet() public {
        uint256 agentId = _register();
        ERC1271Wallet scw = new ERC1271Wallet(wallet);
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        bytes memory sig = _sign(walletKey, agentId, address(scw), owner, deadline);

        vm.prank(owner);
        identity.setAgentWallet(agentId, address(scw), deadline, sig);
        assertEq(identity.getAgentWallet(agentId), address(scw));
    }

    function test_setAgentWallet_revertsOnExpiredSignature() public {
        uint256 agentId = _register();
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        bytes memory sig = _sign(walletKey, agentId, wallet, owner, deadline);
        vm.warp(deadline + 1);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IdentityRegistry.SignatureExpired.selector, deadline));
        identity.setAgentWallet(agentId, wallet, deadline, sig);
    }

    function test_setAgentWallet_revertsOnWrongSigner() public {
        uint256 agentId = _register();
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        bytes memory sig = _sign(ownerKey, agentId, wallet, owner, deadline);
        vm.prank(owner);
        vm.expectRevert(IdentityRegistry.InvalidWalletSignature.selector);
        identity.setAgentWallet(agentId, wallet, deadline, sig);
    }

    function test_setAgentWallet_signatureIsBoundToOwner() public {
        uint256 agentId = _register();
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        bytes memory sig = _sign(walletKey, agentId, wallet, owner, deadline);

        address newOwner = makeAddr("newOwner");
        vm.prank(owner);
        identity.transferFrom(owner, newOwner, agentId);

        vm.prank(newOwner);
        vm.expectRevert(IdentityRegistry.InvalidWalletSignature.selector);
        identity.setAgentWallet(agentId, wallet, deadline, sig);
    }

    function test_setAgentWallet_revertsForStrangerAndZeroWallet() public {
        uint256 agentId = _register();
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        bytes memory sig = _sign(walletKey, agentId, wallet, owner, deadline);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IdentityRegistry.NotAgentOwnerOrOperator.selector, agentId, stranger));
        identity.setAgentWallet(agentId, wallet, deadline, sig);

        vm.prank(owner);
        vm.expectRevert(IdentityRegistry.ZeroWallet.selector);
        identity.setAgentWallet(agentId, address(0), deadline, sig);
    }

    function test_unsetAgentWallet() public {
        uint256 agentId = _register();
        vm.prank(owner);
        identity.unsetAgentWallet(agentId);
        assertEq(identity.getAgentWallet(agentId), address(0));
        assertEq(identity.getMetadata(agentId, "agentWallet"), "");
    }

    function test_transfer_clearsAgentWallet() public {
        uint256 agentId = _register();
        address newOwner = makeAddr("newOwner");

        vm.expectEmit(address(identity));
        emit IIdentityRegistry.MetadataSet(agentId, "agentWallet", "agentWallet", "");
        vm.prank(owner);
        identity.transferFrom(owner, newOwner, agentId);

        assertEq(identity.ownerOf(agentId), newOwner);
        assertEq(identity.getAgentWallet(agentId), address(0));
    }

    function test_supportsErc721Interfaces() public view {
        assertTrue(identity.supportsInterface(0x80ac58cd)); // ERC-721
        assertTrue(identity.supportsInterface(0x5b5e139f)); // ERC-721 Metadata
        assertTrue(identity.supportsInterface(0x49064906)); // ERC-4906 (URIStorage)
    }
}
