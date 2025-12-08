// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

// Uniswap Imports
import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";

// FHE Imports
import {FHE, InEuint64, euint64, ebool} from "@fhenixprotocol/cofhe-contracts/FHE.sol";
import {IFHERC20} from "./interface/IFHERC20.sol";
import {IBlindBidHook} from "../interfaces/IBlindBidHook.sol";

/**
 * @title BlindBidHook
 * @notice Encrypted NFT/Token Auctions in AMM Pools
 * @dev Allows users to submit encrypted bids for NFTs or tokens listed in pools.
 * All bids remain completely hidden until auction closes. Winner determined by
 * highest encrypted bid without revealing losing bids.
 * 
 * @custom:security This contract uses FHE (Fully Homomorphic Encryption) to maintain
 * bid privacy. All bid amounts remain encrypted during the auction phase.
 * Only the winning bid is decrypted during settlement.
 */
contract BlindBidHook is BaseHook, IBlindBidHook {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using CurrencySettler for Currency;
    using FHE for uint256;

    // ============ Constants ============
    uint256 public constant MIN_AUCTION_DURATION = 1 hours;
    uint256 public constant MAX_AUCTION_DURATION = 365 days;
    uint256 public constant MAX_BIDDERS_PER_AUCTION = 1000; // Gas limit consideration

    // ============ Errors ============
    error BlindBidHook__AuctionNotActive();
    error BlindBidHook__AuctionAlreadySettled();
    error BlindBidHook__AuctionNotEnded();
    error BlindBidHook__InvalidBidder();
    error BlindBidHook__BidAlreadySubmitted();
    error BlindBidHook__NoBidsSubmitted();
    error BlindBidHook__InvalidCurrency();
    error BlindBidHook__AuctionAlreadyExists();
    error BlindBidHook__InsufficientBalance();
    error BlindBidHook__InvalidDuration();

    // ============ Events ============
    event AuctionCreated(
        PoolId indexed poolId,
        address indexed auctioneer,
        uint256 startTime,
        uint256 endTime,
        Currency bidCurrency,
        Currency assetCurrency
    );
    
    event BidSubmitted(
        PoolId indexed poolId,
        address indexed bidder,
        uint256 timestamp
    );
    
    event AuctionSettled(
        PoolId indexed poolId,
        address indexed winner,
        uint256 timestamp
    );

    // ============ Structs ============
    struct Auction {
        address auctioneer;           // Creator of the auction
        Currency bidCurrency;         // Currency used for bids (e.g., USDC)
        Currency assetCurrency;      // Currency/NFT being auctioned
        uint256 startTime;            // Auction start timestamp
        uint256 endTime;              // Auction end timestamp
        bool settled;                 // Whether auction has been settled
        address[] bidders;            // List of all bidders
        euint64 maxBid;              // Encrypted maximum bid
        address winner;               // Winner address (set after settlement)
    }

    // ============ State Variables ============
    mapping(PoolId => Auction) public auctions;
    mapping(PoolId => mapping(address => euint64)) public bids; // poolId => bidder => encrypted bid
    mapping(PoolId => mapping(address => bool)) public hasBid;  // Track if bidder has submitted

    // ============ Constructor ============
    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {}

    // ============ Hook Permissions ============
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: false,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // ============ Auction Management ============
    
    /**
     * @notice Create a new auction for a pool
     * @param key The pool key
     * @param bidCurrency Currency used for bids
     * @param assetCurrency Currency/NFT being auctioned
     * @param duration Duration of auction in seconds
     */
    function createAuction(
        PoolKey calldata key,
        Currency bidCurrency,
        Currency assetCurrency,
        uint256 duration
    ) external onlyValidPools(key.hooks) {
        PoolId poolId = key.toId();
        
        // Validate duration
        if (duration < MIN_AUCTION_DURATION || duration > MAX_AUCTION_DURATION) {
            revert BlindBidHook__InvalidDuration();
        }
        
        // Check if auction already exists
        if (auctions[poolId].endTime != 0) {
            revert BlindBidHook__AuctionAlreadyExists();
        }

        uint256 startTime = block.timestamp;
        uint256 endTime = startTime + duration;

        auctions[poolId] = Auction({
            auctioneer: msg.sender,
            bidCurrency: bidCurrency,
            assetCurrency: assetCurrency,
            startTime: startTime,
            endTime: endTime,
            settled: false,
            bidders: new address[](0),
            maxBid: FHE.asEuint64(0),
            winner: address(0)
        });

        emit AuctionCreated(poolId, msg.sender, startTime, endTime, bidCurrency, assetCurrency);
    }

    /**
     * @notice Submit an encrypted bid for an auction
     * @param key The pool key
     * @param encryptedBid Encrypted bid amount (euint64)
     */
    function submitBid(
        PoolKey calldata key,
        InEuint64 calldata encryptedBid
    ) external onlyValidPools(key.hooks) {
        PoolId poolId = key.toId();
        Auction storage auction = auctions[poolId];

        // Validate auction is active
        if (auction.endTime == 0) {
            revert BlindBidHook__AuctionNotActive();
        }
        if (block.timestamp < auction.startTime || block.timestamp >= auction.endTime) {
            revert BlindBidHook__AuctionNotActive();
        }
        if (auction.settled) {
            revert BlindBidHook__AuctionAlreadySettled();
        }

        // Prevent duplicate bids
        if (hasBid[poolId][msg.sender]) {
            revert BlindBidHook__BidAlreadySubmitted();
        }

        // Convert encrypted bid
        euint64 bid = FHE.asEuint64(encryptedBid);
        
        // Ensure bid is greater than zero
        FHE.req(FHE.gt(bid, FHE.asEuint64(0)));

        // Ensure bidder has sufficient encrypted balance
        IFHERC20 bidToken = IFHERC20(Currency.unwrap(auction.bidCurrency));
        euint64 balance = bidToken.encBalances(msg.sender);
        ebool hasSufficientBalance = FHE.gte(balance, bid);
        FHE.req(hasSufficientBalance);
        
        // Approve hook to spend bid amount
        bidToken.approveEncrypted(address(this), bid);

        // Store bid
        bids[poolId][msg.sender] = bid;
        hasBid[poolId][msg.sender] = true;
        auction.bidders.push(msg.sender);

        // Update max bid using encrypted comparison
        // Note: We don't track winner during bidding to maintain bid privacy
        ebool isHigher = FHE.gt(bid, auction.maxBid);
        auction.maxBid = FHE.select(isHigher, bid, auction.maxBid);

        // Allow contract to interact with bid
        FHE.allowThis(bid);
        FHE.allowThis(auction.maxBid);

        emit BidSubmitted(poolId, msg.sender, block.timestamp);
    }

    /**
     * @notice Settle the auction and determine winner
     * @param key The pool key
     */
    function settleAuction(PoolKey calldata key) external onlyValidPools(key.hooks) {
        PoolId poolId = key.toId();
        Auction storage auction = auctions[poolId];

        // Validate auction can be settled
        if (auction.endTime == 0) {
            revert BlindBidHook__AuctionNotActive();
        }
        if (auction.settled) {
            revert BlindBidHook__AuctionAlreadySettled();
        }
        if (block.timestamp < auction.endTime) {
            revert BlindBidHook__AuctionNotEnded();
        }
        if (auction.bidders.length == 0) {
            revert BlindBidHook__NoBidsSubmitted();
        }

        // Find winner by comparing all encrypted bids
        // We need to iterate and find the maximum bid
        euint64 maxBid = FHE.asEuint64(0);
        address winner = address(0);
        bool winnerFound = false;

        // First pass: find the maximum bid value (encrypted)
        for (uint256 i = 0; i < auction.bidders.length; i++) {
            address bidder = auction.bidders[i];
            euint64 currentBid = bids[poolId][bidder];
            
            // Compare encrypted bids
            ebool isHigher = FHE.gt(currentBid, maxBid);
            maxBid = FHE.select(isHigher, currentBid, maxBid);
        }

        // Second pass: identify the winner by comparing each bid to max
        // Only decrypt the comparison result, not the bid amounts
        // This maintains privacy for all losing bids
        for (uint256 i = 0; i < auction.bidders.length; i++) {
            address bidder = auction.bidders[i];
            euint64 currentBid = bids[poolId][bidder];
            
            // Check if this bid equals the max (encrypted comparison)
            ebool isMax = FHE.eq(currentBid, maxBid);
            
            // Decrypt only the comparison result, not the bid amount
            // This ensures losing bids remain encrypted
            if (FHE.decrypt(isMax) && !winnerFound) {
                winner = bidder;
                winnerFound = true;
                // Break after finding first winner (in case of ties, first bidder wins)
                break;
            }
        }

        // Ensure we have a winner
        if (!winnerFound || winner == address(0)) {
            revert BlindBidHook__NoBidsSubmitted();
        }

        // Mark auction as settled
        auction.settled = true;
        auction.winner = winner;
        auction.maxBid = maxBid;

        // Transfer winning bid amount from winner to auctioneer
        IFHERC20 bidToken = IFHERC20(Currency.unwrap(auction.bidCurrency));
        
        // Get winning bid amount
        euint64 winningBidEncrypted = bids[poolId][winner];
        
        // Transfer encrypted amount from winner to hook
        bidToken.transferFromEncrypted(winner, address(this), winningBidEncrypted);
        
        // Request unwrap of winning bid
        bidToken.requestUnwrap(address(this), winningBidEncrypted);
        
        // Get unwrap result (this decrypts the amount)
        uint128 unwrappedAmount = bidToken.getUnwrapResult(address(this), winningBidEncrypted);
        
        // Transfer unwrapped amount to auctioneer
        bidToken.transfer(auction.auctioneer, unwrappedAmount);

        // Transfer asset from auctioneer to winner
        // Note: Auctioneer must approve this contract first
        IFHERC20 assetToken = IFHERC20(Currency.unwrap(auction.assetCurrency));
        uint256 assetAmount = assetToken.balanceOf(auction.auctioneer);
        if (assetAmount > 0) {
            assetToken.transferFrom(auction.auctioneer, winner, assetAmount);
        }

        emit AuctionSettled(poolId, winner, block.timestamp);
    }

    // ============ View Functions ============
    
    /**
     * @notice Get auction details
     * @param poolId The pool ID
     * @return auction The auction struct
     */
    function getAuction(PoolId poolId) external view returns (Auction memory) {
        return auctions[poolId];
    }

    /**
     * @notice Get encrypted bid for a specific bidder
     * @param poolId The pool ID
     * @param bidder The bidder address
     * @return bid The encrypted bid amount
     */
    function getBid(PoolId poolId, address bidder) external view returns (euint64) {
        return bids[poolId][bidder];
    }

    /**
     * @notice Get bidder count for an auction
     * @param poolId The pool ID
     * @return count Number of bidders
     */
    function getBidderCount(PoolId poolId) external view returns (uint256) {
        return auctions[poolId].bidders.length;
    }

    /**
     * @notice Check if auction is active
     * @param poolId The pool ID
     * @return active Whether auction is currently active
     */
    function isAuctionActive(PoolId poolId) external view returns (bool) {
        Auction memory auction = auctions[poolId];
        return auction.endTime != 0 
            && !auction.settled 
            && block.timestamp >= auction.startTime 
            && block.timestamp < auction.endTime;
    }

    /**
     * @notice Get all bidders for an auction
     * @param poolId The pool ID
     * @return bidders Array of bidder addresses
     */
    function getBidders(PoolId poolId) external view returns (address[] memory) {
        return auctions[poolId].bidders;
    }

    /**
     * @notice Check if address has submitted a bid
     * @param poolId The pool ID
     * @param bidder The address to check
     * @return hasSubmitted Whether the address has submitted a bid
     */
    function hasSubmittedBid(PoolId poolId, address bidder) external view returns (bool) {
        return hasBid[poolId][bidder];
    }
}

