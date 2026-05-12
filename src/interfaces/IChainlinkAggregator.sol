// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title IChainlinkAggregator
/// @notice Minimal Chainlink AggregatorV3Interface used by SynthoraVault's
///         oracle circuit-breaker. Paste the full address from:
///         https://docs.chain.link/data-feeds/price-feeds/addresses
///
/// INTEGRATION NOTES
/// ─────────────────
/// • `latestRoundData()` is the ONLY function the vault uses.
/// • Always validate: answeredInRound >= roundId, updatedAt freshness, answer > 0.
/// • Chainlink feeds use 8 decimals for USD pairs on most chains.
/// • On Arbitrum, Chainlink feeds update on price deviation OR heartbeat (1h or 24h).
///   Set CHAINLINK_MAX_AGE accordingly (3600 for 1h feeds, 86400 for 24h feeds).
///
/// USAGE IN _readChainlinkPrice (replace the placeholder body):
///
///   (uint80 roundId, int256 answer, , uint256 updatedAt, uint80 answeredInRound)
///       = IChainlinkAggregator(feed).latestRoundData();
///
///   // Stale round check
///   if (answeredInRound < roundId) return 0;
///
///   // Age check
///   if (block.timestamp - updatedAt > CHAINLINK_MAX_AGE) return 0;
///
///   // Sanity check
///   if (answer <= 0) return 0;
///
///   // Chainlink 8-dec → Pyth-compatible 8-dec (same scale, no conversion needed)
///   return uint128(uint256(answer));

interface IChainlinkAggregator {
    // ── Core data query ───────────────────────────────────────────────────────

    /// @notice Returns the data from the latest round.
    /// @return roundId          The ID of the round that the data was collected from.
    /// @return answer           The answer (price) from the aggregator in fixed-point
    ///                          with `decimals()` decimal places.
    /// @return startedAt        Timestamp of when the round started.
    /// @return updatedAt        Timestamp of when the round was updated. This is
    ///                          the field you should use for freshness checks.
    /// @return answeredInRound  The round ID in which the answer was computed.
    ///                          If `answeredInRound < roundId` the round is incomplete.
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);

    /// @notice Returns historic round data for a specific round ID.
    /// @dev    Useful for TWAP calculations or auditing past prices.
    function getRoundData(uint80 _roundId)
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);

    // ── Metadata ──────────────────────────────────────────────────────────────

    /// @notice Returns the number of decimal places in the `answer` field.
    ///         For USD pairs this is typically 8 (i.e. $1.00 = 100_000_000).
    function decimals() external view returns (uint8);

    /// @notice Human-readable description of the feed (e.g. "AAPL / USD").
    function description() external view returns (string memory);

    /// @notice Aggregator contract version.
    function version() external view returns (uint256);

    // ── Events ────────────────────────────────────────────────────────────────

    /// @notice Emitted each time the aggregator updates.
    /// @param current  New round ID.
    /// @param roundId  Same as `current` — historical naming inconsistency in Chainlink.
    /// @param updatedAt Timestamp.
    event AnswerUpdated(int256 indexed current, uint256 indexed roundId, uint256 updatedAt);

    /// @notice Emitted when a new round is started.
    event NewRound(uint256 indexed roundId, address indexed startedBy, uint256 startedAt);
}
