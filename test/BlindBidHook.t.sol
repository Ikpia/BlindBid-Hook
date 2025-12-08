// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "forge-std/Test.sol";
import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {HookMiner} from "v4-periphery/src/utils/HookMiner.sol";
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
import {IBlindBidHook} from "../interfaces/IBlindBidHook.sol";
import {IFHERC20} from "../src/interface/IFHERC20.sol";
import {MockFHERC20} from "./mocks/MockFHERC20.sol";
import {FHE, InEuint64, euint64} from "@fhenixprotocol/cofhe-contracts/FHE.sol";
import {console2} from "forge-std/console2.sol";

contract TestBlindBidHook is BlindBidHook {
    constructor(IPoolManager _manager) BlindBidHook(_manager) {}
    function validateHookAddress(BaseHook) internal pure override {}
}

contract BlindBidHookTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    TestBlindBidHook hook;
    IPoolManager dummyManager = IPoolManager(address(0xBEEF));
    PoolId poolId;

    MockFHERC20 bidToken;
    MockFHERC20 assetToken;
    Currency bidCurrency;
    Currency assetCurrency;

    address auctioneer = address(0xA11CE);
    // Distinct test addresses (valid hex literals)
    address bidder1 = address(0xB1DD001);
    address bidder2 = address(0xB1DD002);
    address bidder3 = address(0xB1DD003);

    uint256 constant AUCTION_DURATION = 1 days;

    function setUp() public {
        // Stub the FHE task manager so library calls do not revert during tests
        bytes memory stubCode = hex"60006000f3"; // minimal runtime that simply returns
        vm.etch(0xeA30c4B8b44078Bbf8a6ef5b9f1eC1626C7848D9, stubCode);

        // Deploy hook at an address that satisfies hook flag requirements (flags = 0)
        uint160 flags = 0;
        bytes memory constructorArgs = abi.encode(dummyManager);
        (address hookAddr, bytes32 salt) =
            HookMiner.find(address(this), flags, type(TestBlindBidHook).creationCode, constructorArgs);

        hook = new TestBlindBidHook{salt: salt}(dummyManager);
        console2.log("expected hookAddr", hookAddr);
        console2.log("actual hookAddr", address(hook));
        console2.log("deployed hook");

        // Deploy tokens
        bidToken = new MockFHERC20("BidToken", "BID");
        assetToken = new MockFHERC20("AssetToken", "ASSET");
        console2.log("deployed tokens");
        
        bidCurrency = Currency.wrap(address(bidToken));
        assetCurrency = Currency.wrap(address(assetToken));

        // Create pool key (no on-chain pool needed for unit tests)
        key = PoolKey({
            currency0: bidCurrency < assetCurrency ? bidCurrency : assetCurrency,
            currency1: bidCurrency < assetCurrency ? assetCurrency : bidCurrency,
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(hook)
        });
        poolId = key.toId();
        console2.log("pool key ready");

        // Setup tokens for auctioneer and bidders
        _setupTokens();
        console2.log("tokens setup done");
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
    }

    function _encryptBid(uint64 amount) internal pure returns (InEuint64 memory) {
        InEuint64 memory encryptedBid;
        return encryptedBid;
    }

    function testCreateAuction() public {
        vm.prank(auctioneer);
        hook.createAuction(key, bidCurrency, assetCurrency, AUCTION_DURATION);

        IBlindBidHook.Auction memory auction = hook.getAuction(poolId);
        assertEq(auction.auctioneer, auctioneer);
        assertEq(auction.endTime, block.timestamp + AUCTION_DURATION);
        assertFalse(auction.settled);
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
        IBlindBidHook.Auction memory auction = hook.getAuction(poolId);
        assertTrue(auction.settled);
        assertTrue(auction.winner != address(0));
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
        IBlindBidHook.Auction memory auction = hook.getAuction(poolId);
        assertEq(auction.auctioneer, auctioneer);
        assertEq(Currency.unwrap(auction.bidCurrency), Currency.unwrap(bidCurrency));
        assertEq(Currency.unwrap(auction.assetCurrency), Currency.unwrap(assetCurrency));
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

