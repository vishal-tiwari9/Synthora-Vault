// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title IPyth
/// @notice Minimal interface for the Pyth Network on-chain price oracle
/// @dev Full spec: https://docs.pyth.network/price-feeds/api-reference/evm
///      Pyth prices use a fixed-point representation:
///        realPrice = price * 10^expo
///      where `expo` is typically negative (e.g., expo = -8 → divide by 1e8).
///      The vault normalises prices to 18 decimals internally.
interface IPyth {
    // -------------------------------------------------------------------------
    // Structs
    // -------------------------------------------------------------------------

    /// @notice On-chain price snapshot from a single price feed
    /// @param price       Signed integer price (in fixed-point with `expo` exponent)
    /// @param conf        Confidence interval (unsigned, same exponent as `price`)
    /// @param expo        Exponent: realPrice = price × 10^expo
    /// @param publishTime Unix timestamp (seconds) when the price was computed
    struct Price {
        int64  price;
        uint64 conf;
        int32  expo;
        uint   publishTime;
    }

    /// @notice Full price feed snapshot (current price + exponential moving average)
    /// @param id       32-byte unique feed identifier (e.g., keccak256("AAPL/USD"))
    /// @param price    Latest spot price
    /// @param emaPrice Exponential moving-average price (slower, more manipulation resistant)
    struct PriceFeed {
        bytes32 id;
        Price   price;
        Price   emaPrice;
    }

    // -------------------------------------------------------------------------
    // Core Price Queries
    // -------------------------------------------------------------------------

    /// @notice Returns the most recent price for `id` WITHOUT any staleness check.
    /// @dev    DANGEROUS: caller must validate `publishTime` before using the price.
    ///         Reverts only if the feed has never been updated.
    /// @param id Pyth price feed ID
    /// @return   Price struct (may be stale)
    function getPriceUnsafe(bytes32 id) external view returns (Price memory);

    /// @notice Returns the price for `id` only if it was published within `age` seconds.
    /// @dev    Preferred over `getPriceUnsafe` for all trading logic.
    ///         Reverts with `PriceFeedNotFoundWithinRange` if the price is stale.
    /// @param id  Pyth price feed ID
    /// @param age Maximum acceptable age in seconds
    /// @return    Fresh Price struct
    function getPriceNoOlderThan(bytes32 id, uint age) external view returns (Price memory);

    /// @notice Returns the EMA (exponential moving average) price for `id`.
    /// @dev    More manipulation-resistant than the spot price; suitable for
    ///         liquidation checks and risk calculations.
    /// @param id Pyth price feed ID
    /// @return   EMA Price struct (may be stale — validate publishTime)
    function getEmaPriceUnsafe(bytes32 id) external view returns (Price memory);

    /// @notice Returns the EMA price for `id` only if published within `age` seconds.
    /// @param id  Pyth price feed ID
    /// @param age Maximum acceptable age in seconds
    /// @return    Fresh EMA Price struct
    function getEmaPriceNoOlderThan(bytes32 id, uint age) external view returns (Price memory);

    // -------------------------------------------------------------------------
    // Feed Update (Push Model)
    // -------------------------------------------------------------------------

    /// @notice Returns the fee in wei required to update `updateData`.
    /// @param updateData Encoded price update bytes (obtained from Pyth Hermes API)
    /// @return feeAmount Wei required
    function getUpdateFee(bytes[] calldata updateData) external view returns (uint feeAmount);

    /// @notice Pushes fresh price data on-chain.
    /// @dev    Must be called with `msg.value >= getUpdateFee(updateData)`.
    ///         Emits `PriceFeedUpdate` for each updated feed.
    ///         Unused ETH is returned to the caller.
    /// @param updateData Encoded price update bytes from the Hermes off-chain service
    function updatePriceFeeds(bytes[] calldata updateData) external payable;

    /// @notice Pushes fresh price data only if each feed is older than `minPublishTime`.
    /// @dev    Cheaper than `updatePriceFeeds` when feeds are already fresh.
    /// @param updateData    Encoded price update bytes
    /// @param priceIds      Feed IDs to selectively update
    /// @param minPublishTime Only update feeds with publishTime < minPublishTime
    function updatePriceFeedsIfNecessary(
        bytes[]   calldata updateData,
        bytes32[] calldata priceIds,
        uint64[]  calldata minPublishTime
    ) external payable;

    // -------------------------------------------------------------------------
    // Batch Queries
    // -------------------------------------------------------------------------

    /// @notice Returns the full PriceFeed for `id` (both spot and EMA).
    /// @param id Pyth price feed ID
    /// @return   Full PriceFeed struct
    function getPriceFeed(bytes32 id) external view returns (PriceFeed memory);

    /// @notice Checks whether a price feed has ever been published on-chain.
    /// @param id Pyth price feed ID
    /// @return   True if the feed exists and has been written at least once
    function priceFeedExists(bytes32 id) external view returns (bool);

    /// @notice Returns the number of decimal places for the price of a feed.
    /// @dev    Convenience wrapper around the `expo` field (returns -expo).
    /// @param id Pyth price feed ID
    /// @return   Decimals (e.g., 8 for most Pyth feeds)
    function getValidTimePeriod() external view returns (uint);

    // -------------------------------------------------------------------------
    // Events (for off-chain indexing)
    // -------------------------------------------------------------------------

    /// @notice Emitted when a price feed is updated via `updatePriceFeeds`.
    event PriceFeedUpdate(
        bytes32 indexed id,
        uint64  publishTime,
        int64   price,
        uint64  conf
    );

    // -------------------------------------------------------------------------
    // Errors (Pyth SDK standard)
    // -------------------------------------------------------------------------

    /// @dev Feed ID has never been published on-chain.
    error PriceFeedNotFound();

    /// @dev Feed exists but its `publishTime` is older than the requested `age`.
    error PriceFeedNotFoundWithinRange();

    /// @dev Insufficient ETH sent to cover the update fee.
    error InsufficientFee();
}
