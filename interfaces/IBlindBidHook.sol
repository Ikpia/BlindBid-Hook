// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {InEuint64, euint64} from "@fhenixprotocol/cofhe-contracts/FHE.sol";

/// @title IBlindBidHook
/// @notice Interface for BlindBid Hook contract
interface IBlindBidHook {
    struct Auction {
        address auctioneer;
        Currency bidCurrency;
        Currency assetCurrency;
        uint256 startTime;
        uint256 endTime;
        bool settled;
        address[] bidders;
        euint64 maxBid;
        address winner;
    }

    function createAuction(
        PoolKey calldata key,
        Currency bidCurrency,
        Currency assetCurrency,
        uint256 duration
    ) external;

    function submitBid(
        PoolKey calldata key,
        InEuint64 calldata encryptedBid
    ) external;

    function settleAuction(PoolKey calldata key) external;

    function getAuction(PoolId poolId) external view returns (Auction memory);

    function getBidderCount(PoolId poolId) external view returns (uint256);

    function isAuctionActive(PoolId poolId) external view returns (bool);

    function getBid(PoolId poolId, address bidder) external view returns (euint64);

    function getBidders(PoolId poolId) external view returns (address[] memory);

    function hasSubmittedBid(PoolId poolId, address bidder) external view returns (bool);
}

