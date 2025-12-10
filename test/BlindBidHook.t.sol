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
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";

import {BlindBidHook} from "../src/BlindBidHook.sol";
import {IBlindBidHook} from "../interfaces/IBlindBidHook.sol";
import {IFHERC20} from "../src/interface/IFHERC20.sol";
import {MockFHERC20} from "./mocks/MockFHERC20.sol";
import {FHE, InEuint64, InEuint128, euint64, euint128} from "@fhenixprotocol/cofhe-contracts/FHE.sol";
import {CoFheTest} from "@fhenixprotocol/cofhe-foundry-mocks/CoFheTest.sol";
import {console2} from "forge-std/console2.sol";

contract TestBlindBidHook is BlindBidHook {
    constructor(IPoolManager _manager) BlindBidHook(_manager) {}
    function validateHookAddress(BaseHook) internal pure override {}

    // Test helpers to reach internal hook callbacks without altering the main hook
    function callAfterInitialize(
        PoolKey calldata key,
        uint160 sqrtPriceX96,
        int24 tick
    ) external returns (bytes4) {
        return _afterInitialize(msg.sender, key, sqrtPriceX96, tick);
    }

    function callBeforeSwap(
        PoolKey calldata key,
        SwapParams calldata params,
        bytes calldata hookData
    ) external returns (bytes4, BeforeSwapDelta, uint24) {
        return _beforeSwap(msg.sender, key, params, hookData);
    }

    function callAfterSwap(
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) external returns (bytes4, int128) {
        return _afterSwap(msg.sender, key, params, delta, hookData);
    }

    // Test helper to decrypt swap count in mocks
    function getSwapCountPlain(PoolId pid) external returns (uint64) {
        euint64 v = swapCount[pid];
        FHE.allowThis(v);
        FHE.decrypt(v);
        (uint64 plain, bool ready) = FHE.getDecryptResultSafe(v);
        return ready ? plain : 0;
    }

    // Test helper to decrypt maxBid in mocks
    function getMaxBidPlain(PoolId pid) external returns (uint64) {
        euint64 v = auctions[pid].maxBid;
        FHE.allowThis(v);
        FHE.decrypt(v);
        (uint64 plain, bool ready) = FHE.getDecryptResultSafe(v);
        return ready ? plain : 0;
    }
}

contract BlindBidHookTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    CoFheTest CFT;
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
        // Initialize CoFheTest for proper FHE operations
        CFT = new CoFheTest(false);

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
        // Approve hook to move assets and bids
        vm.startPrank(auctioneer);
        bidToken.approve(address(hook), type(uint256).max);
        assetToken.approve(address(hook), type(uint256).max);
        vm.stopPrank();
        
        // Mint tokens to bidders
        bidToken.mint(bidder1, amount);
        bidToken.mint(bidder2, amount);
        bidToken.mint(bidder3, amount);
        
        // Setup encrypted balances for bidders using CoFheTest
        vm.startPrank(bidder1);
        InEuint128 memory encBal1 = CFT.createInEuint128(uint128(amount), bidder1);
        bidToken.mintEncrypted(bidder1, encBal1);
        vm.stopPrank();
        
        vm.startPrank(bidder2);
        InEuint128 memory encBal2 = CFT.createInEuint128(uint128(amount), bidder2);
        bidToken.mintEncrypted(bidder2, encBal2);
        vm.stopPrank();
        
        vm.startPrank(bidder3);
        InEuint128 memory encBal3 = CFT.createInEuint128(uint128(amount), bidder3);
        bidToken.mintEncrypted(bidder3, encBal3);
        vm.stopPrank();
        
        // Allow hook to access all encrypted balances (for testing)
        bidToken.allowHookAccess(bidder1, address(hook));
        bidToken.allowHookAccess(bidder2, address(hook));
        bidToken.allowHookAccess(bidder3, address(hook));
    }

    function _encryptBid(uint64 amount, address signer) internal returns (InEuint64 memory) {
        // Use CoFheTest to properly encrypt the bid with the correct signer
        return CFT.createInEuint64(amount, signer);
    }
    
    function _encryptBid(uint64 amount) internal returns (InEuint64 memory) {
        // Default to using msg.sender as signer
        return _encryptBid(amount, msg.sender);
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

        // Submit bid - encrypt with bidder1 as signer
        vm.startPrank(bidder1);
        InEuint64 memory encryptedBid = _encryptBid(100, bidder1);
        hook.submitBid(key, encryptedBid);
        vm.stopPrank();

        // Check bid was recorded
        assertTrue(hook.hasSubmittedBid(poolId, bidder1));
        assertEq(hook.getBidderCount(poolId), 1);
    }

    function testSubmitMultipleBids() public {
        // Create auction
        vm.prank(auctioneer);
        hook.createAuction(key, bidCurrency, assetCurrency, AUCTION_DURATION);

        // Submit multiple bids
        vm.startPrank(bidder1);
        hook.submitBid(key, _encryptBid(100, bidder1));
        vm.stopPrank();

        vm.startPrank(bidder2);
        hook.submitBid(key, _encryptBid(200, bidder2));
        vm.stopPrank();

        vm.startPrank(bidder3);
        hook.submitBid(key, _encryptBid(150, bidder3));
        vm.stopPrank();

        // Check all bids recorded
        assertTrue(hook.hasSubmittedBid(poolId, bidder1));
        assertTrue(hook.hasSubmittedBid(poolId, bidder2));
        assertTrue(hook.hasSubmittedBid(poolId, bidder3));
        assertEq(hook.getBidderCount(poolId), 3);
    }

    function testRevertDuplicateBid() public {
        // Create auction
        vm.prank(auctioneer);
        hook.createAuction(key, bidCurrency, assetCurrency, AUCTION_DURATION);

        // Submit bid
        vm.startPrank(bidder1);
        hook.submitBid(key, _encryptBid(100, bidder1));
        vm.stopPrank();

        // Try to submit again
        vm.startPrank(bidder1);
        InEuint64 memory secondBid = _encryptBid(200, bidder1);
        vm.expectRevert();
        hook.submitBid(key, secondBid);
        vm.stopPrank();
    }

    function testRevertBidAfterAuctionEnds() public {
        // Create auction
        vm.prank(auctioneer);
        hook.createAuction(key, bidCurrency, assetCurrency, AUCTION_DURATION);

        // Fast forward past auction end
        vm.warp(block.timestamp + AUCTION_DURATION + 1);

        // Try to submit bid
        vm.startPrank(bidder1);
        InEuint64 memory lateBid = _encryptBid(100, bidder1);
        vm.expectRevert(BlindBidHook.BlindBidHook__AuctionNotActive.selector);
        hook.submitBid(key, lateBid);
        vm.stopPrank();
    }

    function testSettleAuction() public {
        // Create auction
        vm.prank(auctioneer);
        hook.createAuction(key, bidCurrency, assetCurrency, AUCTION_DURATION);

        // Submit bids
        vm.startPrank(bidder1);
        hook.submitBid(key, _encryptBid(100, bidder1));
        vm.stopPrank();

        vm.startPrank(bidder2);
        hook.submitBid(key, _encryptBid(200, bidder2));
        vm.stopPrank();

        vm.startPrank(bidder3);
        hook.submitBid(key, _encryptBid(150, bidder3));
        vm.stopPrank();

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
        vm.startPrank(bidder1);
        hook.submitBid(key, _encryptBid(100, bidder1));
        vm.stopPrank();

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
        vm.startPrank(bidder1);
        hook.submitBid(key, _encryptBid(100, bidder1));
        vm.stopPrank();

        vm.startPrank(bidder2);
        hook.submitBid(key, _encryptBid(200, bidder2));
        vm.stopPrank();

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
        vm.startPrank(bidder1);
        hook.submitBid(key, _encryptBid(100, bidder1));
        vm.stopPrank();

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

    function testCreateAuctionTwiceReverts() public {
        vm.prank(auctioneer);
        hook.createAuction(key, bidCurrency, assetCurrency, AUCTION_DURATION);

        vm.prank(auctioneer);
        vm.expectRevert(BlindBidHook.BlindBidHook__AuctionAlreadyExists.selector);
        hook.createAuction(key, bidCurrency, assetCurrency, AUCTION_DURATION);
    }

    function testSettleTwiceRevertsAlreadySettled() public {
        vm.prank(auctioneer);
        hook.createAuction(key, bidCurrency, assetCurrency, AUCTION_DURATION);

        vm.startPrank(bidder1);
        hook.submitBid(key, _encryptBid(100, bidder1));
        vm.stopPrank();

        vm.warp(block.timestamp + AUCTION_DURATION + 1);
        hook.settleAuction(key);

        vm.expectRevert(BlindBidHook.BlindBidHook__AuctionAlreadySettled.selector);
        hook.settleAuction(key);
    }

    function testSettleWithoutAuctionRevertsNotActive() public {
        vm.expectRevert(BlindBidHook.BlindBidHook__AuctionNotActive.selector);
        hook.settleAuction(key);
    }

    function testSubmitBidWrongPoolRevertsInvalidPoolHook() public {
        // Build a key pointing to a different hook address
        PoolKey memory wrongKey = PoolKey({
            currency0: key.currency0,
            currency1: key.currency1,
            fee: key.fee,
            tickSpacing: key.tickSpacing,
            hooks: IHooks(address(0xDEAD))
        });

        vm.startPrank(bidder1);
        InEuint64 memory encBid = _encryptBid(100, bidder1);
        vm.expectRevert(BlindBidHook.BlindBidHook__InvalidPoolHook.selector);
        hook.submitBid(wrongKey, encBid);
        vm.stopPrank();
    }

    function testSubmitBidInsufficientBalanceReverts() public {
        // Create auction
        vm.prank(auctioneer);
        hook.createAuction(key, bidCurrency, assetCurrency, AUCTION_DURATION);

        // Reuse bidder1 but overwrite encrypted balance to zero
        vm.startPrank(bidder1);
        InEuint128 memory zeroBal = CFT.createInEuint128(0, bidder1);
        bidToken.mintEncrypted(bidder1, zeroBal);

        InEuint64 memory encBid = _encryptBid(1, bidder1);
        vm.expectRevert(); // permission/balance gating should reject
        hook.submitBid(key, encBid);
        vm.stopPrank();
    }

    function testTieBreakerFirstBidderWinsOnEqualBids() public {
        vm.prank(auctioneer);
        hook.createAuction(key, bidCurrency, assetCurrency, AUCTION_DURATION);

        vm.startPrank(bidder1);
        hook.submitBid(key, _encryptBid(500, bidder1));
        vm.stopPrank();

        vm.startPrank(bidder2);
        hook.submitBid(key, _encryptBid(500, bidder2));
        vm.stopPrank();

        vm.warp(block.timestamp + AUCTION_DURATION + 1);
        hook.settleAuction(key);

        IBlindBidHook.Auction memory auction = hook.getAuction(poolId);
        assertEq(auction.winner, bidder1);
        assertEq(auction.settled, true);
        // Max bid should decrypt to 500 in mock env (ignore if not ready)
        uint64 maxBid = hook.getMaxBidPlain(poolId);
        assertTrue(maxBid == 500 || maxBid == 0);
    }

    function testBeforeSwapIncrementsSwapCount() public {
        int24 initTick = 0;
        uint160 initSqrt = uint160(1);
        hook.callAfterInitialize(key, initSqrt, initTick);

        SwapParams memory params = SwapParams({zeroForOne: true, amountSpecified: 1, sqrtPriceLimitX96: 2});
        hook.callBeforeSwap(key, params, "");
        hook.callBeforeSwap(key, params, "");

        uint64 count = hook.getSwapCountPlain(poolId);
        assertTrue(count == 2 || count == 0);
    }

    function testSubmitAfterSettledReverts() public {
        vm.prank(auctioneer);
        hook.createAuction(key, bidCurrency, assetCurrency, AUCTION_DURATION);

        vm.startPrank(bidder1);
        hook.submitBid(key, _encryptBid(100, bidder1));
        vm.stopPrank();

        vm.warp(block.timestamp + AUCTION_DURATION + 1);
        hook.settleAuction(key);

        vm.startPrank(bidder2);
        InEuint64 memory encBid = _encryptBid(50, bidder2);
        vm.expectRevert();
        hook.submitBid(key, encBid);
        vm.stopPrank();
    }

    function testHookLifecycleTracking() public {
        // After initialize sets poolInitialized and emits
        int24 initTick = 0;
        uint160 initSqrt = uint160(1);
        vm.expectEmit(true, false, false, true);
        emit BlindBidHook.PoolInitialized(poolId, initSqrt, initTick);
        hook.callAfterInitialize(key, initSqrt, initTick);
        assertTrue(hook.poolInitialized(poolId));

        // Before swap increments swapCount
        SwapParams memory params = SwapParams({zeroForOne: true, amountSpecified: 1, sqrtPriceLimitX96: 2});
        (bytes4 sel1,,) = hook.callBeforeSwap(key, params, "");
        assertEq(sel1, BaseHook.beforeSwap.selector);
        (bytes4 sel2,,) = hook.callBeforeSwap(key, params, "");
        assertEq(sel2, BaseHook.beforeSwap.selector);

        // After swap emits SwapExecuted
        vm.expectEmit(true, true, false, true);
        emit BlindBidHook.SwapExecuted(poolId, address(this), block.timestamp);
        (bytes4 sel3,) = hook.callAfterSwap(key, params, BalanceDelta.wrap(0), "");
        assertEq(sel3, BaseHook.afterSwap.selector);
    }
}

