// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title  Interactions
 * @notice Collection of Foundry scripts demonstrating every major vault action.
 *
 * ─────────────────────────────────────────────────────────────────────────────
 * HOW TO USE
 * ─────────────────────────────────────────────────────────────────────────────
 *
 *  Each public function is a separate runnable script.  Select one via --sig:
 *
 *  # User deposits $1,000 USDC
 *  forge script script/Interactions.s.sol \
 *      --sig "deposit(uint256)" 1000000000 \
 *      --rpc-url $ARBITRUM_RPC_URL --broadcast -vvvv
 *
 *  # Strategist opens a 5× long AAPL position with $5,000 collateral
 *  forge script script/Interactions.s.sol \
 *      --sig "openAaplLong(uint128,uint32)" 5000000000 500 \
 *      --rpc-url $ARBITRUM_RPC_URL --broadcast -vvvv
 *
 *  # Keeper liquidates position #3
 *  forge script script/Interactions.s.sol \
 *      --sig "liquidate(uint256)" 3 \
 *      --rpc-url $ARBITRUM_RPC_URL --broadcast -vvvv
 *
 *  Required env vars (all interactions):
 *    SYNTHORA_PROXY      — deployed proxy address
 *    USDC_ADDRESS        — USDC token address
 *    ACTION_PRIVATE_KEY  — private key of the caller
 *
 *  Optional (for oracle updates):
 *    PYTH_UPDATE_DATA    — hex-encoded update bytes from Hermes API
 */

import {Script, console2} from "forge-std/Script.sol";
import {IERC20}           from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SynthoraVault}    from "../src/SynthoraVault.sol";

// ─────────────────────────────────────────────────────────────────────────────
// Shared base
// ─────────────────────────────────────────────────────────────────────────────

abstract contract InteractionBase is Script {
    SynthoraVault internal vault;
    IERC20        internal usdc;
    uint256       internal callerKey;
    address       internal caller;

    /// @dev Well-known Pyth feed IDs (Arbitrum mainnet)
    bytes32 internal constant AAPL = 0x49f6b65cb1de6b10eaf75e7c03ca029c306d0357e91b5311b175084a5ad55688;
    bytes32 internal constant TSLA = 0x16dad506d7db8da01c87581c87ca897a012a153557d4d578c3b9c9e1bc0632f1;
    bytes32 internal constant NVDA = 0x9b5729b99e46b3a18193f83a50f68c74d67fc0085f5e3edd1bdc88ef5cdb53f8;
    bytes32 internal constant GOLD = 0x765d2ba906dbc32ca17cc11f5310a89e9ee1f6420508c63861f2f8ba4ee34bb2;

    modifier setup() {
        callerKey = vm.envUint("ACTION_PRIVATE_KEY");
        caller    = vm.addr(callerKey);
        vault     = SynthoraVault(vm.envAddress("SYNTHORA_PROXY"));
        usdc      = IERC20(vm.envAddress("USDC_ADDRESS"));

        console2.log("=== Synthora Interaction ===");
        console2.log("Caller  :", caller);
        console2.log("Vault   :", address(vault));
        console2.log("TVL     :", vault.totalAssets());
        console2.log("Shares  :", vault.totalSupply());
        _;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// §1  USER INTERACTIONS
// ─────────────────────────────────────────────────────────────────────────────

/**
 * @notice Deposits USDC into the vault and receives svUSDC shares.
 *
 * Usage:
 *   forge script script/Interactions.s.sol:DepositAction \
 *       --sig "run(uint256)" <USDC_AMOUNT_6DEC> \
 *       --rpc-url $ARBITRUM_RPC_URL --broadcast -vvvv
 *
 * Example: deposit $1,000 USDC
 *   forge script ... --sig "run(uint256)" 1000000000
 */
contract DepositAction is InteractionBase {
    function run(uint256 usdcAmount) external setup {
        console2.log("Depositing USDC:", usdcAmount);

        // Preview first (read-only, no gas)
        (uint256 expectedShares, uint256 fee) = vault.previewDepositAfterFee(usdcAmount);
        console2.log("Expected shares :", expectedShares);
        console2.log("Deposit fee     :", fee);

        vm.startBroadcast(callerKey);

        // Approve vault to pull USDC
        usdc.approve(address(vault), usdcAmount);

        // Deposit
        uint256 shares = vault.deposit(usdcAmount, caller);

        vm.stopBroadcast();

        console2.log("Shares received :", shares);
        console2.log("Share price     :", vault.sharePrice());
        (uint256 owned, uint256 value,) = vault.getUserSummary(caller);
        console2.log("Your shares     :", owned);
        console2.log("Your value (6d) :", value);
    }
}

/**
 * @notice Withdraws USDC from the vault by burning svUSDC shares.
 *
 * Usage:
 *   forge script script/Interactions.s.sol:WithdrawAction \
 *       --sig "run(uint256)" <SHARES_TO_BURN_18DEC> \
 *       --rpc-url $ARBITRUM_RPC_URL --broadcast -vvvv
 */
contract WithdrawAction is InteractionBase {
    function run(uint256 sharesToBurn) external setup {
        uint256 myShares = vault.balanceOf(caller);
        console2.log("My shares       :", myShares);
        console2.log("Shares to burn  :", sharesToBurn);

        require(myShares >= sharesToBurn, "Insufficient shares");

        // Preview
        (uint256 netAssets, uint256 fee) = vault.previewRedeemAfterFee(sharesToBurn);
        console2.log("Expected USDC   :", netAssets);
        console2.log("Withdrawal fee  :", fee);

        // Check flash-loan protection
        (bool blocked, uint256 unlocksAt) = vault.canWithdraw(caller);
        if (blocked) {
            console2.log("WARNING: blocked until block", unlocksAt);
            return;
        }

        vm.startBroadcast(callerKey);
        uint256 assets = vault.redeem(sharesToBurn, caller, caller);
        vm.stopBroadcast();

        console2.log("USDC received   :", assets);
    }
}

/**
 * @notice Emergency withdrawal when vault is in emergency mode.
 *         Bypasses fees and the normal withdrawal flow.
 */
contract EmergencyWithdrawAction is InteractionBase {
    function run(uint256 sharesToBurn) external setup {
        require(vault.emergencyMode(), "Vault is not in emergency mode");

        uint256 myShares = vault.balanceOf(caller);
        if (sharesToBurn == 0 || sharesToBurn > myShares) sharesToBurn = myShares;

        console2.log("Emergency withdrawing shares:", sharesToBurn);

        vm.startBroadcast(callerKey);
        vault.emergencyWithdraw(sharesToBurn, caller);
        vm.stopBroadcast();

        console2.log("Emergency withdraw complete");
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// §2  STRATEGIST INTERACTIONS
// ─────────────────────────────────────────────────────────────────────────────

/**
 * @notice Opens a leveraged position on a synthetic asset.
 *
 * Usage:
 *   forge script script/Interactions.s.sol:OpenPositionAction \
 *       --sig "run(bytes32,uint128,uint32,bool,uint8)" \
 *           <ASSET_ID> <COLLATERAL_6DEC> <LEVERAGE_BPS> <IS_LONG> <STRATEGY_TYPE> \
 *       --rpc-url $ARBITRUM_RPC_URL --broadcast -vvvv
 *
 * Example: 5× long AAPL with $5,000 collateral
 *   ASSET_ID  = 0x49f6b65cb1de6b10eaf75e7c03ca029c306d0357e91b5311b175084a5ad55688
 *   COLLATERAL = 5000000000  (5,000 USDC in 6-dec)
 *   LEVERAGE   = 500         (5× = 500 bps)
 *   IS_LONG    = true
 *   TYPE       = 0           (fixed leverage)
 */
contract OpenPositionAction is InteractionBase {
    function run(
        bytes32 assetId,
        uint128 collateralUsd,
        uint32  leverageBps,
        bool    isLong,
        uint8   strategyType
    ) external setup {
        console2.log("Opening position:");
        console2.log("  Asset     :", uint256(assetId));
        console2.log("  Collateral:", collateralUsd);
        console2.log("  Leverage  :", leverageBps);
        console2.log("  Long      :", isLong ? 1 : 0);

        // Get current price for slippage bounds (1% tolerance)
        (uint128 currentPrice,,) = vault.getAssetPrice(assetId);
        uint128 minPrice = uint128(uint256(currentPrice) * 99 / 100);
        uint128 maxPrice = uint128(uint256(currentPrice) * 101 / 100);

        // Preview liquidation price
        uint128 liqPrice = vault.previewLiquidationPrice(currentPrice, leverageBps, isLong);
        console2.log("  Entry price:", currentPrice);
        console2.log("  Liq price  :", liqPrice);

        // Vault metrics before
        (uint256 util,,uint256 openPos, uint256 liquid) = vault.getVaultMetrics();
        console2.log("Vault utilization:", util, "bps");
        console2.log("Open positions   :", openPos);
        console2.log("Available liquid :", liquid);

        require(collateralUsd <= liquid, "Insufficient vault liquidity");

        vm.startBroadcast(callerKey);
        uint256 positionId = vault.executeStrategy(
            assetId, collateralUsd, leverageBps, isLong, strategyType,
            minPrice, maxPrice
        );
        vm.stopBroadcast();

        console2.log("Position opened  :", positionId);
        console2.log("Health           :", vault.getPositionHealth(positionId));
    }
}

/**
 * @notice Closes an active position.
 *
 * Usage:
 *   forge script script/Interactions.s.sol:ClosePositionAction \
 *       --sig "run(uint256)" <POSITION_ID> \
 *       --rpc-url $ARBITRUM_RPC_URL --broadcast -vvvv
 */
contract ClosePositionAction is InteractionBase {
    function run(uint256 positionId) external setup {
        SynthoraVault.Position memory pos = vault.getPosition(positionId);
        require(pos.isActive, "Position not active");

        int256 pnl = vault.getPositionPnL(positionId);
        console2.log("Position ID :", positionId);
        console2.log("Entry price :", pos.entryPrice);
        console2.log("PnL (signed):", uint256(pnl > 0 ? pnl : -pnl));
        console2.log("PnL positive:", pnl > 0 ? 1 : 0);

        (uint128 currentPrice,,) = vault.getAssetPrice(pos.assetId);
        uint128 minPrice = uint128(uint256(currentPrice) * 98 / 100); // 2% tolerance
        uint128 maxPrice = uint128(uint256(currentPrice) * 102 / 100);

        vm.startBroadcast(callerKey);
        vault.closePosition(positionId, minPrice, maxPrice);
        vm.stopBroadcast();

        console2.log("Position closed successfully");
        console2.log("New TVL:", vault.totalAssets());
    }
}

/**
 * @notice Adjusts leverage on an existing position.
 *
 * Usage:
 *   forge script script/Interactions.s.sol:AdjustLeverageAction \
 *       --sig "run(uint256,uint32)" <POSITION_ID> <NEW_LEVERAGE_BPS> \
 *       --rpc-url $ARBITRUM_RPC_URL --broadcast -vvvv
 */
contract AdjustLeverageAction is InteractionBase {
    function run(uint256 positionId, uint32 newLeverageBps) external setup {
        SynthoraVault.Position memory pos = vault.getPosition(positionId);
        require(pos.isActive, "Position not active");

        console2.log("Old leverage :", pos.leverageBps);
        console2.log("New leverage :", newLeverageBps);
        console2.log("Old size     :", pos.sizeUsd);

        vm.startBroadcast(callerKey);
        vault.adjustLeverage(positionId, newLeverageBps);
        vm.stopBroadcast();

        SynthoraVault.Position memory updated = vault.getPosition(positionId);
        console2.log("New size     :", updated.sizeUsd);
        console2.log("New liq px   :", updated.liquidationPrice);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// §3  KEEPER INTERACTIONS
// ─────────────────────────────────────────────────────────────────────────────

/**
 * @notice Liquidates an undercollateralised position.
 *
 * Usage:
 *   forge script script/Interactions.s.sol:LiquidateAction \
 *       --sig "run(uint256)" <POSITION_ID> \
 *       --rpc-url $ARBITRUM_RPC_URL --broadcast -vvvv
 */
contract LiquidateAction is InteractionBase {
    function run(uint256 positionId) external setup {
        SynthoraVault.Position memory pos = vault.getPosition(positionId);
        require(pos.isActive, "Position not active");

        bool liqable = vault.isPositionLiquidatable(positionId);
        console2.log("Position ID    :", positionId);
        console2.log("Is liquidatable:", liqable ? 1 : 0);
        console2.log("Health (bps)   :", vault.getPositionHealth(positionId));

        require(liqable, "Position is not liquidatable");

        vm.startBroadcast(callerKey);
        vault.liquidatePosition(positionId);
        vm.stopBroadcast();

        console2.log("Liquidated successfully");
    }
}

/**
 * @notice Batch-checks and flags a list of positions for liquidation.
 *         Call this after pushing a fresh Pyth price update on-chain.
 *
 * Usage:
 *   # Check positions 1–10
 *   forge script script/Interactions.s.sol:FlagLiquidationsAction \
 *       --sig "run(uint256,uint256)" 1 10 \
 *       --rpc-url $ARBITRUM_RPC_URL --broadcast -vvvv
 */
contract FlagLiquidationsAction is InteractionBase {
    function run(uint256 fromId, uint256 toId) external setup {
        require(toId >= fromId, "Invalid range");
        uint256 count = toId - fromId + 1;
        uint256[] memory ids = new uint256[](count);
        for (uint256 i; i < count; i++) {
            ids[i] = fromId + i;
        }

        console2.log("Checking positions", fromId, "to", toId);

        vm.startBroadcast(callerKey);
        vault.flagPositionsForLiquidation(ids);
        vm.stopBroadcast();

        console2.log("Flag sweep complete. Check events for flagged positions.");
    }
}

/**
 * @notice Rebalances a dynamic-strategy position.
 *
 * Usage:
 *   forge script script/Interactions.s.sol:RebalanceAction \
 *       --sig "run(uint256)" <POSITION_ID> \
 *       --rpc-url $ARBITRUM_RPC_URL --broadcast -vvvv
 */
contract RebalanceAction is InteractionBase {
    function run(uint256 positionId) external setup {
        SynthoraVault.Position memory pos = vault.getPosition(positionId);
        require(pos.isActive, "Position not active");
        require(pos.strategyType != 0, "Fixed leverage: no rebalance needed");

        uint32 suggested = vault.estimateDynamicLeverage(positionId);
        console2.log("Current leverage :", pos.leverageBps);
        console2.log("Suggested leverage:", suggested);

        vm.startBroadcast(callerKey);
        vault.rebalancePosition(positionId);
        vm.stopBroadcast();

        SynthoraVault.Position memory updated = vault.getPosition(positionId);
        console2.log("New leverage     :", updated.leverageBps);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// §4  ADMIN INTERACTIONS
// ─────────────────────────────────────────────────────────────────────────────

/**
 * @notice Reads and logs a complete vault status report.
 *         Safe read-only call — no broadcast needed.
 *
 * Usage:
 *   forge script script/Interactions.s.sol:VaultStatusReport \
 *       --sig "run()" \
 *       --rpc-url $ARBITRUM_RPC_URL -vvv
 */
contract VaultStatusReport is InteractionBase {
    function run() external setup {
        console2.log("\n╔══════════════════════════════════╗");
        console2.log("║   SYNTHORA VAULT STATUS REPORT   ║");
        console2.log("╚══════════════════════════════════╝\n");

        // ── ERC-4626 basics ──────────────────────────────────────────────────
        console2.log("--- ERC-4626 ---");
        console2.log("Total Assets (USDC 6d) :", vault.totalAssets());
        console2.log("Total Shares (18d)     :", vault.totalSupply());
        console2.log("Share Price  (18d)     :", vault.sharePrice());
        console2.log("High Water Mark (18d)  :", vault.getHighWaterMark());
        console2.log("Min Deposit (USDC 6d)  :", vault.minDepositAmount());
        console2.log("TVL Cap (USDC 6d)      :", vault.tvlCap());
        console2.log("Deposits Locked        :", vault.depositsLocked() ? 1 : 0);
        console2.log("Paused                 :", vault.paused() ? 1 : 0);
        console2.log("Emergency Mode         :", vault.emergencyMode() ? 1 : 0);

        // ── Positions ────────────────────────────────────────────────────────
        console2.log("\n--- Positions ---");
        (uint256 util, uint256 exposure, uint256 open, uint256 liquid) = vault.getVaultMetrics();
        console2.log("Active Positions       :", open);
        console2.log("Total Notional (6d)    :", exposure);
        console2.log("Collateral Locked (6d) :", vault.totalCollateralLocked());
        console2.log("Utilization (bps)      :", util);
        console2.log("Available Liquid (6d)  :", liquid);
        console2.log("Effective Max Leverage :", vault.getEffectiveMaxLeverage());

        // ── Fees ─────────────────────────────────────────────────────────────
        console2.log("\n--- Fees ---");
        SynthoraVault.FeeConfig memory fc = vault.getFeeConfig();
        console2.log("Performance Fee (bps)  :", fc.performanceFeeBps);
        console2.log("Management Fee  (bps)  :", fc.managementFeeBps);
        console2.log("Withdrawal Fee  (bps)  :", fc.withdrawalFeeBps);
        console2.log("Deposit Fee     (bps)  :", fc.depositFeeBps);
        console2.log("Accrued Mgmt Fee (6d)  :", vault.getAccruedManagementFee());
        console2.log("Treasury               :", vault.treasury());

        // ── Risk ─────────────────────────────────────────────────────────────
        console2.log("\n--- Risk Config ---");
        SynthoraVault.RiskConfig memory rc = vault.getRiskConfig();
        console2.log("Min Leverage (bps)     :", rc.minLeverageBps);
        console2.log("Max Leverage (bps)     :", rc.maxLeverageBps);
        console2.log("Max Pos Size (bps)     :", rc.maxPositionSizeBps);
        console2.log("Liq Threshold (bps)    :", rc.liquidationThresholdBps);
        console2.log("Maint. Margin (bps)    :", rc.maintenanceMarginBps);
        console2.log("Max Open Positions     :", rc.maxOpenPositions);

        // ── Version ──────────────────────────────────────────────────────────
        console2.log("\n--- Meta ---");
        console2.log("Version                :", vault.version());
        console2.log("Router                 :", address(vault.router()));
    }
}

/**
 * @notice Updates fee configuration.
 *
 * Usage:
 *   forge script script/Interactions.s.sol:SetFeesAction \
 *       --sig "run(uint32,uint32,uint32,uint32)" 1000 200 50 0 \
 *       --rpc-url $ARBITRUM_RPC_URL --broadcast -vvvv
 */
contract SetFeesAction is InteractionBase {
    function run(
        uint32 perfFeeBps,
        uint32 mgmtFeeBps,
        uint32 withdrawFeeBps,
        uint32 depositFeeBps
    ) external setup {
        console2.log("Setting fees:");
        console2.log("  Performance :", perfFeeBps);
        console2.log("  Management  :", mgmtFeeBps);
        console2.log("  Withdrawal  :", withdrawFeeBps);
        console2.log("  Deposit     :", depositFeeBps);

        vm.startBroadcast(callerKey);
        vault.setFeeConfig(perfFeeBps, mgmtFeeBps, withdrawFeeBps, depositFeeBps);
        vm.stopBroadcast();

        console2.log("Fee config updated");
    }
}

/**
 * @notice Activates emergency mode.
 *         Only call this in a genuine emergency — it pauses the vault and
 *         enables `emergencyWithdraw` for all users.
 *
 * Usage:
 *   forge script script/Interactions.s.sol:EmergencyModeAction \
 *       --sig "run(bool)" true \
 *       --rpc-url $ARBITRUM_RPC_URL --broadcast -vvvv
 */
contract EmergencyModeAction is InteractionBase {
    function run(bool activate) external setup {
        if (activate) {
            console2.log("!!! ACTIVATING EMERGENCY MODE !!!");
            vm.startBroadcast(callerKey);
            vault.activateEmergencyMode();
            vm.stopBroadcast();
            console2.log("Emergency mode active. Users can now emergencyWithdraw().");
        } else {
            console2.log("Deactivating emergency mode...");
            vm.startBroadcast(callerKey);
            vault.deactivateEmergencyMode();
            vm.stopBroadcast();
            console2.log("Emergency mode deactivated. Remember to unpause manually.");
        }
    }
}

/**
 * @notice Collects accrued management fees to treasury.
 *
 * Usage:
 *   forge script script/Interactions.s.sol:CollectFeesAction \
 *       --sig "run()" \
 *       --rpc-url $ARBITRUM_RPC_URL --broadcast -vvvv
 */
contract CollectFeesAction is InteractionBase {
    function run() external setup {
        uint256 accrued = vault.getAccruedManagementFee();
        console2.log("Accrued mgmt fee (USDC 6d):", accrued);

        vm.startBroadcast(callerKey);
        vault.collectManagementFees();
        vm.stopBroadcast();

        console2.log("Fees swept to treasury:", vault.treasury());
    }
}
