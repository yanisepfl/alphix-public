// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/* FORGE IMPORTS */

/* OZ IMPORTS */
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {IAccessManaged} from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";

/* UNISWAP V4 IMPORTS */
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {Constants} from "v4-core/test/utils/Constants.sol";
import {Currency} from "v4-core/src/types/Currency.sol";

/* LOCAL IMPORTS */
import {BaseAlphixTest} from "../../BaseAlphix.t.sol";
import {IAlphixLogic} from "../../../../src/interfaces/IAlphixLogic.sol";
import {IRegistry} from "../../../../src/Registry.sol";

/**
 * @title AccessAndOwnershipFuzzTest
 * @author Alphix
 * @notice Fuzz tests for ownership transfers and AccessManager-gated permissions
 * @dev Tests access control across various addresses and role configurations
 */
contract AccessAndOwnershipFuzzTest is BaseAlphixTest {
    /* ========================================================================== */
    /*                          OWNERSHIP TRANSFER TESTS                         */
    /* ========================================================================== */

    /**
     * @notice Fuzz test that hook ownership can be transferred to any valid address
     * @dev Tests two-step ownership transfer with fuzzed new owner address
     * @param newOwnerSeed Seed to generate new owner address
     */
    function testFuzz_hook_ownership_transfer_to_any_address(uint256 newOwnerSeed) public {
        // Generate a valid address (not zero, not owner) - bound already excludes zero
        address newOwner = address(uint160(bound(newOwnerSeed, 1, type(uint160).max)));
        vm.assume(newOwner != owner);

        // Initiate transfer
        vm.prank(owner);
        hook.transferOwnership(newOwner);

        // Pending owner should be set
        assertEq(hook.pendingOwner(), newOwner, "pending owner mismatch");

        // Accept transfer
        vm.prank(newOwner);
        hook.acceptOwnership();

        // Verify ownership transferred
        assertEq(hook.owner(), newOwner, "owner not transferred");
        assertEq(hook.pendingOwner(), address(0), "pending owner should be cleared");
    }

    /**
     * @notice Fuzz test that logic ownership can be transferred to any valid address
     * @dev Tests two-step ownership transfer for logic proxy
     * @param newOwnerSeed Seed to generate new owner address
     */
    function testFuzz_logic_ownership_transfer_to_any_address(uint256 newOwnerSeed) public {
        // Generate a valid address - bound already excludes zero
        address newOwner = address(uint160(bound(newOwnerSeed, 1, type(uint160).max)));
        vm.assume(newOwner != owner);

        // Initiate transfer
        vm.prank(owner);
        Ownable2StepUpgradeable(address(logicProxy)).transferOwnership(newOwner);

        // Accept transfer
        vm.prank(newOwner);
        Ownable2StepUpgradeable(address(logicProxy)).acceptOwnership();

        // Verify ownership transferred
        assertEq(Ownable2StepUpgradeable(address(logicProxy)).owner(), newOwner, "logic owner not transferred");
    }

    /**
     * @notice Fuzz test that unauthorized addresses cannot accept ownership
     * @dev Tests that only pending owner can accept
     * @param unauthorizedSeed Seed for unauthorized address
     */
    function testFuzz_ownership_transfer_rejects_unauthorized_acceptor(uint256 unauthorizedSeed) public {
        address newOwner = makeAddr("newOwner");
        address unauthorized = address(uint160(bound(unauthorizedSeed, 1, type(uint160).max)));

        // Ensure unauthorized is not the pending owner
        vm.assume(unauthorized != newOwner);
        vm.assume(unauthorized != address(0));

        // Initiate transfer
        vm.prank(owner);
        hook.transferOwnership(newOwner);

        // Unauthorized cannot accept
        vm.prank(unauthorized);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, unauthorized));
        hook.acceptOwnership();
    }

    /* ========================================================================== */
    /*                        ACCESS MANAGER ROLE TESTS                          */
    /* ========================================================================== */

    /**
     * @notice Fuzz test that REGISTRAR_ROLE can be granted to any address
     * @dev Tests role granting with fuzzed addresses
     * @param granteeDelay Role execution delay
     * @param granteeSeed Seed for grantee address
     */
    function testFuzz_access_manager_can_grant_role_to_any_address(uint32 granteeDelay, uint256 granteeSeed) public {
        address grantee = address(uint160(bound(granteeSeed, 1, type(uint160).max)));
        vm.assume(grantee != address(0));

        // Grant role
        vm.prank(owner);
        accessManager.grantRole(REGISTRAR_ROLE, grantee, granteeDelay);

        // Verify role granted
        (bool isMember, uint32 executionDelay) = accessManager.hasRole(REGISTRAR_ROLE, grantee);
        assertTrue(isMember, "role should be granted");
        assertEq(executionDelay, granteeDelay, "delay mismatch");
    }

    /**
     * @notice Fuzz test that role holders can register contracts
     * @dev Tests contract registration with fuzzed contract addresses
     * @param contractSeed Seed for contract address to register
     */
    function testFuzz_role_holder_can_register_contract(uint256 contractSeed) public {
        address contractAddr = address(uint160(bound(contractSeed, 1, type(uint160).max)));
        vm.assume(contractAddr != address(0));

        // Grant role to owner
        vm.prank(owner);
        accessManager.grantRole(REGISTRAR_ROLE, owner, 0);

        // Register contract
        vm.prank(owner);
        registry.registerContract(IRegistry.ContractKey.Alphix, contractAddr);

        // Verify registration
        assertEq(registry.getContract(IRegistry.ContractKey.Alphix), contractAddr, "contract not registered");
    }

    /**
     * @notice Fuzz test that role revocation works correctly
     * @dev Tests that revoked role holders cannot perform protected actions
     * @param granteeSeed Seed for grantee address
     */
    function testFuzz_revoked_role_cannot_register(uint256 granteeSeed) public {
        address grantee = address(uint160(bound(granteeSeed, 1, type(uint160).max)));
        vm.assume(grantee != address(0));

        // Grant role
        vm.prank(owner);
        accessManager.grantRole(REGISTRAR_ROLE, grantee, 0);

        // Revoke role
        vm.prank(owner);
        accessManager.revokeRole(REGISTRAR_ROLE, grantee);

        // Should not be able to register - expect AccessManaged revert
        vm.prank(grantee);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, grantee));
        registry.registerContract(IRegistry.ContractKey.AlphixLogic, address(logicProxy));
    }

    /**
     * @notice Fuzz test that multiple roles can be granted with different delays
     * @dev Tests role system with multiple grantees and delays
     * @param grantee1Seed Seed for first grantee
     * @param grantee2Seed Seed for second grantee
     * @param delay1 Delay for first grantee
     * @param delay2 Delay for second grantee
     */
    function testFuzz_multiple_role_grants_with_delays(
        uint256 grantee1Seed,
        uint256 grantee2Seed,
        uint32 delay1,
        uint32 delay2
    ) public {
        address grantee1 = address(uint160(bound(grantee1Seed, 1, type(uint160).max / 2)));
        address grantee2 = address(uint160(bound(grantee2Seed, type(uint160).max / 2 + 1, type(uint160).max)));

        vm.assume(grantee1 != address(0) && grantee2 != address(0));
        vm.assume(grantee1 != grantee2);

        // Grant roles
        vm.startPrank(owner);
        accessManager.grantRole(REGISTRAR_ROLE, grantee1, delay1);
        accessManager.grantRole(REGISTRAR_ROLE, grantee2, delay2);
        vm.stopPrank();

        // Verify both roles
        (bool isMember1, uint32 executionDelay1) = accessManager.hasRole(REGISTRAR_ROLE, grantee1);
        (bool isMember2, uint32 executionDelay2) = accessManager.hasRole(REGISTRAR_ROLE, grantee2);

        assertTrue(isMember1, "grantee1 should have role");
        assertTrue(isMember2, "grantee2 should have role");
        assertEq(executionDelay1, delay1, "delay1 mismatch");
        assertEq(executionDelay2, delay2, "delay2 mismatch");
    }

    /* ========================================================================== */
    /*                      POOL REGISTRATION FUZZ TESTS                         */
    /* ========================================================================== */

    /**
     * @notice Fuzz test that pools can be registered with various parameters
     * @dev Tests pool registration with fuzzed pool types and fees
     * @param poolTypeIndex Pool type index (0-2)
     * @param initialFee Initial fee for pool
     * @param targetRatio Target ratio for pool
     */
    function testFuzz_pool_registration_with_various_params(
        uint8 poolTypeIndex,
        uint24 initialFee,
        uint256 targetRatio
    ) public {
        // Bound parameters
        poolTypeIndex = uint8(bound(poolTypeIndex, 0, 2));
        initialFee = uint24(bound(initialFee, 100, 10000));
        targetRatio = bound(targetRatio, 1e17, 2e18);

        // Map to pool type
        IAlphixLogic.PoolType poolType;
        if (poolTypeIndex == 0) poolType = IAlphixLogic.PoolType.STABLE;
        else if (poolTypeIndex == 1) poolType = IAlphixLogic.PoolType.STANDARD;
        else poolType = IAlphixLogic.PoolType.VOLATILE;

        // Grant role
        vm.prank(owner);
        accessManager.grantRole(REGISTRAR_ROLE, owner, 0);

        // Create pool key
        (Currency c0, Currency c1) = deployCurrencyPairWithDecimals(18, 18);
        PoolKey memory freshKey = PoolKey({
            currency0: c0, currency1: c1, fee: LPFeeLibrary.DYNAMIC_FEE_FLAG, tickSpacing: 30, hooks: IHooks(hook)
        });

        // Register pool
        vm.prank(owner);
        registry.registerPool(freshKey, poolType, initialFee, targetRatio);

        // Verify registration
        IRegistry.PoolInfo memory info = registry.getPoolInfo(freshKey.toId());
        assertEq(info.hooks, address(hook), "hooks mismatch");
        assertEq(uint8(info.poolType), uint8(poolType), "pool type mismatch");
        assertEq(info.initialFee, initialFee, "fee mismatch");
        assertEq(info.initialTargetRatio, targetRatio, "ratio mismatch");
    }

    /* ========================================================================== */
    /*                    CALLER AUTHORIZATION FUZZ TESTS                        */
    /* ========================================================================== */

    /**
     * @notice Fuzz test that only hook address can call onlyAlphixHook functions
     * @dev Tests that random addresses cannot call protected functions
     * @param callerSeed Seed for caller address
     * @param valueSeed Seed for parameter value
     */
    function testFuzz_only_hook_can_call_protected_functions(uint256 callerSeed, uint256 valueSeed) public {
        address caller = address(uint160(bound(callerSeed, 1, type(uint160).max)));
        uint256 value = bound(valueSeed, 1, 1e20);

        // Assume caller is not the hook
        vm.assume(caller != address(hook));

        // Should revert with InvalidCaller
        vm.prank(caller);
        vm.expectRevert(IAlphixLogic.InvalidCaller.selector);
        logic.setGlobalMaxAdjRate(value);
    }

    /**
     * @notice Fuzz test that hook ownership changes don't affect onlyAlphixHook
     * @dev Verifies that hook address (not owner) is what matters
     * @param newOwnerSeed Seed for new hook owner
     */
    function testFuzz_hook_ownership_change_doesnt_affect_hook_calls(uint256 newOwnerSeed) public {
        address newOwner = address(uint160(bound(newOwnerSeed, 1, type(uint160).max)));
        vm.assume(newOwner != owner);
        vm.assume(newOwner != address(0));
        vm.assume(newOwner != address(hook));

        // Transfer hook ownership
        vm.prank(owner);
        hook.transferOwnership(newOwner);
        vm.prank(newOwner);
        hook.acceptOwnership();

        // New owner still can't call hook-protected functions directly
        vm.prank(newOwner);
        vm.expectRevert(IAlphixLogic.InvalidCaller.selector);
        logic.setGlobalMaxAdjRate(1e19);

        // But hook address can
        vm.prank(address(hook));
        logic.setGlobalMaxAdjRate(1e19); // Should succeed
    }

    /**
     * @notice Fuzz test that unauthorized addresses cannot perform owner-only actions
     * @dev Tests owner-only functions with fuzzed unauthorized addresses
     * @param unauthorizedSeed Seed for unauthorized address
     */
    function testFuzz_unauthorized_cannot_perform_owner_actions(uint256 unauthorizedSeed) public {
        address unauthorized = address(uint160(bound(unauthorizedSeed, 1, type(uint160).max)));
        vm.assume(unauthorized != owner);

        // Create fresh pool
        (PoolKey memory freshKey,) =
            _newUninitializedPoolWithHook(18, 18, defaultTickSpacing, Constants.SQRT_PRICE_1_1, hook);

        // Unauthorized cannot initialize pool
        vm.prank(unauthorized);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, unauthorized));
        hook.initializePool(freshKey, INITIAL_FEE, INITIAL_TARGET_RATIO, IAlphixLogic.PoolType.STANDARD);
    }
}
