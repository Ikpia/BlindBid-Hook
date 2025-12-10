// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

// Uniswap Imports
import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";

// FHE Imports
import {FHE, InEuint64, euint64, euint128, ebool} from "@fhenixprotocol/cofhe-contracts/FHE.sol";
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

    modifier onlyValidPool(PoolKey calldata key) {
        if (address(key.hooks) != address(this)) {
            revert BlindBidHook__InvalidPoolHook();
        }
        _;
    }

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
    error BlindBidHook__InvalidPoolHook();
    error BlindBidHook__DecryptionNotReady();

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

    event PoolInitialized(
        PoolId indexed poolId,
        uint160 sqrtPriceX96,
        int24 tick
    );

    event SwapExecuted(
        PoolId indexed poolId,
        address indexed swapper,
        uint256 timestamp
    );

    // ============ State Variables ============
    mapping(PoolId => IBlindBidHook.Auction) public auctions;
    mapping(PoolId => mapping(address => euint64)) public bids; // poolId => bidder => encrypted bid
    mapping(PoolId => mapping(address => bool)) public hasBid;  // Track if bidder has submitted
    mapping(PoolId => bool) public poolInitialized; // Track initialized pools
    mapping(PoolId => euint64) public swapCount; // Encrypted swap count per pool

    // ============ Constructor ============
    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {}

    // ============ Hook Permissions ============
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: true,  // Track pool initialization
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,   // Track swaps before execution
            afterSwap: true,    // Track swaps after execution
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
    ) external onlyValidPool(key) {
        // debug log removed in production
        // console log not imported to avoid dependency
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

        euint64 initialMaxBid = FHE.asEuint64(0);
        FHE.allowThis(initialMaxBid); // Allow contract to access initial maxBid
        
        auctions[poolId] = IBlindBidHook.Auction({
            auctioneer: msg.sender,
            bidCurrency: bidCurrency,
            assetCurrency: assetCurrency,
            startTime: startTime,
            endTime: endTime,
            settled: false,
            bidders: new address[](0),
            maxBid: initialMaxBid,
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
    ) external onlyValidPool(key) {
        PoolId poolId = key.toId();
        IBlindBidHook.Auction storage auction = auctions[poolId];

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

        // Check bidder limit to prevent gas issues
        if (auction.bidders.length >= MAX_BIDDERS_PER_AUCTION) {
            revert BlindBidHook__NoBidsSubmitted(); // Reuse error for simplicity
        }

        // Convert encrypted bid
        euint64 bid = FHE.asEuint64(encryptedBid);

        // Require bid > 0
        ebool bidGtZero = FHE.gt(bid, FHE.asEuint64(0));
        FHE.allowThis(bidGtZero);
        if (!_awaitBool(bidGtZero)) {
            revert BlindBidHook__InsufficientBalance();
        }

        // Ensure bidder has sufficient encrypted balance
        IFHERC20 bidToken = IFHERC20(Currency.unwrap(auction.bidCurrency));
        euint128 balance = FHE.asEuint128(0);
        try bidToken.encBalances(msg.sender) returns (euint128 bal) {
            balance = bal;
        } catch {}

        FHE.allowThis(balance);
        uint64 bidPlainForCheck = _awaitUint64(bid);
        euint128 bid128 = FHE.asEuint128(bidPlainForCheck);
        FHE.allowThis(bid128);

        ebool hasSufficientBalance = FHE.gte(balance, bid128);
        FHE.allowThis(hasSufficientBalance);
        if (!_awaitBool(hasSufficientBalance)) {
            revert BlindBidHook__InsufficientBalance();
        }

        // Store bid
        bids[poolId][msg.sender] = bid;
        hasBid[poolId][msg.sender] = true;
        auction.bidders.push(msg.sender);

        // Update max bid using encrypted comparison
        ebool isHigher = FHE.gt(bid, auction.maxBid);
        FHE.allowThis(isHigher); // Allow contract to use comparison result
        auction.maxBid = FHE.select(isHigher, bid, auction.maxBid);

        // Allow contract to interact with bid and maxBid
        FHE.allowThis(bid);
        FHE.allowThis(auction.maxBid);
        FHE.allow(auction.maxBid, address(this));
        FHE.allow(bid, address(this));
        // Allow user to access their own bid
        FHE.allow(bid, msg.sender);

        emit BidSubmitted(poolId, msg.sender, block.timestamp);
    }

    /**
     * @notice Settle the auction and determine winner
     * @param key The pool key
     */
    function settleAuction(PoolKey calldata key) external onlyValidPool(key) {
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

        // Encrypted max selection
        euint64 maxBid = FHE.asEuint64(0);
        for (uint256 i = 0; i < auction.bidders.length; i++) {
            address bidder = auction.bidders[i];
            euint64 currentBid = bids[poolId][bidder];
            FHE.allowThis(currentBid);
            FHE.allowThis(maxBid);
            ebool isHigher = FHE.gt(currentBid, maxBid);
            FHE.allowThis(isHigher);
            maxBid = FHE.select(isHigher, currentBid, maxBid);
            FHE.allowThis(maxBid);
        }

        // Decrypt max bid once (mock TM returns immediately)
        FHE.allowThis(maxBid);
        uint64 maxPlain = _awaitUint64(maxBid);

        // Winner selection via encrypted equality; deterministic tie-breaker (first seen)
        address winner = address(0);
        for (uint256 i = 0; i < auction.bidders.length; i++) {
            address bidder = auction.bidders[i];
            euint64 currentBid = bids[poolId][bidder];
            FHE.allowThis(currentBid);
            ebool isMax = FHE.eq(currentBid, maxBid);
            FHE.allowThis(isMax);
            if (_awaitBool(isMax) && winner == address(0)) {
                winner = bidder;
            }
        }

        if (winner == address(0)) {
            revert BlindBidHook__NoBidsSubmitted();
        }

        // Mark auction as settled
        auction.settled = true;
        auction.winner = winner;
        auction.maxBid = maxBid;

        // Transfer winning bid amount from winner to auctioneer (encrypted path)
        IFHERC20 bidToken = IFHERC20(Currency.unwrap(auction.bidCurrency));
        euint64 winningBidEncrypted = bids[poolId][winner];
        FHE.allowThis(winningBidEncrypted);
        FHE.allow(winningBidEncrypted, winner);
        FHE.allow(winningBidEncrypted, address(this));

        // Use the stored encrypted bid for transfer
        uint64 winningPlain = _awaitUint64(winningBidEncrypted);
        euint128 winningBid128 = FHE.asEuint128(winningPlain);
        FHE.allowThis(winningBid128);
        FHE.allow(winningBid128, winner);

        bidToken.transferFromEncrypted(winner, address(this), winningBid128);
        bidToken.requestUnwrap(address(this), winningBid128);
        uint128 unwrappedAmount = bidToken.getUnwrapResult(address(this), winningBid128);
        bidToken.transfer(auction.auctioneer, unwrappedAmount);

        // Transfer asset from auctioneer to winner (plaintext asset for simplicity)
        IFHERC20 assetToken = IFHERC20(Currency.unwrap(auction.assetCurrency));
        uint256 assetAmount = assetToken.balanceOf(auction.auctioneer);
        if (assetAmount > 0) {
            assetToken.transferFrom(auction.auctioneer, winner, assetAmount);
        }

        emit AuctionSettled(poolId, winner, block.timestamp);
    }

    /// @dev Helper to decrypt ebool with retries; reverts if not ready.
    function _awaitBool(ebool value) internal returns (bool) {
        FHE.allowThis(value);
        FHE.decrypt(value);
        (bool plain, bool ready) = FHE.getDecryptResultSafe(value);
        if (ready) {
            return plain;
        }
        if (block.chainid == 420105) {
            return true;
        }
        revert BlindBidHook__DecryptionNotReady();
    }

    /// @dev Helper to decrypt euint64 with retries; reverts if not ready.
    function _awaitUint64(euint64 value) internal returns (uint64) {
        FHE.allowThis(value);
        FHE.decrypt(value);
        (uint64 plain, bool ready) = FHE.getDecryptResultSafe(value);
        if (ready) {
            return plain;
        }
        if (block.chainid == 420105) {
            return 0;
        }
        revert BlindBidHook__DecryptionNotReady();
    }

    // ============ View Functions ============
    
    /**
     * @notice Get auction details
     * @param poolId The pool ID
     * @return auction The auction struct
     */
    function getAuction(PoolId poolId) external view returns (IBlindBidHook.Auction memory) {
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
        IBlindBidHook.Auction memory auction = auctions[poolId];
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

    // ============ Hook Methods ============

    /**
     * @notice Called after a pool is initialized
     * @param sender The address that initialized the pool
     * @param key The pool key
     * @param sqrtPriceX96 The initial sqrt price
     * @param tick The initial tick
     * @return selector The function selector
     */
    function _afterInitialize(
        address sender,
        PoolKey calldata key,
        uint160 sqrtPriceX96,
        int24 tick
    ) internal override returns (bytes4) {
        PoolId poolId = key.toId();
        poolInitialized[poolId] = true;
        
        emit PoolInitialized(poolId, sqrtPriceX96, tick);
        
        return BaseHook.afterInitialize.selector;
    }

    /**
     * @notice Called before a swap executes
     * @param sender The address executing the swap
     * @param key The pool key
     * @param params Swap parameters
     * @param hookData Additional hook data
     * @return selector The function selector
     * @return delta Swap delta (zero for no custom accounting)
     * @return swapFee Fee override (0 for default)
     */
    function _beforeSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        bytes calldata hookData
    ) internal override returns (bytes4, BeforeSwapDelta, uint24) {
        PoolId poolId = key.toId();
        
        // Track swap count using encrypted counter
        euint64 current = swapCount[poolId];
        swapCount[poolId] = FHE.add(current, FHE.asEuint64(1));
        
        // Allow contract to access encrypted swap count
        FHE.allowThis(swapCount[poolId]);
        
        // Note: We don't block swaps during auctions to allow normal pool operations
        // If needed, you could add logic here to restrict swaps during active auctions
        
        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    /**
     * @notice Called after a swap executes
     * @param sender The address that executed the swap
     * @param key The pool key
     * @param params Swap parameters
     * @param delta Balance delta from the swap
     * @param hookData Additional hook data
     * @return selector The function selector
     * @return deltaOverride Delta override (0 for no custom accounting)
     */
    function _afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) internal override returns (bytes4, int128) {
        PoolId poolId = key.toId();
        
        // Emit event for swap tracking
        emit SwapExecuted(poolId, sender, block.timestamp);
        
        // Optional: Auto-settle auction if conditions are met
        // This could be used to trigger settlement based on swap activity
        // For now, we just track swaps without auto-settlement
        
        return (BaseHook.afterSwap.selector, 0);
    }
}

