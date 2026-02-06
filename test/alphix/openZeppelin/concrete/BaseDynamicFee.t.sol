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

/* LOCAL IMPORTS */
import {BaseDynamicFee} from "../../../../src/BaseDynamicFee.sol";
import {BaseAlphixTest} from "../../BaseAlphix.t.sol";

/**
 * @title TestBaseDynamicFee
 * @notice Concrete implementation of BaseDynamicFee for testing purposes
 */
contract TestBaseDynamicFee is BaseDynamicFee {
    uint24 public mockFee = 500;
    bool public shouldRevertOnPoke = false;
    PoolKey private _poolKey;

    constructor(IPoolManager _poolManager) BaseDynamicFee(_poolManager) {}

    /**
     * @dev Implementation of abstract poke function
     */
    function poke(uint256) external override {
        if (shouldRevertOnPoke) {
            revert("Mock revert in poke");
        }
        poolManager.updateDynamicLPFee(_poolKey, mockFee);
    }

    // Test helper functions
    function setMockFee(uint24 _fee) external {
        mockFee = _fee;
    }

    function setShouldRevertOnPoke(bool _shouldRevert) external {
        shouldRevertOnPoke = _shouldRevert;
    }

    function setPoolKey(PoolKey memory key) external {
        _poolKey = key;
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
 * @title BaseDynamicFeeTest
 * @author Alphix
 * @notice Test contract for OpenZeppelin BaseDynamicFee abstract contract
 */
contract BaseDynamicFeeTest is BaseAlphixTest {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    TestBaseDynamicFee public testHook;
    PoolKey public dynamicFeeKey;
    PoolKey public staticFeeKey;

    function setUp() public override {
        super.setUp();

        // Deploy test hook at a valid hook address
        address hookAddress = _computeTestHookAddress();
        deployCodeTo(
            "test/alphix/openZeppelin/concrete/BaseDynamicFee.t.sol:TestBaseDynamicFee",
            abi.encode(poolManager),
            hookAddress
        );
        testHook = TestBaseDynamicFee(hookAddress);

        // Create pool keys
        // forge-lint: disable-next-line(named-struct-fields)
        dynamicFeeKey = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(testHook));
        // forge-lint: disable-next-line(named-struct-fields)
        staticFeeKey = PoolKey(currency0, currency1, 3000, 60, IHooks(testHook));

        // Set the pool key for testing poke
        testHook.setPoolKey(dynamicFeeKey);
    }

    /* CONSTRUCTOR AND INITIALIZATION TESTS */

    function test_constructor_setsPoolManager() public view {
        assertEq(address(testHook.poolManager()), address(poolManager), "Pool manager should be set correctly");
    }

    function test_getHookPermissions_correctDefaults() public view {
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

    /* AFTER INITIALIZE TESTS */

    function test_afterInitialize_success_withDynamicFee() public {
        // Initialize the pool first
        poolManager.initialize(dynamicFeeKey, Constants.SQRT_PRICE_1_1);

        bytes4 result = testHook.testAfterInitialize(address(this), dynamicFeeKey, Constants.SQRT_PRICE_1_1, 0);
        assertEq(result, testHook.afterInitialize.selector, "Should return correct selector");
    }

    function test_afterInitialize_reverts_withStaticFee() public {
        // Create a static fee key that doesn't require pool initialization
        // forge-lint: disable-next-line(named-struct-fields)
        PoolKey memory localStaticKey = PoolKey(currency0, currency1, 3000, 60, IHooks(address(0)));

        vm.expectRevert(BaseDynamicFee.NotDynamicFee.selector);
        testHook.testAfterInitialize(address(this), localStaticKey, Constants.SQRT_PRICE_1_1, 0);
    }

    /* POKE FUNCTION TESTS */

    function test_poke_success_validPool() public {
        uint24 expectedFee = 1000;
        uint256 currentRatio = 7e17;

        // Initialize pool first
        poolManager.initialize(dynamicFeeKey, Constants.SQRT_PRICE_1_1);

        // Set mock fee
        testHook.setMockFee(expectedFee);

        // Get initial fee
        (,,, uint24 initialFee) = poolManager.getSlot0(dynamicFeeKey.toId());

        // Poke the pool
        testHook.poke(currentRatio);

        // Check fee was updated
        (,,, uint24 newFee) = poolManager.getSlot0(dynamicFeeKey.toId());
        assertEq(newFee, expectedFee, "Fee should be updated to mock value");
        assertTrue(newFee != initialFee, "Fee should have changed from initial value");
    }

    // Note: test_poke_reverts_invalidPool removed - single pool architecture stores pool key,
    // so the onlyValidPools modifier is no longer needed at the poke level.

    function test_poke_handlesPokeFunctionRevert() public {
        // Initialize pool first
        poolManager.initialize(dynamicFeeKey, Constants.SQRT_PRICE_1_1);

        // Configure mock to revert on poke
        testHook.setShouldRevertOnPoke(true);

        // Should propagate the revert
        vm.expectRevert("Mock revert in poke");
        testHook.poke(5e17);
    }

    function test_poke_withDifferentCurrentRatios() public {
        uint24 baseFee = 750;
        testHook.setMockFee(baseFee);

        // Initialize pool first
        poolManager.initialize(dynamicFeeKey, Constants.SQRT_PRICE_1_1);

        uint256[] memory ratios = new uint256[](3);
        ratios[0] = 3e17; // 30%
        ratios[1] = 5e17; // 50%
        ratios[2] = 8e17; // 80%

        for (uint256 i = 0; i < ratios.length; i++) {
            // Poke with different ratio
            testHook.poke(ratios[i]);

            // Get fee after poke
            (,,, uint24 feeAfter) = poolManager.getSlot0(dynamicFeeKey.toId());

            // Should use the mock fee regardless of ratio (since this is a mock)
            assertEq(feeAfter, baseFee, string(abi.encodePacked("Fee should be mock value for ratio ", vm.toString(i))));
        }
    }

    /* EDGE CASES AND ERROR CONDITIONS */

    function test_poke_zeroCurrentRatio() public {
        uint24 expectedFee = 300;
        testHook.setMockFee(expectedFee);

        // Initialize pool first
        poolManager.initialize(dynamicFeeKey, Constants.SQRT_PRICE_1_1);

        testHook.poke(0);

        (,,, uint24 newFee) = poolManager.getSlot0(dynamicFeeKey.toId());
        assertEq(newFee, expectedFee, "Should handle zero current ratio");
    }

    function test_poke_maxCurrentRatio() public {
        uint24 expectedFee = 9999;
        uint256 maxRatio = type(uint256).max;
        testHook.setMockFee(expectedFee);

        // Initialize pool first
        poolManager.initialize(dynamicFeeKey, Constants.SQRT_PRICE_1_1);

        testHook.poke(maxRatio);

        (,,, uint24 newFee) = poolManager.getSlot0(dynamicFeeKey.toId());
        assertEq(newFee, expectedFee, "Should handle max current ratio");
    }

    /* MOCK FUNCTIONALITY TESTS */

    function test_mockFee_setAndRetrieve() public {
        uint24 expectedFee = 1500;

        // Set mock fee
        testHook.setMockFee(expectedFee);

        // Verify value is set correctly
        assertEq(testHook.mockFee(), expectedFee, "Mock fee should be set");
    }

    function test_shouldRevertOnPoke_toggle() public {
        // Initially should not revert
        assertFalse(testHook.shouldRevertOnPoke(), "Should not revert initially");

        // Set to revert
        testHook.setShouldRevertOnPoke(true);
        assertTrue(testHook.shouldRevertOnPoke(), "Should be set to revert");

        // Set back to not revert
        testHook.setShouldRevertOnPoke(false);
        assertFalse(testHook.shouldRevertOnPoke(), "Should be set to not revert");
    }

    /* INTEGRATION TESTS */

    function test_poke_updatesFeeCorrectly() public {
        // Initialize pool
        poolManager.initialize(dynamicFeeKey, Constants.SQRT_PRICE_1_1);

        uint24 newFee = 1250;
        testHook.setMockFee(newFee);

        // Get fee before poke
        (,,, uint24 feeBefore) = poolManager.getSlot0(dynamicFeeKey.toId());

        // Poke the pool
        testHook.poke(6e17);

        // Get fee after poke
        (,,, uint24 feeAfter) = poolManager.getSlot0(dynamicFeeKey.toId());

        assertEq(feeAfter, newFee, "Fee should be updated to new value");
        assertTrue(feeAfter != feeBefore, "Fee should have changed");
    }

    /* UTILITY FUNCTIONS */

    /**
     * @notice Computes a valid hook address for the test hook
     */
    function _computeTestHookAddress() internal pure returns (address) {
        // Only afterInitialize permission needed for BaseDynamicFee
        uint160 flags = uint160(Hooks.AFTER_INITIALIZE_FLAG);
        return address(flags | uint160(0x8000) << 144); // Add namespace to avoid collisions
    }
}
