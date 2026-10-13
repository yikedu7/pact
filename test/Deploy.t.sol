// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {TaskEscrow} from "../contracts/TaskEscrow.sol";
import {MockUSDC} from "../contracts/mocks/MockUSDC.sol";
import {IdentityRegistry} from "../contracts/registries/IdentityRegistry.sol";
import {ReputationRegistry} from "../contracts/registries/ReputationRegistry.sol";
import {Deploy} from "../script/Deploy.s.sol";
import {Test} from "forge-std/Test.sol";

contract DeployTest is Test {
    Deploy internal deployer;

    function setUp() public {
        deployer = new Deploy();
        vm.setEnv("WRITE_DEPLOYMENT", "false");
        vm.setEnv("PRIVATE_KEY", "0");
        vm.setEnv("PAYMENT_TOKEN", vm.toString(address(0)));
        vm.setEnv("IDENTITY_REGISTRY", vm.toString(address(0)));
        vm.setEnv("REPUTATION_REGISTRY", vm.toString(address(0)));
        vm.setEnv("MOCK_USDC_MINT", "0");
        vm.setEnv("DEFAULT_VERIFIER", vm.toString(makeAddr("verifierBot")));
    }

    function test_deploy_freshStackWithMockUsdc() public {
        address recipient = makeAddr("recipient");
        vm.setEnv("MOCK_USDC_MINT", "1000000000");
        vm.setEnv("MOCK_USDC_MINT_TO", vm.toString(recipient));

        Deploy.Deployment memory d = deployer.run();

        assertTrue(d.mockPaymentToken);
        assertEq(MockUSDC(d.paymentToken).decimals(), 6);
        assertEq(MockUSDC(d.paymentToken).balanceOf(recipient), 1_000e6);
        assertEq(ReputationRegistry(d.reputationRegistry).getIdentityRegistry(), d.identityRegistry);

        TaskEscrow escrow = TaskEscrow(d.taskEscrow);
        assertEq(address(escrow.paymentToken()), d.paymentToken);
        assertEq(address(escrow.identityRegistry()), d.identityRegistry);
        assertEq(address(escrow.reputationRegistry()), d.reputationRegistry);
        assertEq(escrow.defaultVerifier(), makeAddr("verifierBot"));
        assertEq(d.defaultVerifier, makeAddr("verifierBot"));
    }

    function test_deploy_reusesExistingTokenAndRegistries() public {
        MockUSDC token = new MockUSDC();
        IdentityRegistry identity = new IdentityRegistry();
        ReputationRegistry reputation = new ReputationRegistry(address(identity));
        vm.setEnv("PAYMENT_TOKEN", vm.toString(address(token)));
        vm.setEnv("IDENTITY_REGISTRY", vm.toString(address(identity)));
        vm.setEnv("REPUTATION_REGISTRY", vm.toString(address(reputation)));

        Deploy.Deployment memory d = deployer.run();

        assertFalse(d.mockPaymentToken);
        assertEq(d.paymentToken, address(token));
        assertEq(d.identityRegistry, address(identity));
        assertEq(d.reputationRegistry, address(reputation));
        assertEq(address(TaskEscrow(d.taskEscrow).reputationRegistry()), address(reputation));
    }

    function test_deploy_reputationRequiresIdentity() public {
        vm.setEnv("REPUTATION_REGISTRY", vm.toString(makeAddr("rep")));
        vm.expectRevert(Deploy.ReputationWithoutIdentity.selector);
        deployer.run();
    }

    function test_deploy_supportedChains() public {
        assertTrue(deployer.isSupportedChain(10143)); // Monad testnet
        assertTrue(deployer.isSupportedChain(84532)); // Base Sepolia
        assertTrue(deployer.isSupportedChain(31337)); // Anvil
        assertFalse(deployer.isSupportedChain(1)); // Ethereum mainnet
        assertFalse(deployer.isSupportedChain(143)); // Monad mainnet
        assertFalse(deployer.isSupportedChain(8453)); // Base mainnet
    }

    function test_deploy_refusesMainnet() public {
        vm.chainId(8453);
        vm.expectRevert(abi.encodeWithSelector(Deploy.UnsupportedChain.selector, 8453));
        deployer.run();
    }

    function test_deploy_onMonadTestnetChainId() public {
        vm.chainId(10143);
        Deploy.Deployment memory d = deployer.run();
        assertTrue(d.taskEscrow.code.length > 0);
    }
}
