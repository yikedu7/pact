// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IIdentityRegistry} from "../interfaces/IIdentityRegistry.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ERC721URIStorage} from "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";

/// @title IdentityRegistry
/// @notice Minimal ERC-8004 identity registry: each agent is an ERC-721 token whose URI points to the
///         agent registration file. Agent ids start at 1 so that 0 can be used as "no agent" off-chain.
contract IdentityRegistry is IIdentityRegistry, ERC721URIStorage, EIP712 {
    string public constant AGENT_WALLET_KEY = "agentWallet";

    bytes32 public constant SET_AGENT_WALLET_TYPEHASH =
        keccak256("SetAgentWallet(uint256 agentId,address newWallet,address owner,uint256 deadline)");

    bytes32 private constant AGENT_WALLET_KEY_HASH = keccak256(bytes(AGENT_WALLET_KEY));

    uint256 private _nextAgentId = 1;

    mapping(uint256 agentId => mapping(string key => bytes value)) private _metadata;
    mapping(uint256 agentId => address wallet) private _agentWallet;

    error NotAgentOwnerOrOperator(uint256 agentId, address caller);
    error ReservedMetadataKey(string key);
    error SignatureExpired(uint256 deadline);
    error InvalidWalletSignature();
    error ZeroWallet();

    constructor() ERC721("ERC-8004 Agent Identity", "AGENT") EIP712("IdentityRegistry", "1") {}

    // ---------------------------------------------------------------------
    // Registration
    // ---------------------------------------------------------------------

    function register(string calldata agentURI, MetadataEntry[] calldata metadata) external returns (uint256 agentId) {
        agentId = _register(agentURI);
        for (uint256 i; i < metadata.length; ++i) {
            _setMetadata(agentId, metadata[i].metadataKey, metadata[i].metadataValue);
        }
    }

    function register(string calldata agentURI) external returns (uint256 agentId) {
        agentId = _register(agentURI);
    }

    function register() external returns (uint256 agentId) {
        agentId = _register("");
    }

    function totalAgents() external view returns (uint256) {
        return _nextAgentId - 1;
    }

    // ---------------------------------------------------------------------
    // URI and metadata
    // ---------------------------------------------------------------------

    function setAgentURI(uint256 agentId, string calldata newURI) external {
        _requireOwnerOrOperator(agentId);
        _setTokenURI(agentId, newURI);
        emit URIUpdated(agentId, newURI, msg.sender);
    }

    function getMetadata(uint256 agentId, string calldata metadataKey) external view returns (bytes memory) {
        if (keccak256(bytes(metadataKey)) == AGENT_WALLET_KEY_HASH) {
            address wallet = _agentWallet[agentId];
            return wallet == address(0) ? bytes("") : abi.encodePacked(wallet);
        }
        return _metadata[agentId][metadataKey];
    }

    function setMetadata(uint256 agentId, string calldata metadataKey, bytes calldata metadataValue) external {
        _requireOwnerOrOperator(agentId);
        _setMetadata(agentId, metadataKey, metadataValue);
    }

    // ---------------------------------------------------------------------
    // Agent wallet
    // ---------------------------------------------------------------------

    function getAgentWallet(uint256 agentId) external view returns (address) {
        return _agentWallet[agentId];
    }

    /// @notice Points the agent's payout wallet at `newWallet`. `newWallet` must sign an EIP-712
    ///         `SetAgentWallet` message (EOA) or validate it via ERC-1271 (smart contract wallet).
    function setAgentWallet(uint256 agentId, address newWallet, uint256 deadline, bytes calldata signature) external {
        address owner = _requireOwnerOrOperator(agentId);
        if (newWallet == address(0)) revert ZeroWallet();
        if (block.timestamp > deadline) revert SignatureExpired(deadline);

        bytes32 digest = agentWalletDigest(agentId, newWallet, owner, deadline);
        if (!SignatureChecker.isValidSignatureNow(newWallet, digest, signature)) revert InvalidWalletSignature();

        _setAgentWallet(agentId, newWallet);
    }

    function unsetAgentWallet(uint256 agentId) external {
        _requireOwnerOrOperator(agentId);
        _setAgentWallet(agentId, address(0));
    }

    function agentWalletDigest(uint256 agentId, address newWallet, address owner, uint256 deadline)
        public
        view
        returns (bytes32)
    {
        return _hashTypedDataV4(keccak256(abi.encode(SET_AGENT_WALLET_TYPEHASH, agentId, newWallet, owner, deadline)));
    }

    function DOMAIN_SEPARATOR() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    /// @notice True if `account` owns `agentId` or is approved to manage it.
    function isOwnerOrOperator(uint256 agentId, address account) external view returns (bool) {
        return _isAuthorized(_requireOwned(agentId), account, agentId);
    }

    // ---------------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------------

    function _register(string memory agentURI) private returns (uint256 agentId) {
        agentId = _nextAgentId++;
        _mint(msg.sender, agentId);
        if (bytes(agentURI).length != 0) _setTokenURI(agentId, agentURI);
        _setAgentWallet(agentId, msg.sender);
        emit Registered(agentId, agentURI, msg.sender);
    }

    function _setMetadata(uint256 agentId, string calldata key, bytes calldata value) private {
        // forge-lint: disable-next-line(require-revert-in-loop)
        if (keccak256(bytes(key)) == AGENT_WALLET_KEY_HASH) revert ReservedMetadataKey(key);
        _metadata[agentId][key] = value;
        emit MetadataSet(agentId, key, key, value);
    }

    function _setAgentWallet(uint256 agentId, address wallet) private {
        _agentWallet[agentId] = wallet;
        // forge-lint: disable-next-item(reentrancy-events)
        emit MetadataSet(
            agentId, AGENT_WALLET_KEY, AGENT_WALLET_KEY, wallet == address(0) ? bytes("") : abi.encodePacked(wallet)
        );
    }

    function _requireOwnerOrOperator(uint256 agentId) private view returns (address owner) {
        owner = _requireOwned(agentId);
        if (!_isAuthorized(owner, msg.sender, agentId)) revert NotAgentOwnerOrOperator(agentId, msg.sender);
    }

    /// @dev Clears the verified payout wallet whenever the agent changes hands.
    function _update(address to, uint256 tokenId, address auth) internal override returns (address from) {
        from = super._update(to, tokenId, auth);
        if (from != address(0) && from != to && _agentWallet[tokenId] != address(0)) {
            _setAgentWallet(tokenId, address(0));
        }
    }
}
