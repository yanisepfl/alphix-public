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

/* LOCAL IMPORTS */
import {BaseDynamicFee} from "../../../src/BaseDynamicFee.sol";
import {DynamicFeeLib} from "../../../src/libraries/DynamicFee.sol";
import {BaseAlphixTest} from "../BaseAlphix.t.sol";

/**
 * @title TestBaseDynamicFee
 * @notice Concrete implementation of BaseDynamicFee for testing purposes
 */
contract TestBaseDynamicFee is BaseDynamicFee {
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
            "test/alphix/openZeppelin/BaseDynamicFee.t.sol:TestBaseDynamicFee", abi.encode(poolManager), hookAddress
        );
        testHook = TestBaseDynamicFee(hookAddress);

        // Create pool keys
        dynamicFeeKey = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(testHook));
        staticFeeKey = PoolKey(currency0, currency1, 3000, 60, IHooks(testHook));
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

        // Set mock values
        DynamicFeeLib.OOBState memory oobState;
        testHook.setMockValues(expectedFee, 5e17, 6e17, oobState);

        // Get initial fee
        (,,, uint24 initialFee) = poolManager.getSlot0(dynamicFeeKey.toId());

        // Poke the pool
        testHook.poke(dynamicFeeKey, currentRatio);

        // Check fee was updated
        (,,, uint24 newFee) = poolManager.getSlot0(dynamicFeeKey.toId());
        assertEq(newFee, expectedFee, "Fee should be updated to mock value");
        assertTrue(newFee != initialFee, "Fee should have changed from initial value");
    }

    function test_poke_reverts_invalidPool() public {
        PoolKey memory invalidKey =
            PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(address(0x1234)));

        vm.expectRevert(); // Should revert with onlyValidPools modifier
        testHook.poke(invalidKey, 5e17);
    }

    function test_poke_handlesGetFeeRevert() public {
        // Initialize pool first
        poolManager.initialize(dynamicFeeKey, Constants.SQRT_PRICE_1_1);

        // Configure mock to revert on _getFee
        testHook.setShouldRevertOnGetFee(true);

        // Should propagate the revert
        vm.expectRevert("Mock revert in _getFee");
        testHook.poke(dynamicFeeKey, 5e17);
    }

    function test_poke_withDifferentCurrentRatios() public {
        uint24 baseFee = 750;
        DynamicFeeLib.OOBState memory oobState;
        testHook.setMockValues(baseFee, 5e17, 6e17, oobState);

        // Initialize pool first
        poolManager.initialize(dynamicFeeKey, Constants.SQRT_PRICE_1_1);

        uint256[] memory ratios = new uint256[](3);
        ratios[0] = 3e17; // 30%
        ratios[1] = 5e17; // 50%
        ratios[2] = 8e17; // 80%

        for (uint256 i = 0; i < ratios.length; i++) {
            // Poke with different ratio
            testHook.poke(dynamicFeeKey, ratios[i]);

            // Get fee after poke
            (,,, uint24 feeAfter) = poolManager.getSlot0(dynamicFeeKey.toId());

            // Should use the mock fee regardless of ratio (since this is a mock)
            assertEq(feeAfter, baseFee, string(abi.encodePacked("Fee should be mock value for ratio ", vm.toString(i))));
        }
    }

    /* EDGE CASES AND ERROR CONDITIONS */

    function test_poke_zeroCurrentRatio() public {
        uint24 expectedFee = 300;
        DynamicFeeLib.OOBState memory oobState;
        testHook.setMockValues(expectedFee, 0, 0, oobState);

        // Initialize pool first
        poolManager.initialize(dynamicFeeKey, Constants.SQRT_PRICE_1_1);

        testHook.poke(dynamicFeeKey, 0);

        (,,, uint24 newFee) = poolManager.getSlot0(dynamicFeeKey.toId());
        assertEq(newFee, expectedFee, "Should handle zero current ratio");
    }

    function test_poke_maxCurrentRatio() public {
        uint24 expectedFee = 9999;
        uint256 maxRatio = type(uint256).max;
        DynamicFeeLib.OOBState memory oobState;
        testHook.setMockValues(expectedFee, maxRatio, maxRatio, oobState);

        // Initialize pool first
        poolManager.initialize(dynamicFeeKey, Constants.SQRT_PRICE_1_1);

        testHook.poke(dynamicFeeKey, maxRatio);

        (,,, uint24 newFee) = poolManager.getSlot0(dynamicFeeKey.toId());
        assertEq(newFee, expectedFee, "Should handle max current ratio");
    }

    /* MOCK FUNCTIONALITY TESTS */

    function test_mockValues_setAndRetrieve() public {
        uint24 expectedFee = 1500;
        uint256 expectedOldRatio = 4e17;
        uint256 expectedNewRatio = 7e17;
        DynamicFeeLib.OOBState memory expectedOOBState =
            DynamicFeeLib.OOBState({lastOOBWasUpper: true, consecutiveOOBHits: 3});

        // Set mock values
        testHook.setMockValues(expectedFee, expectedOldRatio, expectedNewRatio, expectedOOBState);

        // Verify values are set correctly
        assertEq(testHook.mockFee(), expectedFee, "Mock fee should be set");
        assertEq(testHook.mockOldTargetRatio(), expectedOldRatio, "Mock old target ratio should be set");
        assertEq(testHook.mockNewTargetRatio(), expectedNewRatio, "Mock new target ratio should be set");

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

    function test_shouldRevertOnGetFee_toggle() public {
        // Initially should not revert
        assertFalse(testHook.shouldRevertOnGetFee(), "Should not revert initially");

        // Set to revert
        testHook.setShouldRevertOnGetFee(true);
        assertTrue(testHook.shouldRevertOnGetFee(), "Should be set to revert");

        // Set back to not revert
        testHook.setShouldRevertOnGetFee(false);
        assertFalse(testHook.shouldRevertOnGetFee(), "Should be set to not revert");
    }

    /* INTEGRATION TESTS */

    function test_poke_updatesFeeCorrectly() public {
        // Initialize pool
        poolManager.initialize(dynamicFeeKey, Constants.SQRT_PRICE_1_1);

        uint24 newFee = 1250;
        DynamicFeeLib.OOBState memory oobState;
        testHook.setMockValues(newFee, 5e17, 6e17, oobState);

        // Get fee before poke
        (,,, uint24 feeBefore) = poolManager.getSlot0(dynamicFeeKey.toId());

        // Poke the pool
        testHook.poke(dynamicFeeKey, 6e17);

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
