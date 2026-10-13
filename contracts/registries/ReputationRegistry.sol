// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IReputationRegistry} from "../interfaces/IReputationRegistry.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @title ReputationRegistry
/// @notice Minimal ERC-8004 reputation registry. Feedback is keyed by (agentId, clientAddress) with a
///         1-indexed `feedbackIndex`. The identity registry is fixed at construction instead of via
///         `initialize`, since this deployment is not behind a proxy.
contract ReputationRegistry is IReputationRegistry {
    uint8 public constant MAX_VALUE_DECIMALS = 18;

    struct Feedback {
        int128 value;
        uint8 valueDecimals;
        bool isRevoked;
        string tag1;
        string tag2;
    }

    address private immutable _identityRegistry;

    mapping(uint256 agentId => mapping(address client => Feedback[])) private _feedback;
    mapping(uint256 agentId => address[]) private _clients;
    mapping(uint256 agentId => mapping(address client => bool)) private _isClient;
    mapping(uint256 agentId => mapping(address client => mapping(uint64 feedbackIndex => address[]))) private
        _responders;

    error ZeroIdentityRegistry();
    error AgentNotFound(uint256 agentId);
    error SelfFeedback(uint256 agentId, address caller);
    error InvalidValueDecimals(uint8 valueDecimals);
    error FeedbackNotFound(uint256 agentId, address clientAddress, uint64 feedbackIndex);
    error FeedbackAlreadyRevoked(uint256 agentId, address clientAddress, uint64 feedbackIndex);
    error EmptyClientFilter();

    constructor(address identityRegistry_) {
        if (identityRegistry_ == address(0)) revert ZeroIdentityRegistry();
        _identityRegistry = identityRegistry_;
    }

    function getIdentityRegistry() external view returns (address) {
        return _identityRegistry;
    }

    // ---------------------------------------------------------------------
    // Writes
    // ---------------------------------------------------------------------

    function giveFeedback(
        uint256 agentId,
        int128 value,
        uint8 valueDecimals,
        string calldata tag1,
        string calldata tag2,
        string calldata endpoint,
        string calldata feedbackURI,
        bytes32 feedbackHash
    ) external {
        if (valueDecimals > MAX_VALUE_DECIMALS) revert InvalidValueDecimals(valueDecimals);
        _requireNotOwnerOrOperator(agentId, msg.sender);

        if (!_isClient[agentId][msg.sender]) {
            _isClient[agentId][msg.sender] = true;
            _clients[agentId].push(msg.sender);
        }

        Feedback[] storage list = _feedback[agentId][msg.sender];
        list.push(Feedback({value: value, valueDecimals: valueDecimals, isRevoked: false, tag1: tag1, tag2: tag2}));
        // forge-lint: disable-next-line(unsafe-typecast)
        uint64 feedbackIndex = uint64(list.length);

        emit NewFeedback(
            agentId,
            msg.sender,
            feedbackIndex,
            value,
            valueDecimals,
            tag1,
            tag1,
            tag2,
            endpoint,
            feedbackURI,
            feedbackHash
        );
    }

    function revokeFeedback(uint256 agentId, uint64 feedbackIndex) external {
        Feedback storage fb = _get(agentId, msg.sender, feedbackIndex);
        if (fb.isRevoked) revert FeedbackAlreadyRevoked(agentId, msg.sender, feedbackIndex);
        fb.isRevoked = true;
        emit FeedbackRevoked(agentId, msg.sender, feedbackIndex);
    }

    function appendResponse(
        uint256 agentId,
        address clientAddress,
        uint64 feedbackIndex,
        string calldata responseURI,
        bytes32 responseHash
    ) external {
        _get(agentId, clientAddress, feedbackIndex);
        _responders[agentId][clientAddress][feedbackIndex].push(msg.sender);
        emit ResponseAppended(agentId, clientAddress, feedbackIndex, msg.sender, responseURI, responseHash);
    }

    // ---------------------------------------------------------------------
    // Reads
    // ---------------------------------------------------------------------

    /// @notice Average of non-revoked feedback from `clientAddresses`, optionally filtered by tags
    ///         (empty string = no filter). Values are rescaled to the largest `valueDecimals` seen.
    function getSummary(uint256 agentId, address[] calldata clientAddresses, string calldata tag1, string calldata tag2)
        external
        view
        returns (uint64 count, int128 summaryValue, uint8 summaryValueDecimals)
    {
        if (clientAddresses.length == 0) revert EmptyClientFilter();
        bytes32 tag1Hash = bytes(tag1).length == 0 ? bytes32(0) : keccak256(bytes(tag1));
        bytes32 tag2Hash = bytes(tag2).length == 0 ? bytes32(0) : keccak256(bytes(tag2));

        for (uint256 c; c < clientAddresses.length; ++c) {
            Feedback[] storage list = _feedback[agentId][clientAddresses[c]];
            for (uint256 i; i < list.length; ++i) {
                if (!_matches(list[i], tag1Hash, tag2Hash)) continue;
                ++count;
                if (list[i].valueDecimals > summaryValueDecimals) summaryValueDecimals = list[i].valueDecimals;
            }
        }
        if (count == 0) return (0, 0, 0);

        int256 sum = 0;
        for (uint256 c; c < clientAddresses.length; ++c) {
            Feedback[] storage list = _feedback[agentId][clientAddresses[c]];
            for (uint256 i; i < list.length; ++i) {
                if (!_matches(list[i], tag1Hash, tag2Hash)) continue;
                sum += int256(list[i].value) * int256(10 ** (summaryValueDecimals - list[i].valueDecimals));
            }
        }
        summaryValue = SafeCast.toInt128(sum / int256(uint256(count)));
    }

    function readFeedback(uint256 agentId, address clientAddress, uint64 feedbackIndex)
        external
        view
        returns (int128 value, uint8 valueDecimals, string memory tag1, string memory tag2, bool isRevoked)
    {
        Feedback storage fb = _get(agentId, clientAddress, feedbackIndex);
        return (fb.value, fb.valueDecimals, fb.tag1, fb.tag2, fb.isRevoked);
    }

    /// @notice Number of responses. `clientAddress == address(0)`, `feedbackIndex == 0` and an empty
    ///         `responders` list each mean "no filter" on that dimension.
    function getResponseCount(
        uint256 agentId,
        address clientAddress,
        uint64 feedbackIndex,
        address[] calldata responders
    ) external view returns (uint64 count) {
        if (clientAddress != address(0)) {
            return _responseCount(agentId, clientAddress, feedbackIndex, responders);
        }
        address[] storage clients = _clients[agentId];
        for (uint256 c; c < clients.length; ++c) {
            count += _responseCount(agentId, clients[c], feedbackIndex, responders);
        }
    }

    function getClients(uint256 agentId) external view returns (address[] memory) {
        return _clients[agentId];
    }

    function getLastIndex(uint256 agentId, address clientAddress) external view returns (uint64) {
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint64(_feedback[agentId][clientAddress].length);
    }

    // ---------------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------------

    function _requireNotOwnerOrOperator(uint256 agentId, address caller) private view {
        IERC721 identity = IERC721(_identityRegistry);
        address owner = address(0);
        try identity.ownerOf(agentId) returns (address o) {
            owner = o;
        } catch {
            revert AgentNotFound(agentId);
        }
        if (caller == owner || identity.isApprovedForAll(owner, caller) || identity.getApproved(agentId) == caller) {
            revert SelfFeedback(agentId, caller);
        }
    }

    function _get(uint256 agentId, address clientAddress, uint64 feedbackIndex)
        private
        view
        returns (Feedback storage)
    {
        Feedback[] storage list = _feedback[agentId][clientAddress];
        if (feedbackIndex == 0 || feedbackIndex > list.length) {
            revert FeedbackNotFound(agentId, clientAddress, feedbackIndex);
        }
        return list[feedbackIndex - 1];
    }

    function _matches(Feedback storage fb, bytes32 tag1Hash, bytes32 tag2Hash) private view returns (bool) {
        if (fb.isRevoked) return false;
        if (tag1Hash != bytes32(0) && keccak256(bytes(fb.tag1)) != tag1Hash) return false;
        if (tag2Hash != bytes32(0) && keccak256(bytes(fb.tag2)) != tag2Hash) return false;
        return true;
    }

    function _responseCount(uint256 agentId, address clientAddress, uint64 feedbackIndex, address[] calldata responders)
        private
        view
        returns (uint64 count)
    {
        uint64 from = feedbackIndex == 0 ? 1 : feedbackIndex;
        // forge-lint: disable-next-line(unsafe-typecast)
        uint64 to = feedbackIndex == 0 ? uint64(_feedback[agentId][clientAddress].length) : feedbackIndex;
        for (uint64 idx = from; idx <= to; ++idx) {
            address[] storage list = _responders[agentId][clientAddress][idx];
            if (responders.length == 0) {
                // forge-lint: disable-next-line(unsafe-typecast)
                count += uint64(list.length);
                continue;
            }
            for (uint256 r; r < list.length; ++r) {
                for (uint256 f; f < responders.length; ++f) {
                    if (list[r] == responders[f]) {
                        ++count;
                        break;
                    }
                }
            }
        }
    }
}
