// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "forge-std/Test.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";

import {BlindBidHook} from "../src/BlindBidHook.sol";
import {HybridFHERC20} from "../src/HybridFHERC20.sol";
import {IFHERC20} from "../src/interface/IFHERC20.sol";
import {FHE, InEuint64, euint64} from "@fhenixprotocol/cofhe-contracts/FHE.sol";

contract BlindBidHookTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    BlindBidHook hook;
    PoolKey key;
    PoolId poolId;

    HybridFHERC20 bidToken;
    HybridFHERC20 assetToken;
    Currency bidCurrency;
    Currency assetCurrency;

    address auctioneer = address(0xA11CE);
    address bidder1 = address(0xB1DDER1);
    address bidder2 = address(0xB1DDER2);
    address bidder3 = address(0xB1DDER3);

    uint256 constant AUCTION_DURATION = 1 days;

    function setUp() public {
        initializeManagerRoutersAndPoolsWithLiq(IHooks(address(0)));

        // Deploy hook
        address hookFlags = address(
            uint160(Hooks.AFTER_SWAP_FLAG) ^ (0x4444 << 144)
        );
        bytes memory constructorArgs = abi.encode(manager);
        deployCodeTo("BlindBidHook.sol:BlindBidHook", constructorArgs, hookFlags);
        hook = BlindBidHook(hookFlags);

        // Deploy tokens
        bidToken = new HybridFHERC20("BidToken", "BID");
        assetToken = new HybridFHERC20("AssetToken", "ASSET");
        
        bidCurrency = Currency.wrap(address(bidToken));
        assetCurrency = Currency.wrap(address(assetToken));

        // Create pool
        key = PoolKey({
            currency0: bidCurrency < assetCurrency ? bidCurrency : assetCurrency,
            currency1: bidCurrency < assetCurrency ? assetCurrency : bidCurrency,
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(hook)
        });
        poolId = key.toId();

        // Initialize pool
        manager.initialize(key, TickMath.getSqrtPriceAtTick(0));

        // Setup tokens for auctioneer and bidders
        _setupTokens();
    }

    function _setupTokens() internal {
        uint256 amount = 1000e18;
        
        // Mint tokens to auctioneer
        bidToken.mint(auctioneer, amount);
        assetToken.mint(auctioneer, amount);
        
        // Mint tokens to bidders
        bidToken.mint(bidder1, amount);
        bidToken.mint(bidder2, amount);
        bidToken.mint(bidder3, amount);

        // Wrap tokens for encrypted operations
        vm.prank(bidder1);
        bidToken.wrap(bidder1, uint128(amount));
        
        vm.prank(bidder2);
        bidToken.wrap(bidder2, uint128(amount));
        
        vm.prank(bidder3);
        bidToken.wrap(bidder3, uint128(amount));

        // Approve hook to spend encrypted tokens
        vm.prank(bidder1);
        bidToken.approve(address(hook), type(uint256).max);
        
        vm.prank(bidder2);
        bidToken.approve(address(hook), type(uint256).max);
        
        vm.prank(bidder3);
        bidToken.approve(address(hook), type(uint256).max);

        // Approve asset token transfer from auctioneer
        vm.prank(auctioneer);
        assetToken.approve(address(hook), type(uint256).max);
    }

    function _encryptBid(uint64 amount) internal pure returns (InEuint64 memory) {
        // In real implementation, this would use FHE encryption
        // For testing, we'll use a mock approach
        return InEuint64({
            data: abi.encode(amount),
            publicKey: bytes("")
        });
    }

    function testCreateAuction() public {
        vm.prank(auctioneer);
        hook.createAuction(key, bidCurrency, assetCurrency, AUCTION_DURATION);

        (address auctioneerAddr,,,, uint256 endTime, bool settled,,,) = hook.auctions(poolId);
        assertEq(auctioneerAddr, auctioneer);
        assertEq(endTime, block.timestamp + AUCTION_DURATION);
        assertFalse(settled);
    }

    function testSubmitBid() public {
        // Create auction
        vm.prank(auctioneer);
        hook.createAuction(key, bidCurrency, assetCurrency, AUCTION_DURATION);

        // Submit bid
        InEuint64 memory encryptedBid = _encryptBid(100);
        
        vm.prank(bidder1);
        hook.submitBid(key, encryptedBid);

        // Check bid was recorded
        assertTrue(hook.hasBid(poolId, bidder1));
        assertEq(hook.getBidderCount(poolId), 1);
    }

    function testSubmitMultipleBids() public {
        // Create auction
        vm.prank(auctioneer);
        hook.createAuction(key, bidCurrency, assetCurrency, AUCTION_DURATION);

        // Submit multiple bids
        vm.prank(bidder1);
        hook.submitBid(key, _encryptBid(100));

        vm.prank(bidder2);
        hook.submitBid(key, _encryptBid(200));

        vm.prank(bidder3);
        hook.submitBid(key, _encryptBid(150));

        // Check all bids recorded
        assertTrue(hook.hasBid(poolId, bidder1));
        assertTrue(hook.hasBid(poolId, bidder2));
        assertTrue(hook.hasBid(poolId, bidder3));
        assertEq(hook.getBidderCount(poolId), 3);
    }

    function testRevertDuplicateBid() public {
        // Create auction
        vm.prank(auctioneer);
        hook.createAuction(key, bidCurrency, assetCurrency, AUCTION_DURATION);

        // Submit bid
        vm.prank(bidder1);
        hook.submitBid(key, _encryptBid(100));

        // Try to submit again
        vm.prank(bidder1);
        vm.expectRevert(BlindBidHook.BlindBidHook__BidAlreadySubmitted.selector);
        hook.submitBid(key, _encryptBid(200));
    }

    function testRevertBidAfterAuctionEnds() public {
        // Create auction
        vm.prank(auctioneer);
        hook.createAuction(key, bidCurrency, assetCurrency, AUCTION_DURATION);

        // Fast forward past auction end
        vm.warp(block.timestamp + AUCTION_DURATION + 1);

        // Try to submit bid
        vm.prank(bidder1);
        vm.expectRevert(BlindBidHook.BlindBidHook__AuctionNotActive.selector);
        hook.submitBid(key, _encryptBid(100));
    }

    function testSettleAuction() public {
        // Create auction
        vm.prank(auctioneer);
        hook.createAuction(key, bidCurrency, assetCurrency, AUCTION_DURATION);

        // Submit bids
        vm.prank(bidder1);
        hook.submitBid(key, _encryptBid(100));

        vm.prank(bidder2);
        hook.submitBid(key, _encryptBid(200));

        vm.prank(bidder3);
        hook.submitBid(key, _encryptBid(150));

        // Fast forward to auction end
        vm.warp(block.timestamp + AUCTION_DURATION + 1);

        // Settle auction
        hook.settleAuction(key);

        // Check auction is settled
        (,,,,, bool settled,, address winner,) = hook.auctions(poolId);
        assertTrue(settled);
        assertEq(winner, bidder2); // Highest bidder
    }

    function testRevertSettleBeforeAuctionEnds() public {
        // Create auction
        vm.prank(auctioneer);
        hook.createAuction(key, bidCurrency, assetCurrency, AUCTION_DURATION);

        // Submit bid
        vm.prank(bidder1);
        hook.submitBid(key, _encryptBid(100));

        // Try to settle before end
        vm.expectRevert(BlindBidHook.BlindBidHook__AuctionNotEnded.selector);
        hook.settleAuction(key);
    }

    function testRevertSettleWithNoBids() public {
        // Create auction
        vm.prank(auctioneer);
        hook.createAuction(key, bidCurrency, assetCurrency, AUCTION_DURATION);

        // Fast forward to auction end
        vm.warp(block.timestamp + AUCTION_DURATION + 1);

        // Try to settle with no bids
        vm.expectRevert(BlindBidHook.BlindBidHook__NoBidsSubmitted.selector);
        hook.settleAuction(key);
    }

    function testIsAuctionActive() public {
        // Create auction
        vm.prank(auctioneer);
        hook.createAuction(key, bidCurrency, assetCurrency, AUCTION_DURATION);

        // Check active
        assertTrue(hook.isAuctionActive(poolId));

        // Fast forward past end
        vm.warp(block.timestamp + AUCTION_DURATION + 1);
        assertFalse(hook.isAuctionActive(poolId));
    }

    function testGetAuction() public {
        // Create auction
        vm.prank(auctioneer);
        hook.createAuction(key, bidCurrency, assetCurrency, AUCTION_DURATION);

        // Get auction
        BlindBidHook.Auction memory auction = hook.getAuction(poolId);
        assertEq(auction.auctioneer, auctioneer);
        assertEq(auction.bidCurrency, bidCurrency);
        assertEq(auction.assetCurrency, assetCurrency);
        assertFalse(auction.settled);
    }

    function testGetBidders() public {
        // Create auction
        vm.prank(auctioneer);
        hook.createAuction(key, bidCurrency, assetCurrency, AUCTION_DURATION);

        // Submit bids
        vm.prank(bidder1);
        hook.submitBid(key, _encryptBid(100));

        vm.prank(bidder2);
        hook.submitBid(key, _encryptBid(200));

        // Get bidders
        address[] memory bidders = hook.getBidders(poolId);
        assertEq(bidders.length, 2);
        assertEq(bidders[0], bidder1);
        assertEq(bidders[1], bidder2);
    }

    function testHasSubmittedBid() public {
        // Create auction
        vm.prank(auctioneer);
        hook.createAuction(key, bidCurrency, assetCurrency, AUCTION_DURATION);

        // Submit bid
        vm.prank(bidder1);
        hook.submitBid(key, _encryptBid(100));

        // Check bid status
        assertTrue(hook.hasSubmittedBid(poolId, bidder1));
        assertFalse(hook.hasSubmittedBid(poolId, bidder2));
    }

    function testRevertInvalidDuration() public {
        // Try to create auction with zero duration
        vm.prank(auctioneer);
        vm.expectRevert(BlindBidHook.BlindBidHook__InvalidDuration.selector);
        hook.createAuction(key, bidCurrency, assetCurrency, 0);

        // Try to create auction with excessive duration
        vm.prank(auctioneer);
        vm.expectRevert(BlindBidHook.BlindBidHook__InvalidDuration.selector);
        hook.createAuction(key, bidCurrency, assetCurrency, 366 days);
    }
}

