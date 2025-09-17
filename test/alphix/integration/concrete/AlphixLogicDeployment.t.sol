// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/* FORGE IMPORTS */
import {Test, console} from "forge-std/Test.sol";

/* OZ IMPORTS (Upgradeable + Proxy) */
import {Ownable2StepUpgradeable, OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/* SOLMATE IMPORTS */
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

/* UNISWAP V4 IMPORTS */
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";

/* LOCAL IMPORTS */
import {BaseAlphixTest} from "../../BaseAlphix.t.sol";
import {Alphix} from "../../../../src/Alphix.sol";
import {AlphixLogic} from "../../../../src/AlphixLogic.sol";
import {IAlphixLogic} from "../../../../src/interfaces/IAlphixLogic.sol";
import {MockAlphixLogic} from "../../../utils/mocks/MockAlphixLogic.sol";

/**
 * @title AlphixLogicDeploymentTest
 * @author Alphix
 * @notice Tests for AlphixLogic deployment, initialization, UUPS upgrades and admin paths
 */
contract AlphixLogicDeploymentTest is BaseAlphixTest {
    /* TESTS */

    /* Alphix Logic Initialization */

    /**
     * @notice AlphixLogic's constructor should disable initializers.
     */
    function test_constructor_disablesInitializers() public {
        AlphixLogic freshImpl = new AlphixLogic();
        vm.expectRevert(abi.encodeWithSelector(Initializable.InvalidInitialization.selector));
        freshImpl.initialize(
            owner,
            address(hook),
            INITIAL_FEE,
            stableBounds,
            standardBounds,
            volatileBounds
        );
    }

    /**
     * @notice Properly deploying a new logic and checks it behaves as expected.
     */
    function test_initialize_success() public {
        AlphixLogic freshImpl = new AlphixLogic();
        ERC1967Proxy freshProxy = new ERC1967Proxy(
            address(freshImpl),
            abi.encodeCall(
                freshImpl.initialize,
                (
                    owner,
                    address(hook),
                    INITIAL_FEE,
                    stableBounds,
                    standardBounds,
                    volatileBounds
                )
            )
        );

        IAlphixLogic freshLogic = IAlphixLogic(address(freshProxy));

        assertEq(freshLogic.getAlphixHook(), address(hook));
        assertEq(freshLogic.getFee(key), 3000);
        assertEq(Ownable2StepUpgradeable(address(freshProxy)).owner(), owner);

        IAlphixLogic.PoolTypeBounds memory stable = freshLogic.getPoolTypeBounds(IAlphixLogic.PoolType.STABLE);
        assertEq(stable.minFee, stableBounds.minFee);
        assertEq(stable.maxFee, stableBounds.maxFee);
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
                freshImpl.initialize,
                (
                    address(0),
                    address(hook),
                    INITIAL_FEE,
                    stableBounds,
                    standardBounds,
                    volatileBounds
                )
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
            abi.encodeCall(
                freshImpl.initialize,
                (
                    owner,
                    address(0),
                    INITIAL_FEE,
                    stableBounds,
                    standardBounds,
                    volatileBounds
                )
            )
        );
    }

    /**
     * @notice Calling AlphixLogic initialize should revert after it was already deployed.
     */ 
    function test_initialize_canOnlyBeCalledOnce() public {
        vm.expectRevert(abi.encodeWithSelector(Initializable.InvalidInitialization.selector));
        AlphixLogic(address(logicProxy)).initialize(
            owner,
            address(hook),
            INITIAL_FEE,
            stableBounds,
            standardBounds,
            volatileBounds
        );
    }

    /**
     * @notice Calling AlphixLogic initialize should revert with invalid bounds (max fee too big).
     */ 
    function test_initialize_revertsOnInvalidBoundsMax() public {
        AlphixLogic freshImpl = new AlphixLogic();
        IAlphixLogic.PoolTypeBounds memory badStandardBounds = IAlphixLogic.PoolTypeBounds({
            minFee: 1,
            maxFee: uint24(LPFeeLibrary.MAX_LP_FEE + 1)
        });

        vm.expectRevert(abi.encodeWithSelector(IAlphixLogic.InvalidFeeBounds.selector, badStandardBounds.minFee, badStandardBounds.maxFee));
        new ERC1967Proxy(
            address(freshImpl),
            abi.encodeCall(
                freshImpl.initialize,
                (
                    owner,
                    address(hook),
                    INITIAL_FEE,
                    stableBounds,
                    badStandardBounds,
                    volatileBounds
                )
            )
        );
    }

    /**
     * @notice Calling AlphixLogic initialize should revert with invalid bounds (min fee greater than max fee).
     */ 
    function test_initialize_revertsOnInvalidBoundsMinGtMax() public {
        AlphixLogic freshImpl = new AlphixLogic();
        IAlphixLogic.PoolTypeBounds memory badStableBounds = IAlphixLogic.PoolTypeBounds({
            minFee: 2000,
            maxFee: 1000
        });

        vm.expectRevert(abi.encodeWithSelector(IAlphixLogic.InvalidFeeBounds.selector, badStableBounds.minFee, badStableBounds.maxFee));
        new ERC1967Proxy(
            address(freshImpl),
            abi.encodeCall(
                freshImpl.initialize,
                (
                    owner,
                    address(hook),
                    INITIAL_FEE,
                    badStableBounds,
                    standardBounds,
                    volatileBounds
                )
            )
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
     */ 
    function test_authorizeUpgrade_success() public {
        AlphixLogic newImpl = new AlphixLogic();

        vm.prank(owner);
        AlphixLogic(address(logicProxy)).upgradeToAndCall(address(newImpl), bytes(""));

        assertEq(logic.getFee(key), 3000);
    }

    /**
     * @notice Logic upgrade to MockAlphixLogic adds storage and changes behavior while preserving original storage
     */
    function test_upgradeToMockLogicAddStorageAndChangesBehavior() public {
        // Verify original behavior
        assertEq(logic.getFee(key), 3000, "original getFee should return 3000");
        
        // Modify bounds through hook to test storage preservation
        IAlphixLogic.PoolTypeBounds memory newVolatile = IAlphixLogic.PoolTypeBounds({
            minFee: 1500,
            maxFee: 30000
        });
        vm.prank(owner);
        hook.setPoolTypeBounds(IAlphixLogic.PoolType.VOLATILE, newVolatile);
        
        // Verify bounds were set
        IAlphixLogic.PoolTypeBounds memory preUpgrade = logic.getPoolTypeBounds(IAlphixLogic.PoolType.VOLATILE);
        assertEq(preUpgrade.minFee, newVolatile.minFee, "pre-upgrade volatile minFee");
        assertEq(preUpgrade.maxFee, newVolatile.maxFee, "pre-upgrade volatile maxFee");
        
        // Deploy MockAlphixLogic with appended storage
        MockAlphixLogic mockImpl = new MockAlphixLogic();
        
        // Upgrade to mock implementation WITH reinitializer to set mockFee to 2000
        vm.prank(owner);
        AlphixLogic(address(logicProxy)).upgradeToAndCall(
            address(mockImpl),
            abi.encodeCall(MockAlphixLogic.initializeV2, (uint24(2000)))
        );
        
        // Verify behavior changed - getFee now returns 2000 from appended storage
        assertEq(logic.getFee(key), 2000, "upgraded getFee should return 2000 from appended storage");
        
        // Verify all original storage was preserved - bounds should remain the same
        IAlphixLogic.PoolTypeBounds memory postUpgrade = logic.getPoolTypeBounds(IAlphixLogic.PoolType.VOLATILE);
        assertEq(postUpgrade.minFee, newVolatile.minFee, "post-upgrade volatile minFee preserved");
        assertEq(postUpgrade.maxFee, newVolatile.maxFee, "post-upgrade volatile maxFee preserved");
        
        // Verify other bounds were preserved too
        IAlphixLogic.PoolTypeBounds memory stablePost = logic.getPoolTypeBounds(IAlphixLogic.PoolType.STABLE);
        assertEq(stablePost.minFee, stableBounds.minFee, "stable bounds preserved");
        assertEq(stablePost.maxFee, stableBounds.maxFee, "stable bounds preserved");

        IAlphixLogic.PoolTypeBounds memory standardPost = logic.getPoolTypeBounds(IAlphixLogic.PoolType.STANDARD);
        assertEq(standardPost.minFee, standardBounds.minFee, "standard bounds preserved");
        assertEq(standardPost.maxFee, standardBounds.maxFee, "standard bounds preserved");
        
        // Verify hook address preserved
        assertEq(logic.getAlphixHook(), address(hook), "hook address preserved");
        
        // Verify owner preserved
        assertEq(Ownable2StepUpgradeable(address(logicProxy)).owner(), owner, "owner preserved");
    }

    /**
    * @notice Test upgrade without reinitializer maintains pre-upgrade behavior until mockFee is set
    */
    function test_upgradeToMockLogicWithoutReinitializerKeepsOriginalBehavior() public {
        // Verify original behavior
        assertEq(logic.getFee(key), 3000, "original getFee should return 3000");
        
        // Deploy and upgrade without reinitializer
        MockAlphixLogic mockImpl = new MockAlphixLogic();
        vm.prank(owner);
        AlphixLogic(address(logicProxy)).upgradeToAndCall(address(mockImpl), bytes(""));
        
        // Verify behavior remains 3000 (fallback when mockFee is zero)
        assertEq(logic.getFee(key), 3000, "should still return 3000 when mockFee uninitialized");
        
        // Verify all original storage preserved
        IAlphixLogic.PoolTypeBounds memory stablePost = logic.getPoolTypeBounds(IAlphixLogic.PoolType.STABLE);
        assertEq(stablePost.minFee, stableBounds.minFee, "stable bounds preserved");
        assertEq(stablePost.maxFee, stableBounds.maxFee, "stable bounds preserved");
        
        assertEq(logic.getAlphixHook(), address(hook), "hook address preserved");
        assertEq(Ownable2StepUpgradeable(address(logicProxy)).owner(), owner, "owner preserved");
    }



    /**
     * @notice Logic upgrade to a random contract reverts.
     */
    function test_authorizeUpgrade_revertsOnInvalidInterface() public {
        MockERC20 invalidImpl = new MockERC20("Invalid", "INV", 18);

        vm.prank(owner);
        vm.expectRevert(); // IAlphixLogic.InvalidLogicContract.selector
        AlphixLogic(address(logicProxy)).upgradeToAndCall(address(invalidImpl), bytes(""));
    }

    /**
     * @notice Logic upgrade reverts when caller is not owner.
     */
    function test_authorizeUpgrade_revertsOnNonOwner() public {
        AlphixLogic newImpl = new AlphixLogic();

        vm.prank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, user1)
        );
        AlphixLogic(address(logicProxy)).upgradeToAndCall(address(newImpl), bytes(""));
    }

    /**
     * @notice Tests that logic upgrade preserves state.
     */
    function test_upgradePreservesState() public {
        IAlphixLogic.PoolTypeBounds memory newVol = IAlphixLogic.PoolTypeBounds({minFee: 2000, maxFee: 25000});
        vm.prank(owner);
        hook.setPoolTypeBounds(IAlphixLogic.PoolType.VOLATILE, newVol);

        IAlphixLogic.PoolTypeBounds memory pre = logic.getPoolTypeBounds(IAlphixLogic.PoolType.VOLATILE);
        assertEq(pre.minFee, newVol.minFee);
        assertEq(pre.maxFee, newVol.maxFee);

        AlphixLogic newImpl = new AlphixLogic();
        vm.prank(owner);
        AlphixLogic(address(logicProxy)).upgradeToAndCall(address(newImpl), bytes(""));

        IAlphixLogic.PoolTypeBounds memory post = logic.getPoolTypeBounds(IAlphixLogic.PoolType.VOLATILE);
        assertEq(post.minFee, newVol.minFee);
        assertEq(post.maxFee, newVol.maxFee);
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
        vm.expectRevert(
            abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, user1)
        );
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
        vm.expectRevert(
            abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, user1)
        );
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
     * @notice Tests AlphixLogic's getFee returns the expected value.
     */
    function test_getFee() public view {
        assertEq(logic.getFee(key), 3000);
    }

    /**
     * @notice Tests AlphixLogic's getPoolTypeBounds returns the expected value.
     */
    function test_getPoolTypeBounds_stable() public view {
        IAlphixLogic.PoolTypeBounds memory bounds = logic.getPoolTypeBounds(IAlphixLogic.PoolType.STABLE);
        assertEq(bounds.minFee, stableBounds.minFee);
        assertEq(bounds.maxFee, stableBounds.maxFee);
    }

    /**
     * @notice Tests AlphixLogic's getPoolTypeBounds returns the expected value.
     */
    function test_getPoolTypeBounds_standard() public view {
        IAlphixLogic.PoolTypeBounds memory bounds = logic.getPoolTypeBounds(IAlphixLogic.PoolType.STANDARD);
        assertEq(bounds.minFee, standardBounds.minFee);
        assertEq(bounds.maxFee, standardBounds.maxFee);
    }

    /**
     * @notice Tests AlphixLogic's getPoolTypeBounds returns the expected value.
     */
    function test_getPoolTypeBounds_volatile() public view {
        IAlphixLogic.PoolTypeBounds memory bounds = logic.getPoolTypeBounds(IAlphixLogic.PoolType.VOLATILE);
        assertEq(bounds.minFee, volatileBounds.minFee);
        assertEq(bounds.maxFee, volatileBounds.maxFee);
    }
}
