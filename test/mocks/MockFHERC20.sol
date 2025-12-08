// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IFHERC20} from "../../src/interface/IFHERC20.sol";
import {InEuint128, euint128} from "@fhenixprotocol/cofhe-contracts/FHE.sol";

contract MockFHERC20 is ERC20, IFHERC20 {
    mapping(address => euint128) private _encBalances;

    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    // Plain mint/burn
    function mint(address user, uint256 amount) external override {
        _mint(user, amount);
    }
    function burn(address user, uint256 amount) external override {
        _burn(user, amount);
    }

    // Encrypted mint/burn (store as-is)
    function mintEncrypted(address user, InEuint128 memory) external override {
        _encBalances[user] = euint128.wrap(0); // dummy
    }
    function mintEncrypted(address user, euint128 amount) external override {
        _encBalances[user] = amount;
    }
    function burnEncrypted(address, InEuint128 memory) external pure override {}
    function burnEncrypted(address, euint128) external pure override {}

    // Encrypted transfer
    function transferFromEncrypted(address, address, InEuint128 memory) external pure override returns (euint128) {
        return euint128.wrap(0);
    }
    function transferFromEncrypted(address, address, euint128) external pure override returns (euint128) {
        return euint128.wrap(0);
    }

    // Decrypt stubs
    function decryptBalance(address) external pure override {}
    function getDecryptBalanceResult(address) external pure override returns (uint128) { return 0; }
    function getDecryptBalanceResultSafe(address) external pure override returns (uint128, bool) { return (0, true); }

    // Wrap/unwrap stubs
    function wrap(address, uint128) external pure override {}
    function requestUnwrap(address, InEuint128 memory) external pure override returns (euint128) { return euint128.wrap(0); }
    function requestUnwrap(address, euint128) external pure override returns (euint128) { return euint128.wrap(0); }
    function getUnwrapResult(address, euint128) external pure override returns (uint128) { return 0; }
    function getUnwrapResultSafe(address, euint128) external pure override returns (uint128, bool) { return (0, true); }

    // View
    function encBalances(address user) external view override returns (euint128) {
        return _encBalances[user];
    }
}

