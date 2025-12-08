# BlindBid Hook

**Encrypted NFT/Token Auctions in AMM Pools**

## Overview

BlindBid Hook enables fully encrypted auctions for NFTs and tokens within Uniswap v4 pools. This is the first implementation of encrypted auctions using Uniswap v4 hooks, leveraging Fhenix FHE (Fully Homomorphic Encryption) technology.

## The Innovation

The Gap: All winning hooks focused on swaps/lending. Nobody built encrypted auctions using hooks.

### Key Features:

Users submit encrypted bids (euint64) for NFTs or rare tokens listed in special pools
All bids completely hidden until auction closes
Hook aggregates encrypted bids using Fhenix FHE operations (max, comparison)
Winner determined by highest encrypted bid WITHOUT revealing losing bids
Losers never know how much winner paid (prevents price discovery gaming)

Why It Wins:

✅ Totally novel: First encrypted auction hook
✅ NFT market fit: High-value NFTs need bid privacy (prevent sniping)
✅ Pure FHE showcase: Complex encrypted comparisons (euint64.max)
✅ Game theory impact: Changes bidding behavior when competitors are blind
✅ Demo wow: "5 bidders, only winner knows they won, all bids stay secret"

Technical Flow:
solidity// Bid submission (encrypted)
function submitBid(PoolId poolId, inEuint64 calldata encryptedBid) external {
    euint64 bid = TFHE.asEuint64(encryptedBid);
    bids[poolId][msg.sender] = bid;
    emit BidSubmitted(msg.sender); // Amount HIDDEN
}

// Auction settlement (encrypted comparison)
function settleAuction(PoolId poolId) external {
    euint64 maxBid = TFHE.asEuint64(0);
    address winner;
    
    // Find max bid (fully encrypted!)
    for (address bidder in bidders[poolId]) {
        euint64 currentBid = bids[poolId][bidder];
        ebool isHigher = TFHE.gt(currentBid, maxBid);
        maxBid = TFHE.select(isHigher, currentBid, maxBid);
        winner = isHigher ? bidder : winner; // Simplified
    }
    
    // Winner gets NFT, pays encrypted amount
    // Losing bids NEVER revealed


Use Cases:

High-value NFT sales (CryptoPunks, Bored Apes)
Rare token allocations (presales, IDOs)
Liquidation auctions (hide distressed asset prices)
Treasury token sales (DAOs selling assets privately)

## Installation

```bash
# Install dependencies
pnpm install

# Run tests
forge test --via-ir

# Deploy
forge script script/DeployBlindBidHook.s.sol
```

## Usage

### Creating an Auction

```solidity
// Create auction with 1 day duration
hook.createAuction(
    poolKey,
    bidCurrency,    // Currency for bids (e.g., USDC)
    assetCurrency,  // Asset being auctioned
    1 days          // Duration
);
```

### Submitting a Bid

```solidity
// Submit encrypted bid
InEuint64 memory encryptedBid = encryptBid(1000);
hook.submitBid(poolKey, encryptedBid);
```

### Settling an Auction

```solidity
// After auction ends, settle to determine winner
hook.settleAuction(poolKey);
```

## Architecture

See [ARCHITECTURE.md](docs/ARCHITECTURE.md) for detailed architecture documentation.

## Security

See [AUDIT.md](docs/AUDIT.md) for security considerations and audit notes.

## License

MIT
