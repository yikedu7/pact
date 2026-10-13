// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

/// @title FulfillmentFeedback
/// @notice Builds the ERC-8004 off-chain feedback file for an escrow outcome entirely on-chain, so the
///         fields the product relies on (task_type, amount, passed, on_time) are computed by the escrow
///         rather than asserted by the verifier. The file is published as a base64 `data:` URI and its
///         keccak256 is used as `feedbackHash`.
library FulfillmentFeedback {
    using Strings for uint256;
    using Strings for address;

    uint256 internal constant MAX_TASK_TYPE_LENGTH = 32;

    struct Data {
        uint256 chainId;
        address identityRegistry;
        uint256 agentId;
        address clientAddress;
        uint256 createdAt;
        int128 value;
        string taskType;
        bool onTime;
        bool passed;
        uint256 orderId;
        address token;
        uint256 amount;
        bytes32 specHash;
        bytes32 deliveryHash;
        bytes32 reportHash;
    }

    function onTimeTag(bool onTime) internal pure returns (string memory) {
        return onTime ? "on_time" : "late";
    }

    /// @notice task_type is reused as ERC-8004 `tag1` and embedded unescaped in JSON, so it is
    ///         restricted to 1-32 chars of `[a-z0-9_.-]`.
    function isValidTaskType(string memory taskType) internal pure returns (bool) {
        bytes memory b = bytes(taskType);
        if (b.length == 0 || b.length > MAX_TASK_TYPE_LENGTH) return false;
        for (uint256 i; i < b.length; ++i) {
            bytes1 c = b[i];
            bool ok = (c >= 0x61 && c <= 0x7a) || (c >= 0x30 && c <= 0x39) || c == 0x5f || c == 0x2e || c == 0x2d;
            if (!ok) return false;
        }
        return true;
    }

    function toJson(Data memory d) internal pure returns (string memory) {
        string memory chain = string.concat("eip155:", d.chainId.toString(), ":");
        string memory head = string.concat(
            '{"agentRegistry":"',
            chain,
            d.identityRegistry.toChecksumHexString(),
            '","agentId":',
            d.agentId.toString(),
            ',"clientAddress":"',
            chain,
            d.clientAddress.toChecksumHexString(),
            '","createdAt":"',
            isoTimestamp(d.createdAt),
            '","value":',
            Strings.toStringSigned(d.value),
            ',"valueDecimals":0,"tag1":"',
            d.taskType,
            '","tag2":"',
            onTimeTag(d.onTime),
            '"'
        );
        string memory body = string.concat(
            ',"task_type":"',
            d.taskType,
            '","amount":"',
            d.amount.toString(),
            '","token":"',
            d.token.toChecksumHexString(),
            '","passed":',
            d.passed ? "true" : "false",
            ',"on_time":',
            d.onTime ? "true" : "false",
            ',"orderId":"',
            d.orderId.toString(),
            '"'
        );
        string memory hashes = string.concat(
            ',"specHash":"',
            uint256(d.specHash).toHexString(32),
            '","deliveryHash":"',
            uint256(d.deliveryHash).toHexString(32),
            '","reportHash":"',
            uint256(d.reportHash).toHexString(32),
            '"}'
        );
        return string.concat(head, body, hashes);
    }

    function toDataURI(string memory json) internal pure returns (string memory) {
        return string.concat("data:application/json;base64,", Base64.encode(bytes(json)));
    }

    /// @notice Unix seconds -> `YYYY-MM-DDTHH:MM:SSZ` (proleptic Gregorian, years 1000-9999).
    function isoTimestamp(uint256 ts) internal pure returns (string memory) {
        (uint256 year, uint256 month, uint256 day) = _civilFromDays(ts / 86400);
        uint256 secs = ts % 86400;
        return string.concat(
            year.toString(),
            "-",
            _pad2(month),
            "-",
            _pad2(day),
            "T",
            _pad2(secs / 3600),
            ":",
            _pad2((secs % 3600) / 60),
            ":",
            _pad2(secs % 60),
            "Z"
        );
    }

    /// @dev Howard Hinnant's `civil_from_days`, specialised to non-negative day counts. The integer
    ///      divisions are intentional truncations of the calendar arithmetic.
    // forge-lint: disable-next-item(divide-before-multiply)
    function _civilFromDays(uint256 daysSinceEpoch) private pure returns (uint256 year, uint256 month, uint256 day) {
        uint256 z = daysSinceEpoch + 719468;
        uint256 era = z / 146097;
        uint256 doe = z - era * 146097;
        uint256 yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
        uint256 doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
        uint256 mp = (5 * doy + 2) / 153;
        day = doy - (153 * mp + 2) / 5 + 1;
        month = mp < 10 ? mp + 3 : mp - 9;
        year = yoe + era * 400 + (month <= 2 ? 1 : 0);
    }

    function _pad2(uint256 v) private pure returns (string memory) {
        return v < 10 ? string.concat("0", v.toString()) : v.toString();
    }
}
