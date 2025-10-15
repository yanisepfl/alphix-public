// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/* FORGE IMPORTS */
import {Test} from "forge-std/Test.sol";

/* OZ IMPORTS */

/* UNISWAP V4 IMPORTS */
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";

/* LOCAL IMPORTS */
import {MockERC165} from "./MockERC165.sol";
import {MockReenteringLogic} from "./MockReenteringLogic.sol";
import {IAlphixLogic} from "../../../src/interfaces/IAlphixLogic.sol";
import {DynamicFeeLib} from "../../../src/libraries/DynamicFee.sol";

/**
 * @title MockAlphixLogicTest
 * @author Alphix
 * @notice Test contract for mock implementations used in testing
 */
contract MockAlphixLogicTest is Test {
    MockERC165 public mockErc165;
    MockReenteringLogic public mockReenteringLogic;
    address public mockHook;

    function setUp() public {
        mockErc165 = new MockERC165();
        mockHook = address(0x1234); // Mock hook address
        mockReenteringLogic = new MockReenteringLogic(mockHook);
    }

    /* MOCK ERC165 TESTS */

    function test_mockErc165_supportsInterface_returnsFalse() public view {
        // Test that MockERC165 always returns false for interface support
        bytes4 arbitraryInterface = 0x12345678;
        assertFalse(mockErc165.supportsInterface(arbitraryInterface), "MockERC165 should always return false");

        // Test with IAlphixLogic interface
        bytes4 alphixLogicInterface = type(IAlphixLogic).interfaceId;
        assertFalse(mockErc165.supportsInterface(alphixLogicInterface), "MockERC165 should not support IAlphixLogic");
    }

    function test_mockErc165_implementsIERC165() public view {
        // Verify it implements IERC165
        bytes4 erc165Interface = 0x01ffc9a7; // IERC165 interface ID
        // Note: MockERC165 returns false for everything, including IERC165 itself
        assertFalse(mockErc165.supportsInterface(erc165Interface), "MockERC165 returns false for everything");
    }

    /* MOCK REENTERING LOGIC TESTS */

    function test_mockReenteringLogic_constructor() public view {
        assertEq(mockReenteringLogic.HOOK(), mockHook, "Hook address should be set correctly");
    }

    function test_mockReenteringLogic_supportsInterface_returnsTrue() public view {
        // Test that MockReenteringLogic always returns true for interface support
        bytes4 arbitraryInterface = 0x12345678;
        assertTrue(
            mockReenteringLogic.supportsInterface(arbitraryInterface), "MockReenteringLogic should always return true"
        );

        // Test with IAlphixLogic interface
        bytes4 alphixLogicInterface = type(IAlphixLogic).interfaceId;
        assertTrue(
            mockReenteringLogic.supportsInterface(alphixLogicInterface),
            "MockReenteringLogic should support any interface"
        );
    }

    function test_mockReenteringLogic_computeFeeAndTargetRatio_attemptsReentry() public {
        // Create a mock pool key
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(0)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });

        // This should revert when it tries to call poke on the mock hook address
        // because the mock hook address (0x1234) doesn't have a poke function
        vm.expectRevert();
        mockReenteringLogic.computeFeeAndTargetRatio(key, 5e17);
    }

    function test_mockReenteringLogic_computeFeeAndTargetRatio_withMockHook() public {
        // Deploy a mock hook that has a poke function to test the reentrancy attempt
        MockHookWithPoke mockHookWithPoke = new MockHookWithPoke();
        MockReenteringLogic reenteringLogic = new MockReenteringLogic(address(mockHookWithPoke));

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(0)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });

        // This should succeed and call the mock hook's poke function
        (uint24 fee, uint256 oldRatio, uint256 newRatio, DynamicFeeLib.OobState memory oobState) =
            reenteringLogic.computeFeeAndTargetRatio(key, 5e17);

        // Verify the returned values match the mock implementation
        assertEq(fee, 3000, "Should return mock fee");
        assertEq(oldRatio, 0, "Should return zero old ratio");
        assertEq(newRatio, 0, "Should return zero new ratio");
        assertFalse(oobState.lastOobWasUpper, "Should return false for lastOobWasUpper");
        assertEq(oobState.consecutiveOobHits, 0, "Should return zero consecutive hits");

        // Verify the mock hook's poke was called
        assertTrue(mockHookWithPoke.pokeCalled(), "Poke should have been called");
    }

    /* DATA STRUCTURE TESTS (for interface validation) */

    function test_poolTypeParams_struct() public pure {
        // Test that we can create PoolTypeParams structs
        DynamicFeeLib.PoolTypeParams memory stableParams = DynamicFeeLib.PoolTypeParams({
            minFee: 1,
            maxFee: 5001,
            baseMaxFeeDelta: 25,
            lookbackPeriod: 30,
            minPeriod: 1 days,
            ratioTolerance: 5e15,
            linearSlope: 2e18,
            maxCurrentRatio: 1e21,
            upperSideFactor: 1e18,
            lowerSideFactor: 2e18
        });

        assertEq(stableParams.minFee, 1, "Min fee should be set correctly");
        assertEq(stableParams.maxFee, 5001, "Max fee should be set correctly");
        assertEq(stableParams.baseMaxFeeDelta, 25, "Base max fee delta should be set correctly");
    }

    function test_poolConfig_struct() public pure {
        // Test that we can create PoolConfig structs
        IAlphixLogic.PoolConfig memory config = IAlphixLogic.PoolConfig({
            initialFee: 500, initialTargetRatio: 5e17, poolType: IAlphixLogic.PoolType.STABLE, isConfigured: true
        });

        assertEq(config.initialFee, 500, "Initial fee should be set correctly");
        assertEq(config.initialTargetRatio, 5e17, "Initial target ratio should be set correctly");
        assertEq(uint8(config.poolType), uint8(IAlphixLogic.PoolType.STABLE), "Pool type should be set correctly");
        assertTrue(config.isConfigured, "Should be configured");
    }

    function test_poolType_enum() public pure {
        // Test pool type enumeration
        assertEq(uint8(IAlphixLogic.PoolType.STABLE), 0, "STABLE should be 0");
        assertEq(uint8(IAlphixLogic.PoolType.STANDARD), 1, "STANDARD should be 1");
        assertEq(uint8(IAlphixLogic.PoolType.VOLATILE), 2, "VOLATILE should be 2");
    }

    function test_oobState_struct() public pure {
        // Test OOB state struct
        DynamicFeeLib.OobState memory oobState = DynamicFeeLib.OobState({lastOobWasUpper: true, consecutiveOobHits: 5});

        assertTrue(oobState.lastOobWasUpper, "Last OOB should be upper");
        assertEq(oobState.consecutiveOobHits, 5, "Consecutive hits should be 5");
    }

    function test_error_selectors() public pure {
        // Test that error selectors are defined
        bytes4 invalidLogicSelector = IAlphixLogic.InvalidLogicContract.selector;
        bytes4 invalidCallerSelector = IAlphixLogic.InvalidCaller.selector;
        bytes4 poolPausedSelector = IAlphixLogic.PoolPaused.selector;

        assertTrue(invalidLogicSelector != bytes4(0), "InvalidLogicContract selector should be non-zero");
        assertTrue(invalidCallerSelector != bytes4(0), "InvalidCaller selector should be non-zero");
        assertTrue(poolPausedSelector != bytes4(0), "PoolPaused selector should be non-zero");
    }
}

/**
 * @dev Helper contract to test reentrancy attempts
 */
contract MockHookWithPoke {
    bool public pokeCalled = false;

    function poke(PoolKey calldata, uint256) external {
        pokeCalled = true;
    }
}
