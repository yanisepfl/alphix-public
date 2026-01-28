// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Test, console} from "forge-std/Test.sol";

import {Alphix4626WrapperSky} from "../../../../../src/wrappers/sky/Alphix4626WrapperSky.sol";
import {MockERC20} from "../../mocks/MockERC20.sol";
import {MockRateProvider} from "../../mocks/MockRateProvider.sol";

/**
 * @title WrapperHandler
 * @author Alphix
 * @notice Handler contract for invariant testing of Alphix4626WrapperSky.
 * @dev Provides bounded function calls for invariant testing.
 */
contract WrapperHandler is Test {
    /* STATE VARIABLES */

    Alphix4626WrapperSky public wrapper;
    MockERC20 public usds;
    MockERC20 public susds;
    MockRateProvider public rateProvider;

    address public owner;
    address public alphixHook;

    /* GHOST VARIABLES (for tracking state) */

    uint256 public ghost_totalDeposits;
    uint256 public ghost_totalWithdraws;
    uint256 public ghost_totalRedeems;
    uint256 public ghost_feesCollected;
    uint256 public ghost_yieldGenerated;

    /// @notice Maximum cumulative rate multiplier (100x from initial 1e27)
    /// @dev Prevents unrealistic yield compounding in invariant tests
    uint256 internal constant MAX_CUMULATIVE_RATE = 100e27;

    mapping(bytes32 => uint256) public calls;

    /* CONSTRUCTOR */

    constructor(
        Alphix4626WrapperSky wrapper_,
        MockERC20 usds_,
        MockERC20 susds_,
        MockRateProvider rateProvider_,
        address owner_,
        address alphixHook_
    ) {
        wrapper = wrapper_;
        usds = usds_;
        susds = susds_;
        rateProvider = rateProvider_;
        owner = owner_;
        alphixHook = alphixHook_;

        // Approve wrapper for hook
        vm.prank(alphixHook);
        usds.approve(address(wrapper), type(uint256).max);
    }

    /* HANDLER FUNCTIONS */

    /**
     * @notice Handler for deposit operations
     */
    function deposit(uint256 amount) external {
        amount = bound(amount, 1e18, 10_000_000e18);
        calls["deposit"]++;

        // Mint tokens to hook
        usds.mint(alphixHook, amount);

        // Deposit
        vm.prank(alphixHook);
        try wrapper.deposit(amount, alphixHook) returns (uint256) {
            ghost_totalDeposits += amount;
        } catch {
            // Deposit failed (e.g., paused)
        }
    }

    /**
     * @notice Handler for withdraw operations
     */
    function withdraw(uint256 percent) external {
        percent = bound(percent, 1, 100);
        calls["withdraw"]++;

        uint256 maxWithdraw = wrapper.maxWithdraw(alphixHook);
        uint256 amount = maxWithdraw * percent / 100;

        if (amount > 0) {
            vm.prank(alphixHook);
            try wrapper.withdraw(amount, alphixHook, alphixHook) returns (uint256) {
                ghost_totalWithdraws += amount;
            } catch {
                // Withdraw failed
            }
        }
    }

    /**
     * @notice Handler for redeem operations
     */
    function redeem(uint256 percent) external {
        percent = bound(percent, 1, 100);
        calls["redeem"]++;

        uint256 maxRedeem = wrapper.maxRedeem(alphixHook);
        uint256 shares = maxRedeem * percent / 100;

        if (shares > 0) {
            vm.prank(alphixHook);
            try wrapper.redeem(shares, alphixHook, alphixHook) returns (uint256 assets) {
                ghost_totalRedeems += assets;
            } catch {
                // Redeem failed
            }
        }
    }

    /**
     * @notice Handler for yield simulation
     * @dev Capped at MAX_CUMULATIVE_RATE to prevent unrealistic compounding
     */
    function simulateYield(uint256 yieldPercent) external {
        yieldPercent = bound(yieldPercent, 1, 1); // Circuit breaker limits to 1%
        calls["simulateYield"]++;

        // Check if we've hit the cumulative rate cap
        uint256 currentRate = rateProvider.getConversionRate();
        if (currentRate >= MAX_CUMULATIVE_RATE) {
            // Skip yield simulation - already at maximum
            return;
        }

        rateProvider.simulateYield(yieldPercent);
        ghost_yieldGenerated += yieldPercent;
    }

    /**
     * @notice Handler for negative yield (slash)
     */
    function simulateSlash(uint256 slashPercent) external {
        slashPercent = bound(slashPercent, 1, 1); // Circuit breaker limits to 1%
        calls["simulateSlash"]++;

        rateProvider.simulateSlash(slashPercent);
    }

    /**
     * @notice Handler for fee changes
     */
    function setFee(uint24 newFee) external {
        newFee = uint24(bound(newFee, 0, 1_000_000));
        calls["setFee"]++;

        vm.prank(owner);
        try wrapper.setFee(newFee) {
        // Fee changed successfully
        }
            catch {
            // Fee change failed
        }
    }

    /**
     * @notice Handler for fee collection
     */
    function collectFees() external {
        calls["collectFees"]++;

        uint256 claimable = wrapper.getClaimableFees();

        if (claimable > 0) {
            vm.prank(owner);
            try wrapper.collectFees() {
                ghost_feesCollected += claimable;
            } catch {
                // Collection failed
            }
        }
    }

    /**
     * @notice Handler for pause/unpause
     */
    function togglePause(bool shouldPause) external {
        calls["togglePause"]++;

        vm.prank(owner);
        if (shouldPause && !wrapper.paused()) {
            try wrapper.pause() {
            // Paused
            }
                catch {
                // Already paused or failed
            }
        } else if (!shouldPause && wrapper.paused()) {
            try wrapper.unpause() {
            // Unpaused
            }
                catch {
                // Already unpaused or failed
            }
        }
    }

    /**
     * @notice Handler for adding hooks
     */
    function addHook(address newHook) external {
        newHook = address(uint160(bound(uint160(newHook), 1, type(uint160).max)));
        if (newHook == address(wrapper) || newHook == address(usds) || newHook == address(susds)) {
            return;
        }

        calls["addHook"]++;

        vm.prank(owner);
        try wrapper.addAlphixHook(newHook) {
            // Approve for the new hook
            vm.prank(newHook);
            usds.approve(address(wrapper), type(uint256).max);
        } catch {
            // Hook addition failed (already exists or invalid)
        }
    }

    /**
     * @notice Handler for removing hooks (but not the main one)
     */
    function removeHook(uint256 hookIndex) external {
        calls["removeHook"]++;

        address[] memory hooks = wrapper.getAllAlphixHooks();
        if (hooks.length > 1) {
            hookIndex = bound(hookIndex, 0, hooks.length - 1);
            address hookToRemove = hooks[hookIndex];

            // Don't remove the main hook used for testing
            if (hookToRemove != alphixHook) {
                vm.prank(owner);
                try wrapper.removeAlphixHook(hookToRemove) {
                // Hook removed
                }
                    catch {
                    // Removal failed
                }
            }
        }
    }

    /**
     * @notice Handler for treasury change
     */
    function setTreasury(address newTreasury) external {
        if (newTreasury == address(0)) return;

        calls["setTreasury"]++;

        vm.prank(owner);
        try wrapper.setYieldTreasury(newTreasury) {
        // Treasury changed
        }
            catch {
            // Change failed
        }
    }

    /* SUMMARY */

    function callSummary() external view {
        console.log("\nCall Summary:");
        console.log("  deposit:", calls["deposit"]);
        console.log("  withdraw:", calls["withdraw"]);
        console.log("  redeem:", calls["redeem"]);
        console.log("  simulateYield:", calls["simulateYield"]);
        console.log("  simulateSlash:", calls["simulateSlash"]);
        console.log("  setFee:", calls["setFee"]);
        console.log("  collectFees:", calls["collectFees"]);
        console.log("  togglePause:", calls["togglePause"]);
        console.log("  addHook:", calls["addHook"]);
        console.log("  removeHook:", calls["removeHook"]);
        console.log("  setTreasury:", calls["setTreasury"]);
        console.log("");
        console.log("Ghost Variables:");
        console.log("  totalDeposits:", ghost_totalDeposits);
        console.log("  totalWithdraws:", ghost_totalWithdraws);
        console.log("  totalRedeems:", ghost_totalRedeems);
        console.log("  feesCollected:", ghost_feesCollected);
        console.log("  yieldGenerated:", ghost_yieldGenerated);
    }
}
