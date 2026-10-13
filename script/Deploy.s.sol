// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {TaskEscrow} from "../contracts/TaskEscrow.sol";
import {IIdentityRegistry} from "../contracts/interfaces/IIdentityRegistry.sol";
import {IReputationRegistry} from "../contracts/interfaces/IReputationRegistry.sol";
import {MockUSDC} from "../contracts/mocks/MockUSDC.sol";
import {IdentityRegistry} from "../contracts/registries/IdentityRegistry.sol";
import {ReputationRegistry} from "../contracts/registries/ReputationRegistry.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Script, console2} from "forge-std/Script.sol";

/// @notice Deploys the escrow stack. The target chain comes from `--rpc-url` (e.g. `monad_testnet`,
///         `base_sepolia`); everything else is read from the environment:
///
///         PRIVATE_KEY           optional; otherwise use `--account` / `--private-key` / `--ledger`
///         PAYMENT_TOKEN         optional ERC-20; when unset a MockUSDC is deployed
///         IDENTITY_REGISTRY     optional existing ERC-8004 identity registry to reuse
///         REPUTATION_REGISTRY   optional existing reputation registry (requires IDENTITY_REGISTRY)
///         DEFAULT_VERIFIER      protocol verifier bot address (defaults to the deployer)
///         MOCK_USDC_MINT        optional amount (6 decimals) to mint when MockUSDC is deployed
///         MOCK_USDC_MINT_TO     optional recipient of that mint (defaults to the deployer)
///         WRITE_DEPLOYMENT      default true; writes deployments/<chainId>.json
contract Deploy is Script {
    uint256 internal constant MONAD_TESTNET = 10143;
    uint256 internal constant BASE_SEPOLIA = 84532;
    uint256 internal constant ANVIL = 31337;

    struct Deployment {
        address deployer;
        address paymentToken;
        address identityRegistry;
        address reputationRegistry;
        address taskEscrow;
        address defaultVerifier;
        bool mockPaymentToken;
        uint256 startBlock;
    }

    error UnsupportedChain(uint256 chainId);
    error ReputationWithoutIdentity();

    function run() external returns (Deployment memory d) {
        if (!isSupportedChain(block.chainid)) revert UnsupportedChain(block.chainid);

        d.paymentToken = vm.envOr("PAYMENT_TOKEN", address(0));
        d.identityRegistry = vm.envOr("IDENTITY_REGISTRY", address(0));
        d.reputationRegistry = vm.envOr("REPUTATION_REGISTRY", address(0));
        if (d.reputationRegistry != address(0) && d.identityRegistry == address(0)) revert ReputationWithoutIdentity();

        uint256 privateKey = vm.envOr("PRIVATE_KEY", uint256(0));
        d.deployer = privateKey == 0 ? msg.sender : vm.addr(privateKey);
        d.defaultVerifier = vm.envOr("DEFAULT_VERIFIER", d.deployer);
        d.startBlock = block.number;

        if (privateKey == 0) vm.startBroadcast();
        else vm.startBroadcast(privateKey);

        if (d.paymentToken == address(0)) {
            MockUSDC usdc = new MockUSDC();
            d.paymentToken = address(usdc);
            d.mockPaymentToken = true;
            uint256 mintAmount = vm.envOr("MOCK_USDC_MINT", uint256(0));
            if (mintAmount != 0) usdc.mint(vm.envOr("MOCK_USDC_MINT_TO", d.deployer), mintAmount);
        }
        if (d.identityRegistry == address(0)) {
            d.identityRegistry = address(new IdentityRegistry());
        }
        if (d.reputationRegistry == address(0)) {
            d.reputationRegistry = address(new ReputationRegistry(d.identityRegistry));
        }
        d.taskEscrow = address(
            new TaskEscrow(
                IERC20(d.paymentToken),
                IIdentityRegistry(d.identityRegistry),
                IReputationRegistry(d.reputationRegistry),
                d.defaultVerifier
            )
        );

        vm.stopBroadcast();

        _log(d);
        if (vm.envOr("WRITE_DEPLOYMENT", true)) _write(d);
    }

    /// @notice Testnets only: this stack must never custody real funds.
    function isSupportedChain(uint256 chainId) public pure returns (bool) {
        return chainId == MONAD_TESTNET || chainId == BASE_SEPOLIA || chainId == ANVIL;
    }

    function _log(Deployment memory d) internal pure {
        console2.log("deployer           ", d.deployer);
        console2.log("paymentToken       ", d.paymentToken, d.mockPaymentToken ? "(MockUSDC)" : "");
        console2.log("identityRegistry   ", d.identityRegistry);
        console2.log("reputationRegistry ", d.reputationRegistry);
        console2.log("taskEscrow         ", d.taskEscrow);
        console2.log("defaultVerifier    ", d.defaultVerifier);
        if (d.defaultVerifier == d.deployer) console2.log("WARNING: DEFAULT_VERIFIER unset, using the deployer");
    }

    function _write(Deployment memory d) internal {
        string memory key = "deployment";
        vm.serializeUint(key, "chainId", block.chainid);
        vm.serializeUint(key, "startBlock", d.startBlock);
        vm.serializeAddress(key, "deployer", d.deployer);
        vm.serializeAddress(key, "paymentToken", d.paymentToken);
        vm.serializeBool(key, "mockPaymentToken", d.mockPaymentToken);
        vm.serializeAddress(key, "identityRegistry", d.identityRegistry);
        vm.serializeAddress(key, "reputationRegistry", d.reputationRegistry);
        vm.serializeAddress(key, "defaultVerifier", d.defaultVerifier);
        string memory json = vm.serializeAddress(key, "taskEscrow", d.taskEscrow);

        string memory path = string.concat(vm.projectRoot(), "/deployments/", vm.toString(block.chainid), ".json");
        vm.writeJson(json, path);
        console2.log("wrote", path);
    }
}
