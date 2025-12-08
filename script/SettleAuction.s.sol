// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "forge-std/Script.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {BlindBidHook} from "../src/BlindBidHook.sol";

/// @notice Example script for settling an auction
contract SettleAuctionScript is Script {
    function run() public {
        address hookAddress = vm.envAddress("BLINDBID_HOOK_ADDRESS");
        address bidTokenAddress = vm.envAddress("BID_TOKEN_ADDRESS");
        address assetTokenAddress = vm.envAddress("ASSET_TOKEN_ADDRESS");
        
        BlindBidHook hook = BlindBidHook(hookAddress);
        
        // Create pool key (adjust based on your pool)
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(bidTokenAddress) < Currency.wrap(assetTokenAddress) 
                ? Currency.wrap(bidTokenAddress) 
                : Currency.wrap(assetTokenAddress),
            currency1: Currency.wrap(bidTokenAddress) < Currency.wrap(assetTokenAddress)
                ? Currency.wrap(assetTokenAddress)
                : Currency.wrap(bidTokenAddress),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        
        // Settle auction
        vm.broadcast();
        hook.settleAuction(key);
        
        console.log("Auction settled successfully");
    }
}

