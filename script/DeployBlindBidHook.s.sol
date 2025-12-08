// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "forge-std/Script.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {Constants} from "./base/Constants.sol";
import {BlindBidHook} from "../src/BlindBidHook.sol";
import {HookMiner} from "v4-periphery/src/utils/HookMiner.sol";

/// @notice Mines the address and deploys the BlindBidHook.sol contract
contract DeployBlindBidHookScript is Script, Constants {
    function setUp() public {}

    function run() public {
        // BlindBidHook doesn't require specific hook flags since it doesn't use hook callbacks
        // But we'll set minimal flags for compatibility
        uint160 flags = uint160(0);

        // Mine a salt that will produce a hook address with the correct flags
        bytes memory constructorArgs = abi.encode(IPoolManager(POOLMANAGER));
        (address hookAddress, bytes32 salt) =
            HookMiner.find(CREATE2_DEPLOYER, flags, type(BlindBidHook).creationCode, constructorArgs);

        // Deploy the hook using CREATE2
        vm.broadcast();
        BlindBidHook hook = new BlindBidHook{salt: salt}(IPoolManager(POOLMANAGER));
        require(address(hook) == hookAddress, "DeployBlindBidHookScript: hook address mismatch");
        
        console.log("BlindBidHook deployed at:", address(hook));
        console.log("Salt used:", vm.toString(salt));
    }
}

