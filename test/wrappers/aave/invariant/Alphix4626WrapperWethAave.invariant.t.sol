// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {Alphix4626WrapperWethAave} from "../../../../src/wrappers/aave/Alphix4626WrapperWethAave.sol";
import {MockWETH} from "../mocks/MockWETH.sol";
import {MockAToken} from "../mocks/MockAToken.sol";
import {MockAavePool} from "../mocks/MockAavePool.sol";
import {MockPoolAddressesProvider} from "../mocks/MockPoolAddressesProvider.sol";

/**
 * @title Alphix4626WrapperWethAaveInvariantTest
 * @author Alphix
 * @notice Invariant tests for the Alphix4626WrapperWethAave contract.
 * @dev These tests verify that critical invariants hold across all state transitions,
 *      including ETH deposit/withdraw/redeem operations.
 *
 * ## Invariants Tested:
 *
 * ### Solvency Invariants
 * 1. **Solvency**: totalAssets() + claimableFees <= aToken balance
 * 2. **totalAssets Equality**: totalAssets() == aToken.balanceOf(wrapper) - claimableFees
 *
 * ### ETH Handling Invariants
 * 3. **No ETH Stuck**: Wrapper should not hold raw ETH (only during tx execution)
 * 4. **No WETH Stuck**: Wrapper should not hold WETH (all supplied to Aave)
 *
 * ### Share/Asset Relationship Invariants
 * 5. **Conversion Monotonicity**: convertToShares is monotonically non-decreasing
 * 6. **Round-Trip Conservation**: convertToShares(convertToAssets(shares)) <= shares
 *
 * ### Fee Invariants
 * 7. **Fee Bound**: fee <= MAX_FEE (1_000_000)
 * 8. **Fees Bounded By Balance**: claimableFees <= aToken.balanceOf(wrapper)
 *
 * ### Immutability Invariants
 * 9. **Immutables Constant**: WETH, AAVE_POOL, ATOKEN, ASSET never change
 */
contract Alphix4626WrapperWethAaveInvariantTest is Test {
    Alphix4626WrapperWethAave internal wethWrapper;
    MockWETH internal weth;
    MockAToken internal aToken;
    MockAavePool internal aavePool;
    MockPoolAddressesProvider internal poolAddressesProvider;

    WethHandler internal handler;

    address internal alphixHook;
    address internal owner;
    address internal treasury;

    uint24 internal constant MAX_FEE = 1_000_000;
    uint24 internal constant DEFAULT_FEE = 100_000; // 10%
    uint8 internal constant WETH_DECIMALS = 18;
    uint256 internal constant DEFAULT_SEED_LIQUIDITY = 1e18;

    function setUp() public {
        alphixHook = makeAddr("alphixHook");
        owner = makeAddr("owner");
        treasury = makeAddr("treasury");

        // Deploy mocks
        weth = new MockWETH();
        aavePool = new MockAavePool();
        aToken = new MockAToken("aWETH", "aWETH", WETH_DECIMALS, address(weth), address(aavePool));
        aavePool.initReserve(address(weth), address(aToken), true, false, false, 0);
        poolAddressesProvider = new MockPoolAddressesProvider(address(aavePool));

        // Deploy wrapper
        vm.deal(owner, 100 ether);
        vm.startPrank(owner);
        weth.deposit{value: DEFAULT_SEED_LIQUIDITY}();

        uint256 nonce = vm.getNonce(owner);
        address expectedWrapper = vm.computeCreateAddress(owner, nonce);
        weth.approve(expectedWrapper, type(uint256).max);

        wethWrapper = new Alphix4626WrapperWethAave(
            address(weth),
            treasury,
            address(poolAddressesProvider),
            "Test WETH Vault",
            "tWETH",
            DEFAULT_FEE,
            DEFAULT_SEED_LIQUIDITY
        );

        // Add alphixHook as authorized hook
        wethWrapper.addAlphixHook(alphixHook);
        vm.stopPrank();

        // Deploy handler
        handler = new WethHandler(wethWrapper, weth, aToken, alphixHook, owner);

        // Target only the handler for invariant testing
        targetContract(address(handler));

        // Exclude all other contracts from direct calls
        excludeContract(address(wethWrapper));
        excludeContract(address(weth));
        excludeContract(address(aToken));
        excludeContract(address(aavePool));
        excludeContract(address(poolAddressesProvider));
    }

    /* SOLVENCY INVARIANTS */

    /**
     * @notice Invariant: The wrapper is always solvent.
     */
    function invariant_solvency() public view {
        uint256 aTokenBalance = aToken.balanceOf(address(wethWrapper));
        uint256 totalAssets = wethWrapper.totalAssets();
        uint256 claimableFees = wethWrapper.getClaimableFees();

        assertLe(totalAssets + claimableFees, aTokenBalance, "Solvency violated: assets + fees > aToken balance");
    }

    /**
     * @notice Invariant: totalAssets equals aToken balance minus fees.
     */
    function invariant_totalAssetsEqualsATokenMinusFees() public view {
        uint256 aTokenBalance = aToken.balanceOf(address(wethWrapper));
        uint256 totalAssets = wethWrapper.totalAssets();
        uint256 claimableFees = wethWrapper.getClaimableFees();

        assertEq(totalAssets, aTokenBalance - claimableFees, "totalAssets != aToken - fees");
    }

    /* ETH HANDLING INVARIANTS */

    /**
     * @notice Invariant: Wrapper should not hold raw ETH after operations.
     */
    function invariant_noEthStuck() public view {
        assertEq(address(wethWrapper).balance, 0, "ETH stuck in wrapper");
    }

    /**
     * @notice Invariant: Wrapper should not hold WETH after operations.
     */
    function invariant_noWethStuck() public view {
        assertEq(weth.balanceOf(address(wethWrapper)), 0, "WETH stuck in wrapper");
    }

    /* SHARE/ASSET RELATIONSHIP INVARIANTS */

    /**
     * @notice Invariant: convertToShares is monotonically non-decreasing.
     */
    function invariant_conversionMonotonicity() public view {
        uint256 smallAmount = 1e18;
        uint256 largeAmount = 1000e18;

        uint256 smallShares = wethWrapper.convertToShares(smallAmount);
        uint256 largeShares = wethWrapper.convertToShares(largeAmount);

        assertLe(smallShares, largeShares, "Conversion not monotonic");
    }

    /**
     * @notice Invariant: Round-tripping shares through assets doesn't increase shares.
     */
    function invariant_conversionRoundTrip() public view {
        uint256 shares = 1000e18;
        uint256 assets = wethWrapper.convertToAssets(shares);
        uint256 sharesBack = wethWrapper.convertToShares(assets);

        assertLe(sharesBack, shares, "Round-trip increased shares");
    }

    /* FEE INVARIANTS */

    /**
     * @notice Invariant: Fee is always <= MAX_FEE.
     */
    function invariant_feeBound() public view {
        assertLe(wethWrapper.getFee(), MAX_FEE, "Fee exceeds MAX_FEE");
    }

    /**
     * @notice Invariant: Claimable fees never exceed aToken balance.
     */
    function invariant_feesBoundByBalance() public view {
        uint256 aTokenBalance = aToken.balanceOf(address(wethWrapper));
        uint256 claimableFees = wethWrapper.getClaimableFees();

        assertLe(claimableFees, aTokenBalance, "Claimable fees > aToken balance");
    }

    /* IMMUTABILITY INVARIANTS */

    /**
     * @notice Invariant: Immutables never change.
     */
    function invariant_immutables() public view {
        assertEq(address(wethWrapper.WETH()), address(weth), "WETH changed");
        assertEq(address(wethWrapper.AAVE_POOL()), address(aavePool), "AAVE_POOL changed");
        assertEq(address(wethWrapper.ATOKEN()), address(aToken), "ATOKEN changed");
        assertEq(address(wethWrapper.ASSET()), address(weth), "ASSET changed");
    }

    /* CALL SUMMARY */

    /**
     * @notice Log call summary after invariant run.
     */
    function invariant_callSummary() public view {
        handler.callSummary();
    }
}

/**
 * @title WethHandler
 * @notice Handler contract for WETH wrapper invariant testing.
 */
contract WethHandler is Test {
    Alphix4626WrapperWethAave internal wethWrapper;
    MockWETH internal weth;
    MockAToken internal aToken;
    address internal alphixHook;
    address internal owner;

    uint24 internal constant MAX_FEE = 1_000_000;

    // Ghost variables
    uint256 public ghostDepositEthCount;
    uint256 public ghostWithdrawEthCount;
    uint256 public ghostRedeemEthCount;
    uint256 public ghostDepositCount;
    uint256 public ghostWithdrawCount;
    uint256 public ghostRedeemCount;
    uint256 public ghostYieldSimulationCount;
    uint256 public ghostSlashCount;
    uint256 public ghostSetFeeCount;

    constructor(
        Alphix4626WrapperWethAave wethWrapper_,
        MockWETH weth_,
        MockAToken aToken_,
        address alphixHook_,
        address owner_
    ) {
        wethWrapper = wethWrapper_;
        weth = weth_;
        aToken = aToken_;
        alphixHook = alphixHook_;
        owner = owner_;
    }

    /**
     * @notice Deposit ETH.
     */
    function depositETH(uint256 amount) public {
        amount = bound(amount, 0.01 ether, 100 ether);

        vm.deal(alphixHook, amount);
        vm.prank(alphixHook);
        wethWrapper.depositETH{value: amount}(alphixHook);

        ghostDepositEthCount++;
    }

    /**
     * @notice Withdraw ETH.
     */
    function withdrawETH(uint256 amount) public {
        uint256 maxWithdraw = wethWrapper.maxWithdraw(alphixHook);
        if (maxWithdraw == 0) return;

        amount = bound(amount, 1, maxWithdraw);

        vm.prank(alphixHook);
        wethWrapper.withdrawETH(amount, alphixHook, alphixHook);

        ghostWithdrawEthCount++;
    }

    /**
     * @notice Redeem ETH.
     */
    function redeemETH(uint256 shares) public {
        uint256 maxRedeem = wethWrapper.maxRedeem(alphixHook);
        if (maxRedeem == 0) return;

        shares = bound(shares, 1, maxRedeem);

        vm.prank(alphixHook);
        wethWrapper.redeemETH(shares, alphixHook, alphixHook);

        ghostRedeemEthCount++;
    }

    /**
     * @notice Standard WETH deposit.
     */
    function deposit(uint256 amount) public {
        amount = bound(amount, 0.01 ether, 100 ether);

        vm.deal(alphixHook, amount);
        vm.startPrank(alphixHook);
        weth.deposit{value: amount}();
        weth.approve(address(wethWrapper), amount);
        wethWrapper.deposit(amount, alphixHook);
        vm.stopPrank();

        ghostDepositCount++;
    }

    /**
     * @notice Standard WETH withdraw.
     */
    function withdraw(uint256 amount) public {
        uint256 maxWithdraw = wethWrapper.maxWithdraw(alphixHook);
        if (maxWithdraw == 0) return;

        amount = bound(amount, 1, maxWithdraw);

        vm.prank(alphixHook);
        wethWrapper.withdraw(amount, alphixHook, alphixHook);

        ghostWithdrawCount++;
    }

    /**
     * @notice Standard WETH redeem.
     */
    function redeem(uint256 shares) public {
        uint256 maxRedeem = wethWrapper.maxRedeem(alphixHook);
        if (maxRedeem == 0) return;

        shares = bound(shares, 1, maxRedeem);

        vm.prank(alphixHook);
        wethWrapper.redeem(shares, alphixHook, alphixHook);

        ghostRedeemCount++;
    }

    /**
     * @notice Simulate yield.
     */
    function simulateYield(uint256 yieldPercent) public {
        yieldPercent = bound(yieldPercent, 0, 50);

        if (yieldPercent > 0) {
            uint256 currentBalance = aToken.balanceOf(address(wethWrapper));
            uint256 yieldAmount = currentBalance * yieldPercent / 100;
            if (yieldAmount > 0) {
                aToken.simulateYield(address(wethWrapper), yieldAmount);
            }
        }

        ghostYieldSimulationCount++;
    }

    /**
     * @notice Simulate slash (negative yield).
     */
    function simulateSlash(uint256 slashPercent) public {
        slashPercent = bound(slashPercent, 0, 50);

        if (slashPercent > 0) {
            uint256 currentBalance = aToken.balanceOf(address(wethWrapper));
            if (currentBalance > 0) {
                uint256 slashAmount = currentBalance * slashPercent / 100;
                if (slashAmount > 0) {
                    aToken.simulateSlash(address(wethWrapper), slashAmount);
                }
            }
        }

        ghostSlashCount++;
    }

    /**
     * @notice Set fee.
     */
    function setFee(uint24 newFee) public {
        newFee = uint24(bound(newFee, 0, MAX_FEE));

        vm.prank(owner);
        wethWrapper.setFee(newFee);

        ghostSetFeeCount++;
    }

    /**
     * @notice Print call summary.
     */
    function callSummary() public view {
        console.log("WETH Wrapper Call Summary:");
        console.log("  DepositETH:", ghostDepositEthCount);
        console.log("  WithdrawETH:", ghostWithdrawEthCount);
        console.log("  RedeemETH:", ghostRedeemEthCount);
        console.log("  Deposit (WETH):", ghostDepositCount);
        console.log("  Withdraw (WETH):", ghostWithdrawCount);
        console.log("  Redeem (WETH):", ghostRedeemCount);
        console.log("  Yield Simulations:", ghostYieldSimulationCount);
        console.log("  Slash Simulations:", ghostSlashCount);
        console.log("  SetFee calls:", ghostSetFeeCount);
    }
}
