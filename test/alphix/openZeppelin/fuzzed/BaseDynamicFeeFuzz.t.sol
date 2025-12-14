// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/* FORGE IMPORTS */

/* UNISWAP V4 IMPORTS */
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {Constants} from "v4-core/test/utils/Constants.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

/* LOCAL IMPORTS */
import {BaseDynamicFee} from "../../../../src/BaseDynamicFee.sol";
import {BaseAlphixTest} from "../../BaseAlphix.t.sol";

/**
 * @title TestBaseDynamicFeeFuzz
 * @notice Concrete implementation of BaseDynamicFee for fuzz testing purposes
 */
contract TestBaseDynamicFeeFuzz is BaseDynamicFee {
    uint24 public mockFee = 500;
    bool public shouldRevertOnPoke = false;

    constructor(IPoolManager _poolManager) BaseDynamicFee(_poolManager) {}

    /**
     * @dev Implementation of abstract poke function
     */
    function poke(PoolKey calldata key, uint256) external override onlyValidPools(key.hooks) {
        if (shouldRevertOnPoke) {
            revert("Mock revert in poke");
        }
        poolManager.updateDynamicLPFee(key, mockFee);
    }

    // Test helper functions
    function setMockFee(uint24 _fee) external {
        mockFee = _fee;
    }

    function setShouldRevertOnPoke(bool _shouldRevert) external {
        shouldRevertOnPoke = _shouldRevert;
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

    /* FUZZING CONSTRAINTS */

    // Fee bounds
    uint24 constant MIN_FEE_FUZZ = 1;
    uint24 constant MAX_FEE_FUZZ = LPFeeLibrary.MAX_LP_FEE;

    // Ratio bounds
    uint256 constant MIN_RATIO_FUZZ = 1e12; // 0.0001%
    uint256 constant MAX_RATIO_FUZZ = 1e24; // 1,000,000x

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

        // Create dynamic fee pool key
        // forge-lint: disable-next-line(named-struct-fields)
        dynamicFeeKey = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(testHook));
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
        // Bound to valid sqrt price range (exclusive of MAX to avoid edge case rejection)
        sqrtPriceX96 = uint160(bound(sqrtPriceX96, TickMath.MIN_SQRT_PRICE, TickMath.MAX_SQRT_PRICE - 1));

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
        // forge-lint: disable-next-line(named-struct-fields)
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
     */
    function testFuzz_poke_success_validPool(uint24 mockFee, uint256 currentRatio) public {
        // Bound parameters
        mockFee = uint24(bound(mockFee, MIN_FEE_FUZZ, MAX_FEE_FUZZ));
        currentRatio = bound(currentRatio, MIN_RATIO_FUZZ, MAX_RATIO_FUZZ);

        // Initialize pool first
        poolManager.initialize(dynamicFeeKey, Constants.SQRT_PRICE_1_1);

        // Set mock fee
        testHook.setMockFee(mockFee);

        // Poke the pool
        testHook.poke(dynamicFeeKey, currentRatio);

        // Check fee was updated
        (,,, uint24 newFee) = poolManager.getSlot0(dynamicFeeKey.toId());
        assertEq(newFee, mockFee, "Fee should be updated to mock value");
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

        testHook.setMockFee(mockFee);

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
     */
    function testFuzz_poke_zeroCurrentRatio(uint24 mockFee) public {
        // Bound parameters
        mockFee = uint24(bound(mockFee, MIN_FEE_FUZZ, MAX_FEE_FUZZ));

        testHook.setMockFee(mockFee);

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
        testHook.setMockFee(mockFee);

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
        testHook.setMockFee(initialFee);
        testHook.poke(dynamicFeeKey, currentRatio);

        // Get fee before second poke
        (,,, uint24 feeBefore) = poolManager.getSlot0(dynamicFeeKey.toId());
        assertEq(feeBefore, initialFee, "Initial fee should be set");

        // Update to new fee
        testHook.setMockFee(newFee);
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
    function testFuzz_poke_boundaryFeeValues(bool useMinFee, uint256 currentRatio) public {
        // Set fee to exact boundary
        uint24 mockFee = useMinFee ? MIN_FEE_FUZZ : MAX_FEE_FUZZ;
        currentRatio = bound(currentRatio, MIN_RATIO_FUZZ, MAX_RATIO_FUZZ);

        testHook.setMockFee(mockFee);

        // Initialize pool
        poolManager.initialize(dynamicFeeKey, Constants.SQRT_PRICE_1_1);

        // Poke with boundary fee
        testHook.poke(dynamicFeeKey, currentRatio);

        (,,, uint24 newFee) = poolManager.getSlot0(dynamicFeeKey.toId());
        assertEq(newFee, mockFee, "Should handle boundary fee values");
    }

    /**
     * @notice Fuzz test that mock fee is set and retrieved correctly
     * @dev Mock fee should be stored and retrievable accurately
     * @param mockFee Fee to set
     */
    function testFuzz_mockFee_setAndRetrieve(uint24 mockFee) public {
        // Bound parameters
        mockFee = uint24(bound(mockFee, MIN_FEE_FUZZ, MAX_FEE_FUZZ));

        // Set mock fee
        testHook.setMockFee(mockFee);

        // Verify value is set correctly
        assertEq(testHook.mockFee(), mockFee, "Mock fee should be set");
    }

    /**
     * @notice Fuzz test that consecutive pokes with different ratios work correctly
     * @dev Multiple pokes should all succeed and update fee correctly
     * @param mockFee Fee to set
     * @param ratio1 First ratio
     * @param ratio2 Second ratio
     * @param ratio3 Third ratio
     */
    function testFuzz_poke_multiplePokesSucceed(uint24 mockFee, uint256 ratio1, uint256 ratio2, uint256 ratio3) public {
        // Bound parameters
        mockFee = uint24(bound(mockFee, MIN_FEE_FUZZ, MAX_FEE_FUZZ));
        ratio1 = bound(ratio1, MIN_RATIO_FUZZ, MAX_RATIO_FUZZ);
        ratio2 = bound(ratio2, MIN_RATIO_FUZZ, MAX_RATIO_FUZZ);
        ratio3 = bound(ratio3, MIN_RATIO_FUZZ, MAX_RATIO_FUZZ);

        testHook.setMockFee(mockFee);

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
     * @notice Fuzz test that poke reverts when configured to do so
     * @dev Should propagate revert from poke implementation
     * @param currentRatio Current ratio to test
     */
    function testFuzz_poke_revertsWhenConfigured(uint256 currentRatio) public {
        currentRatio = bound(currentRatio, MIN_RATIO_FUZZ, MAX_RATIO_FUZZ);

        // Initialize pool first
        poolManager.initialize(dynamicFeeKey, Constants.SQRT_PRICE_1_1);

        // Configure mock to revert
        testHook.setShouldRevertOnPoke(true);

        // Should propagate the revert
        vm.expectRevert("Mock revert in poke");
        testHook.poke(dynamicFeeKey, currentRatio);
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
