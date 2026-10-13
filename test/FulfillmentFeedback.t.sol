// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {FulfillmentFeedback} from "../contracts/libraries/FulfillmentFeedback.sol";
import {MockUSDC} from "../contracts/mocks/MockUSDC.sol";
import {Test} from "forge-std/Test.sol";

contract FulfillmentFeedbackHarness {
    function isoTimestamp(uint256 ts) external pure returns (string memory) {
        return FulfillmentFeedback.isoTimestamp(ts);
    }

    function isValidTaskType(string calldata t) external pure returns (bool) {
        return FulfillmentFeedback.isValidTaskType(t);
    }

    function toDataURI(string calldata json) external pure returns (string memory) {
        return FulfillmentFeedback.toDataURI(json);
    }
}

contract FulfillmentFeedbackTest is Test {
    FulfillmentFeedbackHarness internal h;

    function setUp() public {
        h = new FulfillmentFeedbackHarness();
    }

    function test_isoTimestamp_knownVectors() public view {
        assertEq(h.isoTimestamp(0), "1970-01-01T00:00:00Z");
        assertEq(h.isoTimestamp(1_700_000_000), "2023-11-14T22:13:20Z");
        assertEq(h.isoTimestamp(951_782_400), "2000-02-29T00:00:00Z");
        assertEq(h.isoTimestamp(1_709_164_800), "2024-02-29T00:00:00Z");
        assertEq(h.isoTimestamp(4_102_444_799), "2099-12-31T23:59:59Z");
        assertEq(h.isoTimestamp(4_107_542_400), "2100-03-01T00:00:00Z"); // 2100 is not a leap year
    }

    /// @dev Round-trips against an independent `days_from_civil` implementation.
    function testFuzz_isoTimestamp_roundTrips(uint256 ts) public view {
        ts = bound(ts, 0, 253_402_300_799); // through 9999-12-31T23:59:59Z
        bytes memory s = bytes(h.isoTimestamp(ts));
        assertEq(s.length, 20);
        uint256 y = _num(s, 0, 4);
        uint256 m = _num(s, 5, 2);
        uint256 d = _num(s, 8, 2);
        uint256 secs = _num(s, 11, 2) * 3600 + _num(s, 14, 2) * 60 + _num(s, 17, 2);
        assertEq(_daysFromCivil(y, m, d) * 86400 + secs, ts);
    }

    function test_isValidTaskType() public view {
        assertTrue(h.isValidTaskType("summarize"));
        assertTrue(h.isValidTaskType("code-review_v2.1"));
        assertTrue(h.isValidTaskType("abcdefghijklmnopqrstuvwxyz012345")); // 32 chars
        assertFalse(h.isValidTaskType(""));
        assertFalse(h.isValidTaskType("abcdefghijklmnopqrstuvwxyz0123456")); // 33 chars
        assertFalse(h.isValidTaskType("Upper"));
        assertFalse(h.isValidTaskType("with space"));
        assertFalse(h.isValidTaskType('q"uote'));
        assertFalse(h.isValidTaskType("back\\slash"));
    }

    function test_toDataURI() public view {
        assertEq(h.toDataURI('{"a":1}'), "data:application/json;base64,eyJhIjoxfQ==");
    }

    function test_mockUsdc_hasSixDecimalsAndOpenMint() public {
        MockUSDC usdc = new MockUSDC();
        assertEq(usdc.decimals(), 6);
        address anyone = makeAddr("anyone");
        vm.prank(anyone);
        usdc.mint(anyone, 5e6);
        assertEq(usdc.balanceOf(anyone), 5e6);
        assertEq(usdc.totalSupply(), 5e6);
    }

    function _num(bytes memory s, uint256 start, uint256 len) private pure returns (uint256 n) {
        for (uint256 i = start; i < start + len; ++i) {
            n = n * 10 + (uint8(s[i]) - 48);
        }
    }

    function _daysFromCivil(uint256 y, uint256 m, uint256 d) private pure returns (uint256) {
        if (m <= 2) y -= 1;
        uint256 era = y / 400;
        uint256 yoe = y - era * 400;
        uint256 mp = m > 2 ? m - 3 : m + 9;
        uint256 doy = (153 * mp + 2) / 5 + d - 1;
        uint256 doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
        return era * 146097 + doe - 719468;
    }
}
