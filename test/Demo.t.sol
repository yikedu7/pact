// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ITaskEscrow} from "../contracts/interfaces/ITaskEscrow.sol";
import {Demo} from "../script/Demo.s.sol";
import {BaseTest} from "./utils/BaseTest.sol";

contract DemoTest is BaseTest {
    Demo internal demo;
    uint256 internal buyerKey;
    uint256 internal expertKey;

    function setUp() public override {
        super.setUp();
        vm.chainId(31337);
        demo = new Demo();
        (, buyerKey) = makeAddrAndKey("demoBuyer");
        (, expertKey) = makeAddrAndKey("demoExpert");
    }

    function _config(Demo.Scenario scenario, bool approveForMe) internal view returns (Demo.Config memory c) {
        c.buyerKey = buyerKey;
        c.expertKey = expertKey;
        c.scenario = scenario;
        c.approveForMe = approveForMe;
    }

    function test_demo_specJsonMatchesCanonicalTemplate() public view {
        assertEq(demo.specJsonFor(false, deliverBy), SPEC_JSON);
    }

    /// @dev Reference vector for the TypeScript agents: `keccak256(toBytes(canonicalize(spec)))` with the
    ///      `canonicalize` (RFC 8785) npm package and viem, for the template in BaseTest.
    function test_specHash_matchesOffChainJcsVector() public view {
        assertEq(SPEC_HASH, 0xf17141832feb6a9f4c7f33ea2cc83f40f40d4f6ef18fe8445a2cd6a5fc7f83ac);
        assertEq(escrow.hashSpec(bytes(SPEC_JSON)), SPEC_HASH);
    }

    function test_demo_passWithUserApproval() public {
        Demo.Result memory r = demo.execute(escrow, _config(Demo.Scenario.Pass, false));
        assertEq(uint8(r.status), uint8(ITaskEscrow.Status.Released));
        assertEq(usdc.balanceOf(vm.addr(expertKey)), PRICE);
        assertEq(usdc.balanceOf(address(escrow)), 0);
        (uint64 count, int128 rate,) = reputation.getSummary(r.expertAgentId, _clients(), "expert", TASK_TYPE);
        assertEq(count, 1);
        assertEq(rate, 100);
        assertEq(escrow.getOrder(r.orderId).specHash, keccak256(bytes(demo.specJsonFor(false, deliverBy))));
        assertEq(escrow.getOrder(r.orderId).verifier, vm.addr(buyerKey));
    }

    function test_demo_passWithApproveForMe() public {
        Demo.Result memory r = demo.execute(escrow, _config(Demo.Scenario.Pass, true));
        assertEq(uint8(r.status), uint8(ITaskEscrow.Status.Released));
        assertEq(usdc.balanceOf(vm.addr(expertKey)), PRICE);
        assertEq(escrow.getOrder(r.orderId).specHash, keccak256(bytes(demo.specJsonFor(true, deliverBy))));
    }

    function test_demo_failRefundsBuyer() public {
        Demo.Result memory r = demo.execute(escrow, _config(Demo.Scenario.Fail, false));
        assertEq(uint8(r.status), uint8(ITaskEscrow.Status.Refunded));
        assertEq(usdc.balanceOf(vm.addr(expertKey)), 0);
        assertEq(usdc.balanceOf(vm.addr(buyerKey)), 100e6);
        (uint64 count, int128 rate,) = reputation.getSummary(r.expertAgentId, _clients(), "expert", TASK_TYPE);
        assertEq(count, 1);
        assertEq(rate, 0);
    }

    function test_demo_reusesRegisteredAgents() public {
        Demo.Result memory first = demo.execute(escrow, _config(Demo.Scenario.Pass, false));
        Demo.Config memory c = _config(Demo.Scenario.Pass, false);
        c.expertAgentId = first.expertAgentId;
        c.buyerAgentId = first.buyerAgentId;
        Demo.Result memory second = demo.execute(escrow, c);
        assertEq(second.expertAgentId, first.expertAgentId);
        assertEq(second.buyerAgentId, first.buyerAgentId);
        assertEq(identity.totalAgents(), first.buyerAgentId);
        assertEq(identity.ownerOf(first.buyerAgentId), vm.addr(buyerKey));
        assertEq(second.orderId, first.orderId + 1);
        (uint64 count,,) = reputation.getSummary(first.expertAgentId, _clients(), "expert", TASK_TYPE);
        assertEq(count, 2);
    }

    function test_demo_refusesMainnet() public {
        vm.chainId(143);
        Demo.Config memory c = _config(Demo.Scenario.Pass, false);
        vm.expectRevert(abi.encodeWithSelector(Demo.UnsupportedChain.selector, 143));
        demo.execute(escrow, c);
    }

    function test_demo_timeoutStopsFundedThenRefunds() public {
        Demo.Result memory r = demo.execute(escrow, _config(Demo.Scenario.Timeout, false));
        assertEq(uint8(r.status), uint8(ITaskEscrow.Status.Funded));
        assertEq(usdc.balanceOf(address(escrow)), PRICE);

        vm.warp(deliverBy + 1);
        escrow.refundExpired(r.orderId);
        assertEq(uint8(escrow.getOrder(r.orderId).status), uint8(ITaskEscrow.Status.Refunded));
        assertEq(usdc.balanceOf(vm.addr(buyerKey)), 100e6);
        (uint64 count, int128 rate,) = reputation.getSummary(r.expertAgentId, _clients(), "expert", TASK_TYPE);
        assertEq(count, 1);
        assertEq(rate, 0);
    }

    function test_demo_configFromEnvDefaultsToAnvilAccounts() public view {
        Demo.Config memory c = demo.configFromEnv();
        assertEq(vm.addr(c.buyerKey), 0x70997970C51812dc3A010C7d01b50e0d17dc79C8);
        assertEq(vm.addr(c.expertKey), 0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC);
    }
}
