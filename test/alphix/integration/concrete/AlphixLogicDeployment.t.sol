// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/* FORGE IMPORTS */
import {Test, console} from "forge-std/Test.sol";

/* OZ IMPORTS (Upgradeable + Proxy) */
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/* SOLMATE IMPORTS */
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

/* UNISWAP V4 IMPORTS */
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";

/* LOCAL IMPORTS */
import {BaseAlphixTest} from "../../BaseAlphix.t.sol";
import {AlphixLogic} from "../../../../src/AlphixLogic.sol";
import {IAlphixLogic} from "../../../../src/interfaces/IAlphixLogic.sol";
import {MockAlphixLogic} from "../../../utils/mocks/MockAlphixLogic.sol";
import {DynamicFeeLib} from "../../../../src/libraries/DynamicFee.sol";

/**
 * @title AlphixLogicDeploymentTest
 * @author Alphix
 * @notice Tests for AlphixLogic deployment, initialization, UUPS upgrades and admin paths
 * @dev Updated to unified PoolTypeParams and ratio-aware compute/finalize flow
 */
contract AlphixLogicDeploymentTest is BaseAlphixTest {
    using StateLibrary for IPoolManager;

    /* TESTS */

    /* Alphix Logic Initialization */

    /**
     * @notice AlphixLogic's constructor should disable initializers.
     */
    function test_constructor_disablesInitializers() public {
        AlphixLogic freshImpl = new AlphixLogic();
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        // initialize(owner, hook, baseFee, stable, standard, volatile)
        freshImpl.initialize(owner, address(hook), stableParams, standardParams, volatileParams);
    }

    /**
     * @notice Properly deploying a new logic and checks it behaves as expected.
     * @dev Verifies per-type params seeded from initializer and owner is correct.
     */
    function test_initialize_success() public {
        AlphixLogic freshImpl = new AlphixLogic();
        ERC1967Proxy freshProxy = new ERC1967Proxy(
            address(freshImpl),
            abi.encodeCall(freshImpl.initialize, (owner, address(hook), stableParams, standardParams, volatileParams))
        );
        IAlphixLogic freshLogic = IAlphixLogic(address(freshProxy));

        assertEq(freshLogic.getAlphixHook(), address(hook), "hook mismatch");
        assertEq(Ownable2StepUpgradeable(address(freshProxy)).owner(), owner, "owner mismatch");

        DynamicFeeLib.PoolTypeParams memory ps = freshLogic.getPoolTypeParams(IAlphixLogic.PoolType.STABLE);
        assertEq(ps.minFee, stableParams.minFee, "minFee mismatch");
        assertEq(ps.maxFee, stableParams.maxFee, "maxFee mismatch");
        assertEq(ps.baseMaxFeeDelta, stableParams.baseMaxFeeDelta, "baseMaxFeeDelta mismatch");
        assertEq(ps.lookbackPeriod, stableParams.lookbackPeriod, "lookbackPeriod mismatch");
        assertEq(ps.minPeriod, stableParams.minPeriod, "minPeriod mismatch");
        assertEq(ps.ratioTolerance, stableParams.ratioTolerance, "ratioTolerance mismatch");
        assertEq(ps.linearSlope, stableParams.linearSlope, "linearSlope mismatch");
        assertEq(ps.upperSideFactor, stableParams.upperSideFactor, "upperSideFactor mismatch");
        assertEq(ps.lowerSideFactor, stableParams.lowerSideFactor, "lowerSideFactor mismatch");
    }

    /**
     * @notice Initializing a logic should fail when setting owner as address(0).
     */
    function test_initialize_revertsOnZeroOwner() public {
        AlphixLogic freshImpl = new AlphixLogic();

        vm.expectRevert(IAlphixLogic.InvalidAddress.selector);
        new ERC1967Proxy(
            address(freshImpl),
            abi.encodeCall(
                freshImpl.initialize, (address(0), address(hook), stableParams, standardParams, volatileParams)
            )
        );
    }

    /**
     * @notice Initializing a logic should fail when setting hook as address(0).
     */
    function test_initialize_revertsOnZeroHook() public {
        AlphixLogic freshImpl = new AlphixLogic();

        vm.expectRevert(IAlphixLogic.InvalidAddress.selector);
        new ERC1967Proxy(
            address(freshImpl),
            abi.encodeCall(freshImpl.initialize, (owner, address(0), stableParams, standardParams, volatileParams))
        );
    }

    /**
     * @notice Calling AlphixLogic initialize should revert after it was already deployed.
     */
    function test_initialize_canOnlyBeCalledOnce() public {
        vm.expectRevert(abi.encodeWithSelector(Initializable.InvalidInitialization.selector));
        AlphixLogic(address(logicProxy)).initialize(owner, address(hook), stableParams, standardParams, volatileParams);
    }

    /**
     * @notice Calling initialize should revert with invalid params (minFee > maxFee).
     */
    function test_initialize_revertsOnInvalidParams_minGtMax() public {
        AlphixLogic freshImpl = new AlphixLogic();
        DynamicFeeLib.PoolTypeParams memory badStable = stableParams;
        badStable.minFee = badStable.maxFee + 1;

        vm.expectRevert(
            abi.encodeWithSelector(IAlphixLogic.InvalidFeeBounds.selector, badStable.minFee, badStable.maxFee)
        );
        new ERC1967Proxy(
            address(freshImpl),
            abi.encodeCall(freshImpl.initialize, (owner, address(hook), badStable, standardParams, volatileParams))
        );
    }

    /**
     * @notice Calling initialize should revert when maxFee is over LPFeeLibrary.MAX_LP_FEE.
     */
    function test_initialize_revertsOnInvalidParams_maxTooHigh() public {
        AlphixLogic freshImpl = new AlphixLogic();
        DynamicFeeLib.PoolTypeParams memory badStandard = standardParams;
        badStandard.maxFee = uint24(LPFeeLibrary.MAX_LP_FEE + 1);

        vm.expectRevert(
            abi.encodeWithSelector(IAlphixLogic.InvalidFeeBounds.selector, badStandard.minFee, badStandard.maxFee)
        );
        new ERC1967Proxy(
            address(freshImpl),
            abi.encodeCall(freshImpl.initialize, (owner, address(hook), stableParams, badStandard, volatileParams))
        );
    }

    /* ERC165 */

    /**
     * @notice Testing if logic proxy support interface check works as intended.
     */
    function test_supportsInterface() public view {
        assertTrue(IERC165(address(logicProxy)).supportsInterface(type(IAlphixLogic).interfaceId));
        assertTrue(IERC165(address(logicProxy)).supportsInterface(type(IERC165).interfaceId));
        assertFalse(IERC165(address(logicProxy)).supportsInterface(bytes4(0x12345678)));
    }

    /* UUPS UPGRADE (OZ v5) */

    /**
     * @notice Tests if logic upgrade works (implem is the same)
     * @dev Verifies state and owner unchanged after upgrade.
     */
    function test_authorizeUpgrade_success() public {
        // Snapshot current fee from PoolManager
        (,,, uint24 preFee) = poolManager.getSlot0(poolId);

        AlphixLogic newImpl = new AlphixLogic();
        vm.prank(owner);
        AlphixLogic(address(logicProxy)).upgradeToAndCall(address(newImpl), bytes(""));

        (,,, uint24 postFee) = poolManager.getSlot0(poolId);
        assertEq(postFee, preFee, "fee changed across same-impl upgrade");

        assertEq(Ownable2StepUpgradeable(address(logicProxy)).owner(), owner, "owner changed");
        assertEq(logic.getAlphixHook(), address(hook), "hook changed");
    }

    /**
     * @notice Logic upgrade to MockAlphixLogic adds storage and changes behavior while preserving original storage
     * @dev After upgrade and reinitializer, poke through the hook should adopt the mock fee.
     */
    function test_upgradeToMockLogicAddStorageAndChangesBehavior() public {
        // Pre-upgrade: adjust a per-type param to test state preservation
        DynamicFeeLib.PoolTypeParams memory newVol = volatileParams;
        newVol.minFee = 1500;
        newVol.maxFee = 30000;
        vm.prank(owner);
        hook.setPoolTypeParams(IAlphixLogic.PoolType.VOLATILE, newVol);

        DynamicFeeLib.PoolTypeParams memory preVol = logic.getPoolTypeParams(IAlphixLogic.PoolType.VOLATILE);
        assertEq(preVol.minFee, newVol.minFee, "pre-upgrade minFee");
        assertEq(preVol.maxFee, newVol.maxFee, "pre-upgrade maxFee");

        // Upgrade to mock and set mockFee via reinitializer
        MockAlphixLogic mockImpl = new MockAlphixLogic();
        vm.prank(owner);
        AlphixLogic(address(logicProxy)).upgradeToAndCall(
            address(mockImpl), abi.encodeCall(MockAlphixLogic.initializeV2, (uint24(2000)))
        );

        // Advance time past cooldown period (1 day + buffer)
        vm.warp(block.timestamp + 1 days + 1);

        // Poke with any ratio to trigger compute->manager update->finalize
        vm.prank(owner);
        hook.poke(key, 6e17); // 60%

        // Read fee from PoolManager, should reflect mockFee=2000 set by mock
        (,,, uint24 newFee) = poolManager.getSlot0(poolId);
        assertEq(newFee, 2000, "mock fee not applied");

        // Verify state preserved
        DynamicFeeLib.PoolTypeParams memory postVol = logic.getPoolTypeParams(IAlphixLogic.PoolType.VOLATILE);
        assertEq(postVol.minFee, newVol.minFee, "post-upgrade minFee preserved");
        assertEq(postVol.maxFee, newVol.maxFee, "post-upgrade maxFee preserved");
        assertEq(logic.getAlphixHook(), address(hook), "hook preserved");
        assertEq(Ownable2StepUpgradeable(address(logicProxy)).owner(), owner, "owner preserved");
    }

    /**
     * @notice Test upgrade without reinitializer maintains pre-upgrade fee until mockFee is set
     */
    function test_upgradeToMockLogicWithoutReinitializerKeepsOriginalBehavior() public {
        // Snapshot fee
        (,,, uint24 preFee) = poolManager.getSlot0(poolId);

        // Upgrade without setting mock fee
        MockAlphixLogic mockImpl = new MockAlphixLogic();
        vm.prank(owner);
        AlphixLogic(address(logicProxy)).upgradeToAndCall(address(mockImpl), bytes(""));

        // Advance time past cooldown period (1 day + buffer)
        vm.warp(block.timestamp + 1 days + 1);

        // Poke; mock returns live fee when mockFee == 0
        vm.prank(owner);
        hook.poke(key, 5e17);

        (,,, uint24 postFee) = poolManager.getSlot0(poolId);
        assertEq(postFee, preFee, "fee should remain unchanged when mockFee is zero");

        // State intact
        DynamicFeeLib.PoolTypeParams memory st = logic.getPoolTypeParams(IAlphixLogic.PoolType.STABLE);
        assertEq(st.minFee, stableParams.minFee, "stable params preserved");
        assertEq(st.maxFee, stableParams.maxFee, "stable params preserved");
        assertEq(logic.getAlphixHook(), address(hook), "hook preserved");
        assertEq(Ownable2StepUpgradeable(address(logicProxy)).owner(), owner, "owner preserved");
    }

    /**
     * @notice Logic upgrade to a random contract reverts.
     */
    function test_authorizeUpgrade_revertsOnInvalidInterface() public {
        MockERC20 invalidImpl = new MockERC20("Invalid", "INV", 18);

        vm.prank(owner);
        vm.expectRevert(); // InvalidLogicContract
        AlphixLogic(address(logicProxy)).upgradeToAndCall(address(invalidImpl), bytes(""));
    }

    /**
     * @notice Logic upgrade reverts when caller is not owner.
     */
    function test_authorizeUpgrade_revertsOnNonOwner() public {
        AlphixLogic newImpl = new AlphixLogic();

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, user1));
        AlphixLogic(address(logicProxy)).upgradeToAndCall(address(newImpl), bytes(""));
    }

    /* PAUSE/UNPAUSE */

    /**
     * @notice Tests AlphixLogic pause should succeed if done correctly.
     */
    function test_pause_success() public {
        vm.prank(owner);
        AlphixLogic(address(logicProxy)).pause();

        assertTrue(PausableUpgradeable(address(logicProxy)).paused());
    }

    /**
     * @notice Tests AlphixLogic pause revert if caller not owner.
     */
    function test_pause_revertsOnNonOwner() public {
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, user1));
        AlphixLogic(address(logicProxy)).pause();
    }

    /**
     * @notice Tests AlphixLogic unpause should succeed if done correctly.
     */
    function test_unpause_success() public {
        vm.prank(owner);
        AlphixLogic(address(logicProxy)).pause();

        vm.prank(owner);
        AlphixLogic(address(logicProxy)).unpause();

        assertFalse(PausableUpgradeable(address(logicProxy)).paused());
    }

    /**
     * @notice Tests AlphixLogic unpause revert if caller not owner.
     */
    function test_unpause_revertsOnNonOwner() public {
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, user1));
        AlphixLogic(address(logicProxy)).unpause();
    }

    /* GETTERS */

    /**
     * @notice Tests AlphixLogic's getAlphixHook returns the expected hook.
     */
    function test_getAlphixHook() public view {
        assertEq(logic.getAlphixHook(), address(hook));
    }

    /**
     * @notice Tests AlphixLogic's getPoolTypeParams returns the expected values for STABLE.
     */
    function test_getPoolTypeParams_stable() public view {
        DynamicFeeLib.PoolTypeParams memory p = logic.getPoolTypeParams(IAlphixLogic.PoolType.STABLE);
        assertEq(p.minFee, stableParams.minFee);
        assertEq(p.maxFee, stableParams.maxFee);
        assertEq(p.lookbackPeriod, stableParams.lookbackPeriod);
        assertEq(p.minPeriod, stableParams.minPeriod);
    }

    /**
     * @notice Tests AlphixLogic's getPoolTypeParams returns the expected values for STANDARD.
     */
    function test_getPoolTypeParams_standard() public view {
        DynamicFeeLib.PoolTypeParams memory p = logic.getPoolTypeParams(IAlphixLogic.PoolType.STANDARD);
        assertEq(p.minFee, standardParams.minFee);
        assertEq(p.maxFee, standardParams.maxFee);
        assertEq(p.lookbackPeriod, standardParams.lookbackPeriod);
        assertEq(p.minPeriod, standardParams.minPeriod);
    }

    /**
     * @notice Tests AlphixLogic's getPoolTypeParams returns the expected values for VOLATILE.
     */
    function test_getPoolTypeParams_volatile() public view {
        DynamicFeeLib.PoolTypeParams memory p = logic.getPoolTypeParams(IAlphixLogic.PoolType.VOLATILE);
        assertEq(p.minFee, volatileParams.minFee);
        assertEq(p.maxFee, volatileParams.maxFee);
        assertEq(p.lookbackPeriod, volatileParams.lookbackPeriod);
        assertEq(p.minPeriod, volatileParams.minPeriod);
    }
}
