# BlindBid Hook Architecture

## Overview
BlindBid Hook enables encrypted auctions for NFTs and tokens within Uniswap v4 pools using Fhenix FHE (Fully Homomorphic Encryption).

## Core Components

### BlindBidHook Contract
Main contract implementing the auction logic:
- Auction lifecycle management
- Encrypted bid storage and comparison
- Winner determination using FHE operations
- Asset transfer coordination

### Key Data Structures

#### Auction Struct
```solidity
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
```

#### Encrypted Bid Storage
- `bids[poolId][bidder]` - Encrypted bid amounts
- `hasBid[poolId][bidder]` - Bid submission tracking

## Auction Flow

### 1. Auction Creation
- Auctioneer creates auction with currencies and duration
- Auction becomes active at startTime

### 2. Bid Submission Phase
- Bidders submit encrypted bids (euint64)
- Bids are stored encrypted, never revealed
- Maximum bid is tracked using encrypted comparisons

### 3. Auction Settlement
- After endTime, anyone can settle
- Winner determined by encrypted max comparison
- Assets transferred atomically

## FHE Operations

### Encrypted Comparisons
- `FHE.gt(a, b)` - Greater than comparison
- `FHE.eq(a, b)` - Equality check
- `FHE.select(condition, a, b)` - Conditional selection

### Privacy Guarantees
- Bid amounts remain encrypted during auction
- Only winning bid is decrypted
- Losing bids never revealed

## Integration Points

### Uniswap v4
- Uses BaseHook for pool integration
- No hook callbacks needed (standalone auctions)
- Pool serves as coordination mechanism

### Fhenix FHE
- Uses cofhe-contracts for FHE operations
- Requires HybridFHERC20 tokens for encrypted transfers
- Supports euint64 for bid amounts

## Gas Considerations

### Bid Submission
- O(1) storage operations
- Single FHE comparison
- Minimal gas cost

### Settlement
- O(n) iteration over bidders
- Multiple FHE operations
- Decryption overhead
- Consider gas limits for large auctions

## Future Enhancements

1. **Bid Withdrawal**: Allow bidders to withdraw before auction end
2. **Reserve Price**: Add minimum bid requirements
3. **Fee Mechanism**: Protocol fees for sustainability
4. **Multi-Asset Auctions**: Support multiple assets per auction
5. **Time Extensions**: Sniping protection mechanisms

