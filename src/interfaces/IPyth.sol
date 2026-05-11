// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;


interface IPyth {
     

      struct Price {
        int64  price;
        uint64 conf;
        int32  expo;
        uint   publishTime;
    }


      struct PriceFeed {
        bytes32 id;
        Price   price;
        Price   emaPrice;
    }


    function getPriceUnsafe(bytes32 id) external view returns (Price memory);

    function getPriceNoOlderThan(bytes32 id, uint age) external view returns (Price memory);

    function getEmaPriceUnsafe(bytes32 id) external view returns (Price memory);

    function getEmaPriceNoOlderThan(bytes32 id, uint age) external view returns (Price memory);


    function getUpdateFee(bytes[] calldata updateData) external view returns (uint feeAmount);

    function updatePriceFeeds(bytes[] calldata updateData) external payable;

    function updatePriceFeedsIfNecessary(
        bytes[]   calldata updateData,
        bytes32[] calldata priceIds,
        uint64[]  calldata minPublishTime
    ) external payable;

  function getPriceFeed(bytes32 id) external view returns (PriceFeed memory);

  function priceFeedExists(bytes32 id) external view returns (bool);


  function getValidTimePeriod() external view returns (uint);
   event PriceFeedUpdate(
        bytes32 indexed id,
        uint64  publishTime,
        int64   price,
        uint64  conf
    );


      /// @dev Feed ID has never been published on-chain.
    error PriceFeedNotFound();

    /// @dev Feed exists but its `publishTime` is older than the requested `age`.
    error PriceFeedNotFoundWithinRange();

    /// @dev Insufficient ETH sent to cover the update fee.
    error InsufficientFee();
}