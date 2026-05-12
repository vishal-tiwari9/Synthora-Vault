// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title ISynthoraRouter
/// @notice Minimal interface for the Synthora order-execution router
/// @dev    This interface defines the contract boundary between the vault's
///         position-management logic and the underlying trade-execution layer.
///
///         INTEGRATION NOTES
///         -----------------
///         Replace the placeholder `_route*` functions in `SynthoraVault` with
///         real calls to this interface once the router is deployed.
///
///         The router is expected to:
///         1. Accept collateral from the vault (USDC via `safeTransfer` or `approve`).
///         2. Open/close/liquidate positions on the underlying perp DEX
///            (e.g., GMX v2, Synthetix Perps v3, a custom CLOB).
///         3. Return realised PnL (positive or negative) denominated in USDC
///            back to the vault on position close / liquidation.
///         4. Emit its own events for off-chain indexing.
///
///         Vault → Router trust model:
///         - The vault holds UPGRADER_ROLE over itself and acts as the sole
///           depositor of collateral into the router.
///         - The router must never be able to pull funds from the vault
///           without explicit approval.
///         - All router calls are guarded by `routerSet` and `nonReentrant`
///           modifiers in the vault.
interface ISynthoraRouter {
    // -------------------------------------------------------------------------
    // Structs
    // -------------------------------------------------------------------------

    /// @notice Result returned after opening a position
    /// @param routerPositionId  Internal ID assigned by the router
    /// @param executedPrice     Actual fill price (18-dec, USD)
    /// @param executedSizeUsd   Actual filled notional (USDC, 6-dec)
    /// @param fee               Execution fee charged by the router (USDC, 6-dec)
    struct OpenResult {
        uint256 routerPositionId;
        uint128 executedPrice;
        uint128 executedSizeUsd;
        uint128 fee;
    }

    /// @notice Result returned after closing or liquidating a position
    /// @param exitPrice      Actual exit price (18-dec, USD)
    /// @param realizedPnl    Signed PnL returned to the vault (USDC, 6-dec)
    ///                       Negative values represent losses (collateral reduction).
    /// @param fee            Execution/liquidation fee (USDC, 6-dec)
    /// @param collateralOut  Net USDC transferred back to the vault
    struct CloseResult {
        uint128 exitPrice;
        int256 realizedPnl;
        uint128 fee;
        uint128 collateralOut;
    }

    // -------------------------------------------------------------------------
    // Position Lifecycle
    // -------------------------------------------------------------------------

    /// @notice Opens a leveraged synthetic position.
    /// @dev    The caller (vault) must approve `collateralUsd` USDC to this
    ///         contract before calling, OR transfer it beforehand and rely on
    ///         the router to pull via `transferFrom`.
    ///
    ///         PLACEHOLDER — implement against the target perp DEX.
    ///
    /// @param assetId       Pyth feed ID identifying the synthetic asset
    /// @param sizeUsd       Notional position size in USDC (6-dec)
    /// @param collateralUsd Margin posted by the vault in USDC (6-dec)
    /// @param isLong        True = long, False = short
    /// @param referencePrice Entry reference price (used for slippage guard, 18-dec)
    /// @return result       Struct containing execution details
    function openPosition(bytes32 assetId, uint128 sizeUsd, uint128 collateralUsd, bool isLong, uint128 referencePrice)
        external
        returns (OpenResult memory result);

    /// @notice Closes an open position and returns collateral ± PnL to the vault.
    /// @dev    PLACEHOLDER — implement against the target perp DEX.
    ///
    /// @param vaultPositionId   The position ID assigned by the vault (for correlation)
    /// @param referencePrice    Expected exit price (used for slippage guard, 18-dec)
    /// @return result           Struct containing close details and net USDC out
    function closePosition(uint256 vaultPositionId, uint128 referencePrice) external returns (CloseResult memory result);

    /// @notice Liquidates an undercollateralised position.
    /// @dev    Called by the vault after it has verified the position is
    ///         below the maintenance margin.  The router executes the market
    ///         close and returns the remaining collateral (if any) to the vault.
    ///         The liquidation bonus/fee is paid to `keeper` by the router.
    ///
    ///         PLACEHOLDER — implement against the target perp DEX.
    ///
    /// @param vaultPositionId   Vault-side position ID
    /// @param liquidationPrice  Price at which the liquidation is triggered (18-dec)
    /// @param keeper            Address to receive the liquidation incentive
    /// @return result           Struct containing close details
    function liquidatePosition(uint256 vaultPositionId, uint128 liquidationPrice, address keeper)
        external
        returns (CloseResult memory result);

    // -------------------------------------------------------------------------
    // Position Adjustment
    // -------------------------------------------------------------------------

    /// @notice Increases or decreases the size of an open position.
    /// @dev    PLACEHOLDER — implement against the target perp DEX.
    ///
    /// @param vaultPositionId Vault-side position ID
    /// @param newSizeUsd      New target notional size (USDC, 6-dec)
    /// @param newLeverageBps  New leverage in basis points (100 = 1×)
    /// @param referencePrice  Current oracle price for slippage guard (18-dec)
    function adjustLeverage(uint256 vaultPositionId, uint128 newSizeUsd, uint32 newLeverageBps, uint128 referencePrice)
        external;

    /// @notice Tops up collateral for a position to avoid liquidation.
    /// @dev    PLACEHOLDER — implement against the target perp DEX.
    ///         The vault must pre-approve or transfer `additionalCollateral` USDC.
    ///
    /// @param vaultPositionId     Vault-side position ID
    /// @param additionalCollateral Extra margin in USDC (6-dec)
    function addCollateral(uint256 vaultPositionId, uint128 additionalCollateral) external;

    // -------------------------------------------------------------------------
    // Funding Rate Arbitrage
    // -------------------------------------------------------------------------

    /// @notice Flips or adjusts a position direction based on funding rate signal.
    /// @dev    PLACEHOLDER — only relevant for `strategyType == 2` (funding arb).
    ///         The router may close the existing leg and open a new opposing leg
    ///         in a single atomic transaction to reduce slippage.
    ///
    /// @param vaultPositionId Vault-side position ID
    /// @param fundingRate     Current signed funding rate (bps, negative = shorts pay longs)
    function adjustFundingArb(uint256 vaultPositionId, int256 fundingRate) external;

    // -------------------------------------------------------------------------
    // Queries
    // -------------------------------------------------------------------------

    /// @notice Returns the current unrealised PnL for a position from the router's view.
    /// @dev    This may differ from the vault's internal `_calculatePnL` due to
    ///         accumulated funding payments, borrow fees, etc.
    ///
    /// @param vaultPositionId Vault-side position ID
    /// @return pnl            Signed PnL in USDC (6-dec); negative = loss
    function getUnrealisedPnL(uint256 vaultPositionId) external view returns (int256 pnl);

    /// @notice Returns whether the router considers a position liquidatable.
    /// @param vaultPositionId Vault-side position ID
    /// @return                True if the router would accept a liquidation call
    function isLiquidatable(uint256 vaultPositionId) external view returns (bool);

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    event RouterPositionOpened(
        uint256 indexed vaultPositionId,
        uint256 indexed routerPositionId,
        bytes32 indexed assetId,
        uint128 executedPrice,
        uint128 sizeUsd,
        uint128 collateralUsd,
        bool isLong
    );

    event RouterPositionClosed(
        uint256 indexed vaultPositionId, uint128 exitPrice, int256 realizedPnl, uint128 collateralOut
    );

    event RouterPositionLiquidated(
        uint256 indexed vaultPositionId, uint128 liquidationPrice, address indexed keeper, uint128 collateralOut
    );

    // -------------------------------------------------------------------------
    // Errors
    // -------------------------------------------------------------------------

    error RouterPositionNotFound(uint256 vaultPositionId);
    error RouterInsufficientLiquidity(uint256 required, uint256 available);
    error RouterSlippageExceeded(uint128 expected, uint128 actual);
    error RouterUnauthorizedCaller(address caller);
}
