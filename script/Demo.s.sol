// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {TaskEscrow} from "../contracts/TaskEscrow.sol";
import {ITaskEscrow} from "../contracts/interfaces/ITaskEscrow.sol";
import {FulfillmentFeedback} from "../contracts/libraries/FulfillmentFeedback.sol";
import {MockUSDC} from "../contracts/mocks/MockUSDC.sol";
import {IdentityRegistry} from "../contracts/registries/IdentityRegistry.sol";
import {ReputationRegistry} from "../contracts/registries/ReputationRegistry.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {Script, console2} from "forge-std/Script.sol";

/// @notice Optional local Foundry replay of the two-wallet demo ("Guild logo, 5 USDC, 24h").
///         Not the Path A critical path. Path A is the split TypeScript commands, one wallet per process.
///         This script signs createOrder, fund, and release/fail with the buyer key, and agree plus
///         submitDelivery with the expert key. `createOrder.verifier` is the buyer address.
///
///         BUYER_PRIVATE_KEY / EXPERT_PRIVATE_KEY
///                         default to anvil accounts 1–2 on chain 31337, required elsewhere
///         SCENARIO        pass (default) | fail | timeout (stops once Funded; refundExpired after deliverBy)
///         APPROVAL_MODE   user (default) | approve_for_me
///         EXPERT_AGENT_ID / BUYER_AGENT_ID   reuse agents registered by an earlier run
contract Demo is Script {
    uint256 public constant PRICE = 5e6;
    uint32 public constant REVIEW_WINDOW = 1 hours;
    string public constant TASK_TYPE = "design.logo";

    uint256 internal constant ANVIL_KEY_1 = 0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d;
    uint256 internal constant ANVIL_KEY_2 = 0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a;

    /// @dev RFC 8785 canonical form of the PRODUCT_SPEC criteria template, split around the two values the
    ///      run fills in (`approval_mode`, `deadline`); keys are sorted, so the pieces concatenate in order.
    string internal constant SPEC_HEAD = unicode'{"acceptance_criteria":[{"check":"file_format == png && size >= 1024",'
        unicode'"id":"c1","type":"auto"},{"check":"包含文字 \'Guild\'，风格简洁","id":"c2","type":"llm"}],'
        unicode'"approval_mode":"';
    string internal constant SPEC_MID = '","deadline":"';
    string internal constant SPEC_TAIL = '","deliverables":[{"count":3,"kind":"image/png","min_size":"1024x1024"}],'
        '"price":{"amount":"5","token":"USDC"},"revisions":1,"task_type":"design.logo","title":"Guild logo"}';

    string internal constant DELIVERY_MANIFEST =
        '{"files":["ipfs://guild-logo-1.png","ipfs://guild-logo-2.png","ipfs://guild-logo-3.png"]}';
    string internal constant RESULT_PASS =
        '{"passed":true,"results":[{"id":"c1","passed":true},{"id":"c2","passed":true}]}';
    string internal constant RESULT_FAIL =
        '{"passed":false,"results":[{"id":"c1","passed":true},{"id":"c2","passed":false}]}';

    enum Scenario {
        Pass,
        Fail,
        Timeout
    }

    struct Config {
        uint256 buyerKey;
        uint256 expertKey;
        Scenario scenario;
        bool approveForMe;
        uint256 expertAgentId;
        uint256 buyerAgentId;
    }

    struct Result {
        uint256 orderId;
        uint256 expertAgentId;
        uint256 buyerAgentId;
        ITaskEscrow.Status status;
    }

    error UnsupportedChain(uint256 chainId);
    error UnknownScenario(string scenario);

    function run() external returns (Result memory) {
        string memory json =
            vm.readFile(string.concat(vm.projectRoot(), "/deployments/", vm.toString(block.chainid), ".json"));
        return execute(TaskEscrow(vm.parseJsonAddress(json, ".taskEscrow")), configFromEnv());
    }

    function configFromEnv() public view returns (Config memory c) {
        bool anvil = block.chainid == 31337;
        c.buyerKey = anvil ? vm.envOr("BUYER_PRIVATE_KEY", ANVIL_KEY_1) : vm.envUint("BUYER_PRIVATE_KEY");
        c.expertKey = anvil ? vm.envOr("EXPERT_PRIVATE_KEY", ANVIL_KEY_2) : vm.envUint("EXPERT_PRIVATE_KEY");
        bytes32 scenario = keccak256(bytes(vm.envOr("SCENARIO", string("pass"))));
        if (scenario == keccak256("pass")) c.scenario = Scenario.Pass;
        else if (scenario == keccak256("fail")) c.scenario = Scenario.Fail;
        else if (scenario == keccak256("timeout")) c.scenario = Scenario.Timeout;
        else revert UnknownScenario(vm.envString("SCENARIO"));
        c.approveForMe = keccak256(bytes(vm.envOr("APPROVAL_MODE", string("user")))) == keccak256("approve_for_me");
        c.expertAgentId = vm.envOr("EXPERT_AGENT_ID", uint256(0));
        c.buyerAgentId = vm.envOr("BUYER_AGENT_ID", uint256(0));
    }

    function execute(TaskEscrow escrow, Config memory c) public returns (Result memory r) {
        if (block.chainid != 31337 && block.chainid != 10143 && block.chainid != 84532) {
            revert UnsupportedChain(block.chainid);
        }
        IdentityRegistry identity = IdentityRegistry(address(escrow.identityRegistry()));
        MockUSDC usdc = MockUSDC(address(escrow.paymentToken()));
        address buyer = vm.addr(c.buyerKey);

        r.expertAgentId = c.expertAgentId;
        if (r.expertAgentId == 0) {
            vm.broadcast(c.expertKey);
            r.expertAgentId = identity.register("ipfs://guild-design-bot.json");
        }
        r.buyerAgentId = c.buyerAgentId;
        if (r.buyerAgentId == 0) {
            vm.broadcast(c.buyerKey);
            r.buyerAgentId = identity.register("ipfs://guild-buyer-agent.json");
        }
        uint64 deliverBy = uint64(vm.getBlockTimestamp() + 24 hours);
        string memory specJson = specJsonFor(c.approveForMe, deliverBy);
        bytes32 specHash = keccak256(bytes(specJson));

        vm.startBroadcast(c.buyerKey);
        if (usdc.balanceOf(buyer) < PRICE) usdc.mint(buyer, 100e6);
        usdc.approve(address(escrow), PRICE);
        r.orderId = escrow.createOrder(
            ITaskEscrow.OrderParams({
                sellerAgentId: r.expertAgentId,
                buyerAgentId: r.buyerAgentId,
                verifier: buyer,
                amount: PRICE,
                specHash: specHash,
                specURI: _dataURI(specJson),
                taskType: TASK_TYPE,
                deliverBy: deliverBy,
                reviewWindow: REVIEW_WINDOW,
                approvalMode: c.approveForMe ? ITaskEscrow.ApprovalMode.ApproveForMe : ITaskEscrow.ApprovalMode.User
            })
        );
        vm.stopBroadcast();

        vm.broadcast(c.expertKey);
        escrow.agree(r.orderId, specHash);

        vm.broadcast(c.buyerKey);
        escrow.fund(r.orderId);

        if (c.scenario == Scenario.Timeout) return _finish(escrow, r, c);

        vm.broadcast(c.expertKey);
        escrow.submitDelivery(r.orderId, keccak256(bytes(DELIVERY_MANIFEST)), _dataURI(DELIVERY_MANIFEST));

        bool pass = c.scenario == Scenario.Pass;
        string memory result = pass ? RESULT_PASS : RESULT_FAIL;
        vm.startBroadcast(c.buyerKey);
        if (pass) escrow.release(r.orderId, keccak256(bytes(result)), _dataURI(result));
        else escrow.fail(r.orderId, keccak256(bytes(result)), _dataURI(result));
        vm.stopBroadcast();

        if (pass && !c.approveForMe) {
            vm.broadcast(c.buyerKey);
            escrow.approve(r.orderId);
        }

        return _finish(escrow, r, c);
    }

    function _finish(TaskEscrow escrow, Result memory r, Config memory c) internal view returns (Result memory) {
        r.status = escrow.getOrder(r.orderId).status;
        _report(escrow, r, vm.addr(c.expertKey));
        return r;
    }

    function specJsonFor(bool approveForMe, uint64 deliverBy) public pure returns (string memory) {
        return string.concat(
            SPEC_HEAD,
            approveForMe ? "approve_for_me" : "user",
            SPEC_MID,
            FulfillmentFeedback.isoTimestamp(deliverBy),
            SPEC_TAIL
        );
    }

    function _report(TaskEscrow escrow, Result memory r, address expert) internal view {
        ReputationRegistry reputation = ReputationRegistry(address(escrow.reputationRegistry()));
        address[] memory clients = new address[](1);
        clients[0] = address(escrow);
        (uint64 count, int128 passRate,) = reputation.getSummary(r.expertAgentId, clients, "expert", TASK_TYPE);

        console2.log("orderId", r.orderId);
        console2.log("status (3=Funded, 6=Released, 7=Refunded)", uint8(r.status));
        console2.log("expert agentId", r.expertAgentId);
        console2.log("buyer agentId", r.buyerAgentId);
        console2.log("verifier", escrow.getOrder(r.orderId).verifier);
        console2.log("expert payment token balance", escrow.paymentToken().balanceOf(expert));
        console2.log("expert design.logo feedback count (via escrow)", count);
        console2.log("expert design.logo pass rate %", uint256(int256(passRate)));
    }

    function _dataURI(string memory json) internal pure returns (string memory) {
        return string.concat("data:application/json;base64,", Base64.encode(bytes(json)));
    }
}
