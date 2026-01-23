// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Actions} from "v4-periphery/src/libraries/Actions.sol";
import {LiquidityAmounts} from "v4-core/test/utils/LiquidityAmounts.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {TickBitmap} from "v4-core/src/libraries/TickBitmap.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {Alphix} from "../../src/Alphix.sol";
import {IAlphix} from "../../src/interfaces/IAlphix.sol";
import {DynamicFeeLib} from "../../src/libraries/DynamicFee.sol";

/**
 * @title Create Pool and Add Initial Liquidity
 * @notice Creates a Uniswap V4 pool with Alphix Hook and seeds it with liquidity
 * @dev Initializes both Uniswap V4 pool and Alphix dynamic fee system
 *
 * DEPLOYMENT ORDER: 3 (After configuration)
 *
 * ARCHITECTURE: Single-Pool-Per-Hook Design
 * Each Alphix Hook manages exactly ONE pool. This script creates THE pool for the hook.
 *
 * Environment Variables Required:
 * - DEPLOYMENT_NETWORK: Network identifier
 * - POSITION_MANAGER_{NETWORK}: Uniswap V4 PositionManager address
 * - ALPHIX_HOOK_{NETWORK}: Alphix Hook contract address
 * - TOKEN0_{NETWORK}: First token address (must be < TOKEN1, or address(0) for ETH)
 * - TOKEN1_{NETWORK}: Second token address (must be > TOKEN0)
 * - TICK_SPACING_{NETWORK}: Tick spacing for the pool (e.g., 60)
 * - SQRT_PRICE_{NETWORK}: Starting sqrtPriceX96
 * - AMOUNT0_{NETWORK}: Initial token0 amount in wei
 * - AMOUNT1_{NETWORK}: Initial token1 amount in wei
 * - LIQUIDITY_RANGE_{NETWORK}: Range in tick spacings around current price
 * - INITIAL_FEE_{NETWORK}: Initial dynamic fee in bps
 * - TARGET_RATIO_{NETWORK}: Initial target ratio
 * - JIT_TICK_LOWER_{NETWORK}: Lower tick for JIT liquidity (immutable after init)
 * - JIT_TICK_UPPER_{NETWORK}: Upper tick for JIT liquidity (immutable after init)
 *
 * After Execution:
 * - Pool is created and initialized
 * - Initial liquidity is added
 * - Dynamic fee system is activated
 */
contract CreatePoolScript is Script {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;

    IAllowanceTransfer constant PERMIT2 = IAllowanceTransfer(0x000000000022D473030F116dDEE9F6B43aC78BA3);

    struct Config {
        string network;
        address positionManagerAddr;
        address hookAddr;
        address token0;
        address token1;
        int24 tickSpacing;
        uint160 sqrtPrice;
        uint256 amount0;
        uint256 amount1;
        uint256 liquidityRange;
        uint24 initialFee;
        uint256 targetRatio;
        int24 jitTickLower;
        int24 jitTickUpper;
    }

    struct LiqData {
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        bool isEthPool;
    }

    function run() public {
        Config memory cfg = _loadConfig();
        LiqData memory liq = _computeLiquidity(cfg);

        console.log("===========================================");
        console.log("CREATING POOL");
        console.log("===========================================");
        console.log("Network:", cfg.network);
        console.log("Hook:", cfg.hookAddr);
        console.log("Token0:", cfg.token0, liq.isEthPool ? "(ETH)" : "");
        console.log("Token1:", cfg.token1);
        console.log("Liquidity:", liq.liquidity);
        console.log("Initial Fee:", cfg.initialFee, "bps");
        console.log("");

        _executePoolCreation(cfg, liq);
    }

    function _loadConfig() internal view returns (Config memory cfg) {
        cfg.network = vm.envString("DEPLOYMENT_NETWORK");
        require(bytes(cfg.network).length > 0, "DEPLOYMENT_NETWORK not set");

        string memory envVar;

        envVar = string.concat("POSITION_MANAGER_", cfg.network);
        cfg.positionManagerAddr = vm.envAddress(envVar);
        require(cfg.positionManagerAddr != address(0), string.concat(envVar, " not set"));

        envVar = string.concat("ALPHIX_HOOK_", cfg.network);
        cfg.hookAddr = vm.envAddress(envVar);
        require(cfg.hookAddr != address(0), string.concat(envVar, " not set"));

        envVar = string.concat("TOKEN0_", cfg.network);
        cfg.token0 = vm.envAddress(envVar);

        envVar = string.concat("TOKEN1_", cfg.network);
        cfg.token1 = vm.envAddress(envVar);
        require(cfg.token1 != address(0), string.concat(envVar, " not set"));
        require(cfg.token0 < cfg.token1, "TOKEN0 must be < TOKEN1");

        // Tick spacing validation (must fit in int24 and be > 0)
        uint256 rawTickSpacing = vm.envUint(string.concat("TICK_SPACING_", cfg.network));
        require(rawTickSpacing > 0, string.concat("TICK_SPACING_", cfg.network, " must be > 0"));
        require(
            rawTickSpacing <= uint256(uint24(type(int24).max)),
            string.concat("TICK_SPACING_", cfg.network, " exceeds int24 max")
        );
        // forge-lint: disable-next-line(unsafe-typecast)
        cfg.tickSpacing = int24(uint24(rawTickSpacing));

        // sqrtPrice validation (must fit in uint160 and be within TickMath bounds)
        uint256 rawSqrtPrice = vm.envUint(string.concat("SQRT_PRICE_", cfg.network));
        require(rawSqrtPrice <= type(uint160).max, string.concat("SQRT_PRICE_", cfg.network, " exceeds uint160 max"));
        require(
            rawSqrtPrice >= TickMath.MIN_SQRT_PRICE && rawSqrtPrice <= TickMath.MAX_SQRT_PRICE,
            string.concat("SQRT_PRICE_", cfg.network, " outside TickMath bounds")
        );
        cfg.sqrtPrice = uint160(rawSqrtPrice);

        // Amount validation - ensure at least one amount is non-zero for initial liquidity
        cfg.amount0 = vm.envUint(string.concat("AMOUNT0_", cfg.network));
        cfg.amount1 = vm.envUint(string.concat("AMOUNT1_", cfg.network));
        require(cfg.amount0 > 0 || cfg.amount1 > 0, "At least one of AMOUNT0 or AMOUNT1 must be > 0");
        // Validate amounts fit in uint160 for Permit2 approvals (reserve +1 for approval headroom)
        require(
            cfg.amount0 < type(uint160).max,
            string.concat("AMOUNT0_", cfg.network, " must be < uint160 max (reserved +1 for Permit2)")
        );
        require(
            cfg.amount1 < type(uint160).max,
            string.concat("AMOUNT1_", cfg.network, " must be < uint160 max (reserved +1 for Permit2)")
        );

        // Liquidity range validation (must be > 0 and fit in int24 after cast)
        uint256 rawLiquidityRange = vm.envUint(string.concat("LIQUIDITY_RANGE_", cfg.network));
        require(rawLiquidityRange > 0, string.concat("LIQUIDITY_RANGE_", cfg.network, " must be > 0"));
        require(
            rawLiquidityRange <= uint256(uint24(type(int24).max)),
            string.concat("LIQUIDITY_RANGE_", cfg.network, " exceeds int24 max")
        );
        cfg.liquidityRange = rawLiquidityRange;

        // initialFee validation (must fit in uint24)
        uint256 rawInitialFee = vm.envUint(string.concat("INITIAL_FEE_", cfg.network));
        require(rawInitialFee <= type(uint24).max, string.concat("INITIAL_FEE_", cfg.network, " exceeds uint24 max"));
        cfg.initialFee = uint24(rawInitialFee);
        cfg.targetRatio = vm.envUint(string.concat("TARGET_RATIO_", cfg.network));

        // JIT tick range (required - immutable after pool initialization)
        envVar = string.concat("JIT_TICK_LOWER_", cfg.network);
        int256 rawJitLower = vm.envInt(envVar);
        require(
            rawJitLower >= type(int24).min && rawJitLower <= type(int24).max,
            string.concat(envVar, " out of int24 range")
        );
        cfg.jitTickLower = int24(rawJitLower);

        envVar = string.concat("JIT_TICK_UPPER_", cfg.network);
        int256 rawJitUpper = vm.envInt(envVar);
        require(
            rawJitUpper >= type(int24).min && rawJitUpper <= type(int24).max,
            string.concat(envVar, " out of int24 range")
        );
        cfg.jitTickUpper = int24(rawJitUpper);
        require(cfg.jitTickLower < cfg.jitTickUpper, "Invalid JIT tick range: JIT_TICK_LOWER must be < JIT_TICK_UPPER");
    }

    function _computeLiquidity(Config memory cfg) internal pure returns (LiqData memory liq) {
        Currency currency0 = Currency.wrap(cfg.token0);
        liq.isEthPool = currency0.isAddressZero();

        // Calculate tick bounds
        int24 currentTick = TickMath.getTickAtSqrtPrice(cfg.sqrtPrice);
        int24 compressed = TickBitmap.compress(currentTick, cfg.tickSpacing);
        // forge-lint: disable-next-line(unsafe-typecast)
        liq.tickLower = (compressed - int24(uint24(cfg.liquidityRange))) * cfg.tickSpacing;
        // forge-lint: disable-next-line(unsafe-typecast)
        liq.tickUpper = (compressed + int24(uint24(cfg.liquidityRange))) * cfg.tickSpacing;

        // Validate computed ticks are within TickMath bounds
        require(
            liq.tickLower >= TickMath.MIN_TICK,
            "Computed tickLower below MIN_TICK - reduce LIQUIDITY_RANGE or adjust SQRT_PRICE"
        );
        require(
            liq.tickUpper <= TickMath.MAX_TICK,
            "Computed tickUpper above MAX_TICK - reduce LIQUIDITY_RANGE or adjust SQRT_PRICE"
        );

        // Calculate liquidity
        liq.liquidity = LiquidityAmounts.getLiquidityForAmounts(
            cfg.sqrtPrice,
            TickMath.getSqrtPriceAtTick(liq.tickLower),
            TickMath.getSqrtPriceAtTick(liq.tickUpper),
            cfg.amount0,
            cfg.amount1
        );
    }

    function _executePoolCreation(Config memory cfg, LiqData memory liq) internal {
        Currency currency0 = Currency.wrap(cfg.token0);
        Currency currency1 = Currency.wrap(cfg.token1);

        PoolKey memory poolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: cfg.tickSpacing,
            hooks: IHooks(cfg.hookAddr)
        });

        PoolId poolId = poolKey.toId();

        DynamicFeeLib.PoolParams memory poolParams = _defaultPoolParams();

        IPositionManager posm = IPositionManager(cfg.positionManagerAddr);
        Alphix alphix = Alphix(cfg.hookAddr);

        vm.startBroadcast();

        // Approve tokens
        _approveTokens(cfg, liq.isEthPool);

        // Step 1: Initialize Uniswap pool
        console.log("Step 1: Initializing Uniswap V4 pool...");
        posm.initializePool(poolKey, cfg.sqrtPrice);

        // Step 2: Initialize Alphix (with JIT tick range - immutable after init)
        console.log("Step 2: Initializing Alphix dynamic fee system...");
        console.log("  - JIT Tick Lower:");
        console.logInt(int256(cfg.jitTickLower));
        console.log("  - JIT Tick Upper:");
        console.logInt(int256(cfg.jitTickUpper));
        alphix.initializePool(poolKey, cfg.initialFee, cfg.targetRatio, poolParams, cfg.jitTickLower, cfg.jitTickUpper);

        // Step 3: Add liquidity
        console.log("Step 3: Adding initial liquidity...");
        _addLiquidity(posm, poolKey, liq, cfg.amount0 + 1, cfg.amount1 + 1);

        vm.stopBroadcast();

        // Step 4: Verify everything went according to plan
        console.log("Step 4: Verifying pool state...");
        _verifyPoolState(alphix, poolKey, poolId, cfg);

        console.log("");
        console.log("===========================================");
        console.log("POOL CREATION SUCCESSFUL");
        console.log("===========================================");
        console.log("Pool ID:", _toHex(PoolId.unwrap(poolId)));
        console.log("");
        console.log("Add to .env:");
        console.log("  POOL_ID_%s=%s", cfg.network, _toHex(PoolId.unwrap(poolId)));
        console.log("");
        console.log("Next: Run 04_ConfigureReHypothecation.s.sol (optional)");
        console.log("===========================================");
    }

    function _verifyPoolState(Alphix alphix, PoolKey memory poolKey, PoolId poolId, Config memory cfg) internal view {
        // 1. Verify hook is unpaused
        require(!alphix.paused(), "VERIFY FAILED: Hook should be unpaused after initializePool");
        console.log("  [OK] Hook is unpaused");

        // 2. Verify pool is configured
        IAlphix.PoolConfig memory storedConfig = alphix.getPoolConfig();
        require(storedConfig.isConfigured, "VERIFY FAILED: Pool should be configured");
        console.log("  [OK] Pool is configured");

        // 3. Verify initial fee matches
        require(storedConfig.initialFee == cfg.initialFee, "VERIFY FAILED: Initial fee mismatch");
        console.log("  [OK] Initial fee:", storedConfig.initialFee, "bps");

        // 4. Verify target ratio matches
        require(storedConfig.initialTargetRatio == cfg.targetRatio, "VERIFY FAILED: Target ratio mismatch");
        console.log("  [OK] Target ratio:", storedConfig.initialTargetRatio);

        // 5. Verify pool key is stored correctly
        PoolId storedPoolId = alphix.getPoolId();
        require(PoolId.unwrap(storedPoolId) == PoolId.unwrap(poolId), "VERIFY FAILED: Pool ID mismatch");
        console.log("  [OK] Pool ID stored correctly");

        // 6. Verify hook address in pool key
        require(address(poolKey.hooks) == address(alphix), "VERIFY FAILED: Hook address mismatch in pool key");
        console.log("  [OK] Hook address in pool key");
    }

    function _defaultPoolParams() internal pure returns (DynamicFeeLib.PoolParams memory) {
        return DynamicFeeLib.PoolParams({
            minFee: 1, // 0.0001%
            maxFee: 1001, // 0.1001%
            baseMaxFeeDelta: 10,
            lookbackPeriod: 30,
            minPeriod: 172_800, // 2 days
            ratioTolerance: 5e15,
            linearSlope: 5e17,
            maxCurrentRatio: 1e21,
            upperSideFactor: 1e18,
            lowerSideFactor: 2e18
        });
    }

    function _approveTokens(Config memory cfg, bool isEthPool) internal {
        uint256 amount0Max = cfg.amount0 + 1;
        uint256 amount1Max = cfg.amount1 + 1;
        uint48 expiration = uint48(block.timestamp + 1 hours);

        if (!isEthPool) {
            IERC20(cfg.token0).approve(address(PERMIT2), amount0Max);
            // forge-lint: disable-next-line(unsafe-typecast)
            PERMIT2.approve(cfg.token0, cfg.positionManagerAddr, uint160(amount0Max), expiration);
        }
        IERC20(cfg.token1).approve(address(PERMIT2), amount1Max);
        // forge-lint: disable-next-line(unsafe-typecast)
        PERMIT2.approve(cfg.token1, cfg.positionManagerAddr, uint160(amount1Max), expiration);
    }

    function _addLiquidity(
        IPositionManager posm,
        PoolKey memory poolKey,
        LiqData memory liq,
        uint256 amount0Max,
        uint256 amount1Max
    ) internal {
        bytes memory hookData = "";
        bytes memory actions;
        bytes[] memory params;

        if (liq.isEthPool) {
            actions = abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR), uint8(Actions.SWEEP));
            params = new bytes[](3);
            params[0] = abi.encode(
                poolKey, liq.tickLower, liq.tickUpper, liq.liquidity, amount0Max, amount1Max, msg.sender, hookData
            );
            params[1] = abi.encode(poolKey.currency0, poolKey.currency1);
            params[2] = abi.encode(Currency.wrap(address(0)), msg.sender);
            posm.modifyLiquidities{value: amount0Max}(abi.encode(actions, params), block.timestamp + 60);
        } else {
            actions = abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR));
            params = new bytes[](2);
            params[0] = abi.encode(
                poolKey, liq.tickLower, liq.tickUpper, liq.liquidity, amount0Max, amount1Max, msg.sender, hookData
            );
            params[1] = abi.encode(poolKey.currency0, poolKey.currency1);
            posm.modifyLiquidities(abi.encode(actions, params), block.timestamp + 60);
        }
    }

    function _toHex(bytes32 data) internal pure returns (string memory) {
        bytes memory hexChars = "0123456789abcdef";
        bytes memory result = new bytes(66);
        result[0] = "0";
        result[1] = "x";
        for (uint256 i = 0; i < 32; i++) {
            result[2 + i * 2] = hexChars[uint8(data[i] >> 4)];
            result[2 + i * 2 + 1] = hexChars[uint8(data[i] & 0x0f)];
        }
        return string(result);
    }
}
