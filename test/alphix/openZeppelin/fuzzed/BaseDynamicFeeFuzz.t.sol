// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/* FORGE IMPORTS */
import {Test} from "forge-std/Test.sol";

/* UNISWAP V4 IMPORTS */
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {Constants} from "v4-core/test/utils/Constants.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

/* LOCAL IMPORTS */
import {BaseDynamicFee} from "../../../../src/BaseDynamicFee.sol";
import {DynamicFeeLib} from "../../../../src/libraries/DynamicFee.sol";
import {BaseAlphixTest} from "../../BaseAlphix.t.sol";

/**
 * @title TestBaseDynamicFeeFuzz
 * @notice Concrete implementation of BaseDynamicFee for fuzz testing purposes
 */
contract TestBaseDynamicFeeFuzz is BaseDynamicFee {
    uint24 public mockFee = 500;
    uint256 public mockOldTargetRatio = 5e17;
    uint256 public mockNewTargetRatio = 6e17;
    DynamicFeeLib.OOBState public mockOOBState;
    bool public shouldRevertOnGetFee = false;

    constructor(IPoolManager _poolManager) BaseDynamicFee(_poolManager) {}

    function _getFee(PoolKey calldata, uint256)
        internal
        view
        override
        returns (uint24, uint256, uint256, DynamicFeeLib.OOBState memory)
    {
        if (shouldRevertOnGetFee) {
            revert("Mock revert in _getFee");
        }
        return (mockFee, mockOldTargetRatio, mockNewTargetRatio, mockOOBState);
    }

    // Test helper functions
    function setMockValues(
        uint24 _fee,
        uint256 _oldTargetRatio,
        uint256 _newTargetRatio,
        DynamicFeeLib.OOBState memory _oobState
    ) external {
        mockFee = _fee;
        mockOldTargetRatio = _oldTargetRatio;
        mockNewTargetRatio = _newTargetRatio;
        mockOOBState = _oobState;
    }

    function getMockOOBState() external view returns (DynamicFeeLib.OOBState memory) {
        return mockOOBState;
    }

    function setShouldRevertOnGetFee(bool _shouldRevert) external {
        shouldRevertOnGetFee = _shouldRevert;
    }

    // Expose internal functions for testing
    function testAfterInitialize(address sender, PoolKey calldata key, uint160 sqrtPriceX96, int24 tick)
        external
        returns (bytes4)
    {
        return _afterInitialize(sender, key, sqrtPriceX96, tick);
    }
}

/**
 * @title BaseDynamicFeeFuzzTest
 * @author Alphix
 * @notice Fuzz tests for OpenZeppelin BaseDynamicFee abstract contract
 * @dev Comprehensive fuzz tests to ensure BaseDynamicFee works correctly across all valid parameter ranges
 */
contract BaseDynamicFeeFuzzTest is BaseAlphixTest {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    TestBaseDynamicFeeFuzz public testHook;
    PoolKey public dynamicFeeKey;
    PoolKey public staticFeeKey;

    /* FUZZING CONSTRAINTS */

    // Fee bounds
    uint24 constant MIN_FEE_FUZZ = 1;
    uint24 constant MAX_FEE_FUZZ = LPFeeLibrary.MAX_LP_FEE;

    // Ratio bounds
    uint256 constant MIN_RATIO_FUZZ = 1e12; // 0.0001%
    uint256 constant MAX_RATIO_FUZZ = 1e24; // 1,000,000x

    // OOB state bounds
    uint24 constant MIN_OOB_HITS_FUZZ = 0;
    uint24 constant MAX_OOB_HITS_FUZZ = 100;

    /**
     * @notice Sets up test environment with test hook
     */
    function setUp() public override {
        super.setUp();

        // Deploy test hook at a valid hook address
        address hookAddress = _computeTestHookAddress();
        deployCodeTo(
            "test/alphix/openZeppelin/fuzzed/BaseDynamicFeeFuzz.t.sol:TestBaseDynamicFeeFuzz",
            abi.encode(poolManager),
            hookAddress
        );
        testHook = TestBaseDynamicFeeFuzz(hookAddress);

        // Create pool keys
        dynamicFeeKey = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(testHook));
        staticFeeKey = PoolKey(currency0, currency1, 3000, 60, IHooks(testHook));
    }

    /* ========================================================================== */
    /*                       CONSTRUCTOR AND INITIALIZATION TESTS                */
    /* ========================================================================== */

    /**
     * @notice Fuzz test that constructor sets pool manager correctly
     * @dev Pool manager should always be correctly assigned regardless of deployment
     */
    function testFuzz_constructor_setsPoolManager() public view {
        assertEq(address(testHook.poolManager()), address(poolManager), "Pool manager should be set correctly");
    }

    /**
     * @notice Fuzz test that hook permissions are correct
     * @dev BaseDynamicFee should only have afterInitialize enabled
     */
    function testFuzz_getHookPermissions_correctDefaults() public view {
        Hooks.Permissions memory permissions = testHook.getHookPermissions();

        // BaseDynamicFee should only have afterInitialize enabled by default
        assertFalse(permissions.beforeInitialize, "beforeInitialize should be false");
        assertTrue(permissions.afterInitialize, "afterInitialize should be true");
        assertFalse(permissions.beforeAddLiquidity, "beforeAddLiquidity should be false");
        assertFalse(permissions.afterAddLiquidity, "afterAddLiquidity should be false");
        assertFalse(permissions.beforeRemoveLiquidity, "beforeRemoveLiquidity should be false");
        assertFalse(permissions.afterRemoveLiquidity, "afterRemoveLiquidity should be false");
        assertFalse(permissions.beforeSwap, "beforeSwap should be false");
        assertFalse(permissions.afterSwap, "afterSwap should be false");
        assertFalse(permissions.beforeDonate, "beforeDonate should be false");
        assertFalse(permissions.afterDonate, "afterDonate should be false");
        assertFalse(permissions.beforeSwapReturnDelta, "beforeSwapReturnDelta should be false");
        assertFalse(permissions.afterSwapReturnDelta, "afterSwapReturnDelta should be false");
        assertFalse(permissions.afterAddLiquidityReturnDelta, "afterAddLiquidityReturnDelta should be false");
        assertFalse(permissions.afterRemoveLiquidityReturnDelta, "afterRemoveLiquidityReturnDelta should be false");
    }

    /* ========================================================================== */
    /*                        AFTER INITIALIZE FUZZ TESTS                        */
    /* ========================================================================== */

    /**
     * @notice Fuzz test that afterInitialize succeeds with dynamic fee pools
     * @dev Should always return correct selector for dynamic fee pools
     * @param sqrtPriceX96 Initial sqrt price
     */
    function testFuzz_afterInitialize_success_withDynamicFee(uint160 sqrtPriceX96) public {
        // Bound to valid sqrt price range
        sqrtPriceX96 = uint160(bound(sqrtPriceX96, TickMath.MIN_SQRT_PRICE, TickMath.MAX_SQRT_PRICE));

        // Initialize the pool first
        poolManager.initialize(dynamicFeeKey, sqrtPriceX96);

        bytes4 result = testHook.testAfterInitialize(address(this), dynamicFeeKey, sqrtPriceX96, 0);
        assertEq(result, testHook.afterInitialize.selector, "Should return correct selector");
    }

    /**
     * @notice Fuzz test that afterInitialize reverts with static fee pools
     * @dev Should always revert with NotDynamicFee error for static fee pools
     * @param staticFee Static fee amount
     */
    function testFuzz_afterInitialize_reverts_withStaticFee(uint24 staticFee) public {
        // Bound to valid static fee range (exclude dynamic fee flag)
        staticFee = uint24(bound(staticFee, 1, LPFeeLibrary.MAX_LP_FEE));
        vm.assume(!LPFeeLibrary.isDynamicFee(staticFee));

        // Create a static fee key that doesn't require pool initialization
        PoolKey memory localStaticKey = PoolKey(currency0, currency1, staticFee, 60, IHooks(address(0)));

        vm.expectRevert(BaseDynamicFee.NotDynamicFee.selector);
        testHook.testAfterInitialize(address(this), localStaticKey, Constants.SQRT_PRICE_1_1, 0);
    }

    /* ========================================================================== */
    /*                          POKE FUNCTION FUZZ TESTS                         */
    /* ========================================================================== */

    /**
     * @notice Fuzz test that poke updates fee correctly with valid parameters
     * @dev Fee should be updated to mock value regardless of input ratio
     * @param mockFee Fee to set in mock
     * @param currentRatio Current ratio to poke with
     * @param oldTargetRatio Old target ratio
     * @param newTargetRatio New target ratio
     */
    function testFuzz_poke_success_validPool(
        uint24 mockFee,
        uint256 currentRatio,
        uint256 oldTargetRatio,
        uint256 newTargetRatio
    ) public {
        // Bound parameters
        mockFee = uint24(bound(mockFee, MIN_FEE_FUZZ, MAX_FEE_FUZZ));
        currentRatio = bound(currentRatio, MIN_RATIO_FUZZ, MAX_RATIO_FUZZ);
        oldTargetRatio = bound(oldTargetRatio, MIN_RATIO_FUZZ, MAX_RATIO_FUZZ);
        newTargetRatio = bound(newTargetRatio, MIN_RATIO_FUZZ, MAX_RATIO_FUZZ);

        // Initialize pool first
        poolManager.initialize(dynamicFeeKey, Constants.SQRT_PRICE_1_1);

        // Set mock values
        DynamicFeeLib.OOBState memory oobState;
        testHook.setMockValues(mockFee, oldTargetRatio, newTargetRatio, oobState);

        // Poke the pool
        testHook.poke(dynamicFeeKey, currentRatio);

        // Check fee was updated
        (,,, uint24 newFee) = poolManager.getSlot0(dynamicFeeKey.toId());
        assertEq(newFee, mockFee, "Fee should be updated to mock value");
    }

    /**
     * @notice Fuzz test that poke works with different OOB states
     * @dev Should handle all valid OOB state combinations
     * @param mockFee Fee to set
     * @param currentRatio Current ratio
     * @param lastOOBWasUpper Whether last OOB was upper
     * @param consecutiveOOBHits Number of consecutive OOB hits
     */
    function testFuzz_poke_success_withDifferentOOBStates(
        uint24 mockFee,
        uint256 currentRatio,
        bool lastOOBWasUpper,
        uint24 consecutiveOOBHits
    ) public {
        // Bound parameters
        mockFee = uint24(bound(mockFee, MIN_FEE_FUZZ, MAX_FEE_FUZZ));
        currentRatio = bound(currentRatio, MIN_RATIO_FUZZ, MAX_RATIO_FUZZ);
        consecutiveOOBHits = uint24(bound(consecutiveOOBHits, MIN_OOB_HITS_FUZZ, MAX_OOB_HITS_FUZZ));

        // Initialize pool
        poolManager.initialize(dynamicFeeKey, Constants.SQRT_PRICE_1_1);

        // Set mock values with OOB state
        DynamicFeeLib.OOBState memory oobState =
            DynamicFeeLib.OOBState({lastOOBWasUpper: lastOOBWasUpper, consecutiveOOBHits: consecutiveOOBHits});
        testHook.setMockValues(mockFee, 5e17, 6e17, oobState);

        // Poke the pool
        testHook.poke(dynamicFeeKey, currentRatio);

        // Check fee was updated
        (,,, uint24 newFee) = poolManager.getSlot0(dynamicFeeKey.toId());
        assertEq(newFee, mockFee, "Fee should be updated to mock value");

        // Verify OOB state was stored
        DynamicFeeLib.OOBState memory retrievedState = testHook.getMockOOBState();
        assertEq(retrievedState.lastOOBWasUpper, lastOOBWasUpper, "OOB state lastOOBWasUpper should match");
        assertEq(retrievedState.consecutiveOOBHits, consecutiveOOBHits, "OOB state consecutiveOOBHits should match");
    }

    /**
     * @notice Fuzz test that poke works with various ratio values
     * @dev Should handle all ratio values from minimum to maximum
     * @param mockFee Fee to set
     * @param currentRatio Current ratio to test
     */
    function testFuzz_poke_withDifferentCurrentRatios(uint24 mockFee, uint256 currentRatio) public {
        // Bound parameters
        mockFee = uint24(bound(mockFee, MIN_FEE_FUZZ, MAX_FEE_FUZZ));
        currentRatio = bound(currentRatio, 0, MAX_RATIO_FUZZ);

        DynamicFeeLib.OOBState memory oobState;
        testHook.setMockValues(mockFee, 5e17, 6e17, oobState);

        // Initialize pool first
        poolManager.initialize(dynamicFeeKey, Constants.SQRT_PRICE_1_1);

        // Poke with ratio
        testHook.poke(dynamicFeeKey, currentRatio);

        // Get fee after poke
        (,,, uint24 feeAfter) = poolManager.getSlot0(dynamicFeeKey.toId());

        // Should use the mock fee regardless of ratio (since this is a mock)
        assertEq(feeAfter, mockFee, "Fee should be mock value for any ratio");
    }

    /**
     * @notice Fuzz test that poke handles zero current ratio
     * @dev Zero ratio should be handled gracefully
     * @param mockFee Fee to set
     * @param oldTargetRatio Old target ratio
     * @param newTargetRatio New target ratio
     */
    function testFuzz_poke_zeroCurrentRatio(uint24 mockFee, uint256 oldTargetRatio, uint256 newTargetRatio) public {
        // Bound parameters
        mockFee = uint24(bound(mockFee, MIN_FEE_FUZZ, MAX_FEE_FUZZ));
        oldTargetRatio = bound(oldTargetRatio, 0, MAX_RATIO_FUZZ);
        newTargetRatio = bound(newTargetRatio, 0, MAX_RATIO_FUZZ);

        DynamicFeeLib.OOBState memory oobState;
        testHook.setMockValues(mockFee, oldTargetRatio, newTargetRatio, oobState);

        // Initialize pool first
        poolManager.initialize(dynamicFeeKey, Constants.SQRT_PRICE_1_1);

        testHook.poke(dynamicFeeKey, 0);

        (,,, uint24 newFee) = poolManager.getSlot0(dynamicFeeKey.toId());
        assertEq(newFee, mockFee, "Should handle zero current ratio");
    }

    /**
     * @notice Fuzz test that poke handles maximum current ratio
     * @dev Maximum ratio values should be handled without overflow
     * @param mockFee Fee to set
     */
    function testFuzz_poke_maxCurrentRatio(uint24 mockFee) public {
        // Bound parameters
        mockFee = uint24(bound(mockFee, MIN_FEE_FUZZ, MAX_FEE_FUZZ));

        uint256 maxRatio = MAX_RATIO_FUZZ;
        DynamicFeeLib.OOBState memory oobState;
        testHook.setMockValues(mockFee, maxRatio, maxRatio, oobState);

        // Initialize pool first
        poolManager.initialize(dynamicFeeKey, Constants.SQRT_PRICE_1_1);

        testHook.poke(dynamicFeeKey, maxRatio);

        (,,, uint24 newFee) = poolManager.getSlot0(dynamicFeeKey.toId());
        assertEq(newFee, mockFee, "Should handle max current ratio");
    }

    /**
     * @notice Fuzz test that poke updates fee correctly in integration scenario
     * @dev Fee should always be updated to the new mock value
     * @param initialFee Initial mock fee
     * @param newFee New mock fee to set
     * @param currentRatio Current ratio to poke with
     */
    function testFuzz_poke_updatesFeeCorrectly(uint24 initialFee, uint24 newFee, uint256 currentRatio) public {
        // Bound parameters
        initialFee = uint24(bound(initialFee, MIN_FEE_FUZZ, MAX_FEE_FUZZ));
        newFee = uint24(bound(newFee, MIN_FEE_FUZZ, MAX_FEE_FUZZ));
        currentRatio = bound(currentRatio, MIN_RATIO_FUZZ, MAX_RATIO_FUZZ);

        // Initialize pool
        poolManager.initialize(dynamicFeeKey, Constants.SQRT_PRICE_1_1);

        // Set initial fee
        DynamicFeeLib.OOBState memory oobState;
        testHook.setMockValues(initialFee, 5e17, 6e17, oobState);
        testHook.poke(dynamicFeeKey, currentRatio);

        // Get fee before second poke
        (,,, uint24 feeBefore) = poolManager.getSlot0(dynamicFeeKey.toId());
        assertEq(feeBefore, initialFee, "Initial fee should be set");

        // Update to new fee
        testHook.setMockValues(newFee, 5e17, 6e17, oobState);
        testHook.poke(dynamicFeeKey, currentRatio);

        // Get fee after poke
        (,,, uint24 feeAfter) = poolManager.getSlot0(dynamicFeeKey.toId());

        assertEq(feeAfter, newFee, "Fee should be updated to new value");
    }

    /**
     * @notice Fuzz test that poke handles boundary fee values
     * @dev Should handle minimum and maximum fee values correctly
     * @param useMinFee Whether to test min fee (true) or max fee (false)
     * @param currentRatio Current ratio
     */
    function testFuzz_poke_boundaryFeeValues(uint24, /* feeAtBoundary */ bool useMinFee, uint256 currentRatio) public {
        // Set fee to exact boundary
        uint24 mockFee = useMinFee ? MIN_FEE_FUZZ : MAX_FEE_FUZZ;
        currentRatio = bound(currentRatio, MIN_RATIO_FUZZ, MAX_RATIO_FUZZ);

        DynamicFeeLib.OOBState memory oobState;
        testHook.setMockValues(mockFee, 5e17, 6e17, oobState);

        // Initialize pool
        poolManager.initialize(dynamicFeeKey, Constants.SQRT_PRICE_1_1);

        // Poke with boundary fee
        testHook.poke(dynamicFeeKey, currentRatio);

        (,,, uint24 newFee) = poolManager.getSlot0(dynamicFeeKey.toId());
        assertEq(newFee, mockFee, "Should handle boundary fee values");
    }

    /**
     * @notice Fuzz test that mock values are set and retrieved correctly
     * @dev All mock values should be stored and retrievable accurately
     * @param mockFee Fee to set
     * @param oldTargetRatio Old target ratio
     * @param newTargetRatio New target ratio
     * @param lastOOBWasUpper OOB state flag
     * @param consecutiveOOBHits OOB hit count
     */
    function testFuzz_mockValues_setAndRetrieve(
        uint24 mockFee,
        uint256 oldTargetRatio,
        uint256 newTargetRatio,
        bool lastOOBWasUpper,
        uint24 consecutiveOOBHits
    ) public {
        // Bound parameters
        mockFee = uint24(bound(mockFee, MIN_FEE_FUZZ, MAX_FEE_FUZZ));
        oldTargetRatio = bound(oldTargetRatio, MIN_RATIO_FUZZ, MAX_RATIO_FUZZ);
        newTargetRatio = bound(newTargetRatio, MIN_RATIO_FUZZ, MAX_RATIO_FUZZ);
        consecutiveOOBHits = uint24(bound(consecutiveOOBHits, MIN_OOB_HITS_FUZZ, MAX_OOB_HITS_FUZZ));

        DynamicFeeLib.OOBState memory expectedOOBState =
            DynamicFeeLib.OOBState({lastOOBWasUpper: lastOOBWasUpper, consecutiveOOBHits: consecutiveOOBHits});

        // Set mock values
        testHook.setMockValues(mockFee, oldTargetRatio, newTargetRatio, expectedOOBState);

        // Verify values are set correctly
        assertEq(testHook.mockFee(), mockFee, "Mock fee should be set");
        assertEq(testHook.mockOldTargetRatio(), oldTargetRatio, "Mock old target ratio should be set");
        assertEq(testHook.mockNewTargetRatio(), newTargetRatio, "Mock new target ratio should be set");

        DynamicFeeLib.OOBState memory retrievedOOBState = testHook.getMockOOBState();
        assertEq(
            retrievedOOBState.lastOOBWasUpper,
            expectedOOBState.lastOOBWasUpper,
            "Mock OOB state lastOOBWasUpper should be set"
        );
        assertEq(
            retrievedOOBState.consecutiveOOBHits,
            expectedOOBState.consecutiveOOBHits,
            "Mock OOB state consecutiveOOBHits should be set"
        );
    }

    /**
     * @notice Fuzz test that consecutive pokes with different ratios work correctly
     * @dev Multiple pokes should all succeed and update fee correctly
     * @param mockFee Fee to set
     * @param ratio1 First ratio
     * @param ratio2 Second ratio
     * @param ratio3 Third ratio
     */
    function testFuzz_poke_multiplePokesSucceed(uint24 mockFee, uint256 ratio1, uint256 ratio2, uint256 ratio3)
        public
    {
        // Bound parameters
        mockFee = uint24(bound(mockFee, MIN_FEE_FUZZ, MAX_FEE_FUZZ));
        ratio1 = bound(ratio1, MIN_RATIO_FUZZ, MAX_RATIO_FUZZ);
        ratio2 = bound(ratio2, MIN_RATIO_FUZZ, MAX_RATIO_FUZZ);
        ratio3 = bound(ratio3, MIN_RATIO_FUZZ, MAX_RATIO_FUZZ);

        DynamicFeeLib.OOBState memory oobState;
        testHook.setMockValues(mockFee, 5e17, 6e17, oobState);

        // Initialize pool
        poolManager.initialize(dynamicFeeKey, Constants.SQRT_PRICE_1_1);

        // First poke
        testHook.poke(dynamicFeeKey, ratio1);
        (,,, uint24 fee1) = poolManager.getSlot0(dynamicFeeKey.toId());
        assertEq(fee1, mockFee, "First poke should set fee");

        // Second poke
        testHook.poke(dynamicFeeKey, ratio2);
        (,,, uint24 fee2) = poolManager.getSlot0(dynamicFeeKey.toId());
        assertEq(fee2, mockFee, "Second poke should maintain fee");

        // Third poke
        testHook.poke(dynamicFeeKey, ratio3);
        (,,, uint24 fee3) = poolManager.getSlot0(dynamicFeeKey.toId());
        assertEq(fee3, mockFee, "Third poke should maintain fee");
    }

    /**
     * @notice Fuzz test that extreme ratio differences are handled
     * @dev Should handle large differences between old and new target ratios
     * @param mockFee Fee to set
     * @param oldTargetRatio Old target ratio
     * @param newTargetRatio New target ratio (different from old)
     * @param currentRatio Current ratio
     */
    function testFuzz_poke_extremeRatioDifferences(
        uint24 mockFee,
        uint256 oldTargetRatio,
        uint256 newTargetRatio,
        uint256 currentRatio
    ) public {
        // Bound parameters
        mockFee = uint24(bound(mockFee, MIN_FEE_FUZZ, MAX_FEE_FUZZ));
        oldTargetRatio = bound(oldTargetRatio, MIN_RATIO_FUZZ, MAX_RATIO_FUZZ / 2);
        newTargetRatio = bound(newTargetRatio, MAX_RATIO_FUZZ / 2, MAX_RATIO_FUZZ);
        currentRatio = bound(currentRatio, MIN_RATIO_FUZZ, MAX_RATIO_FUZZ);

        // Ensure they're different
        vm.assume(oldTargetRatio != newTargetRatio);

        DynamicFeeLib.OOBState memory oobState;
        testHook.setMockValues(mockFee, oldTargetRatio, newTargetRatio, oobState);

        // Initialize pool
        poolManager.initialize(dynamicFeeKey, Constants.SQRT_PRICE_1_1);

        // Poke should succeed even with extreme ratio differences
        testHook.poke(dynamicFeeKey, currentRatio);

        (,,, uint24 newFee) = poolManager.getSlot0(dynamicFeeKey.toId());
        assertEq(newFee, mockFee, "Should handle extreme ratio differences");
    }

    /* ========================================================================== */
    /*                                  HELPERS                                  */
    /* ========================================================================== */

    /**
     * @notice Computes a valid hook address for the test hook
     * @dev Only afterInitialize permission needed for BaseDynamicFee
     */
    function _computeTestHookAddress() internal pure returns (address) {
        // Only afterInitialize permission needed for BaseDynamicFee
        uint160 flags = uint160(Hooks.AFTER_INITIALIZE_FLAG);
        return address(flags | uint160(0x8000) << 144); // Add namespace to avoid collisions
    }
}
