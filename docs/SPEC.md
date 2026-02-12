# Contract Specifications

This document provides technical specifications for all Sarafu Network Protocol smart contracts.

## Table of Contents

- [GiftableToken](#giftabletoken)
- [SwapPool](#swappool)
- [Splitter](#splitter)
- [FeePolicy](#feepolicy)
- [Limiter](#limiter)
- [RelativeQuoter](#relativequoter)
- [ProtocolFeeController](#protocolfeecontroller)
- [DecimalQuoter](#decimalquoter)

---

## GiftableToken

ERC20 token with minting, burning, expiry, and writer permissions.

**Proxy:** Yes (ERC1967)

**Storage:**
- `writers` - Mapping of authorized minters
- `expired` - Token expiry state flag
- `totalBurned` - Cumulative burned amount
- `totalMinted` - Cumulative minted amount
- Token metadata (name, symbol, decimals)
- `_expires` - Expiry timestamp (0 = never expires)

**Key Functions:**
- `initialize(name, symbol, decimals, owner, expiresAt)` - Initialize the token
- `mint(to, amount)` - Mint tokens (owner or writer only)
- `mintTo(to, amount)` - Alias for mint
- `burn(amount)` - Burn tokens from caller
- `addWriter(address)` - Grant minting permission (owner only)
- `deleteWriter(address)` - Revoke minting permission (owner only)
- `expire()` - Manually expire the token (owner only)

**Validation:**
- Only owner or writers can mint
- Token cannot be transferred after expiry
- Auto-expires when block.timestamp > expiresAt (if set)

**Events:**
- `Mint(minter, beneficiary, value)`
- `Burn(from, value)`
- `Expired(timestamp)`
- `WriterAdded(writer)`
- `WriterRemoved(writer)`

---

## SwapPool

Automated Market Maker (AMM) for token swaps with configurable fees, limits, and quoters.

**Proxy:** Yes (ERC1967)

**Storage:**
- `tokenRegistry` - Optional registry for token whitelist
- `tokenLimiter` - Contract that defines holder limits
- `quoter` - Price quoter for swap calculations
- `feeAddress` - Recipient of accumulated fees
- `feePolicy` - Contract that determines swap fees
- `protocolFeeController` - Protocol-level fee controller
- `feesDecoupled` - Whether fees are separate from liquidity
- `fees` - Mapping of accumulated fees per token
- Token balances and LP token metadata
- Seal state (0-7) for progressive initialization

**Key Functions:**
- `initialize(name, symbol, decimals, owner, feePolicy, feeAddress, tokenRegistry, tokenLimiter, quoter, feesDecoupled, protocolFeeController)` - Initialize pool
- `deposit(token, value)` - Add liquidity
- `withdraw(token, value)` - Remove liquidity
- `swap(tokenIn, tokenOut, value)` - Execute token swap
- `seal(state)` - Lock pool configuration at initialization stage
- `setFeePolicy(address)` - Update fee policy (owner only)
- `setQuoter(address)` - Update quoter (owner only)
- `collectFees(token)` - Withdraw accumulated fees (owner only)

**Seal States:**
- 0: Unsealed (can modify all)
- 1+: Progressive locking of configuration

**Validation:**
- Tokens must pass registry check (if registry set)
- Holder limits enforced via limiter
- Fees calculated via fee policy
- Cannot modify sealed components

**Events:**
- `Deposit(depositor, token, value)`
- `Withdrawal(withdrawer, token, value)`
- `Swap(initiator, tokenIn, tokenOut, inValue, outValue, fee)`
- `FeeCollected(collector, token, value)`

---

## Splitter

Payment splitter that distributes ETH and ERC20 tokens among multiple recipients.

**Proxy:** Yes (ERC1967)

**Storage:**
- `_splitHash` - Hash of accounts and allocations for validation

**Key Functions:**
- `initialize(owner, accounts, percentAllocations)` - Set up split configuration
- `updateSplit(accounts, percentAllocations)` - Modify split (owner only)
- `distributeETH(accounts, percentAllocations)` - Split ETH balance among recipients
- `distributeERC20(token, accounts, percentAllocations)` - Split ERC20 balance among recipients
- `getHash()` - Returns current split hash

**Split Hash:**
- `splitHash = keccak256(abi.encodePacked(accounts, percentAllocations))`
- Validates that distribution parameters match initialized configuration

**Validation:**
- At least 2 recipients
- `accounts.length == percentAllocations.length`
- All allocations are non-zero
- No duplicate accounts
- Allocations sum to `1_000_000` (100% in PPM)

**Distribution:**
- Processes N-1 recipients with calculated shares
- Remainder goes to last recipient (handles rounding)
- Empty balances return early (no-op)

**Events:**
- None (implicit transfers only)

---

## FeePolicy

Configurable fee policy with default and per-pair fee rates.

**Proxy:** Yes (ERC1967)

**Storage:**
- `defaultFee` - Default fee for all pairs (in PPM)
- `pairFees` - Mapping of token pair => custom fee

**Constants:**
- `PPM = 1_000_000` (100%)

**Key Functions:**
- `initialize(owner, defaultFee)` - Set owner and default fee
- `getFee(tokenIn, tokenOut)` - Get fee for specific pair
- `getDefaultFee()` - Get default fee
- `isActive()` - Always returns true
- `setDefaultFee(fee)` - Update default fee (owner only)
- `setPairFee(tokenIn, tokenOut, fee)` - Set custom fee for pair (owner only)
- `removePairFee(tokenIn, tokenOut)` - Remove custom pair fee (owner only)

**Validation:**
- Fees cannot exceed PPM (100%)

**Pair Key:**
- `keccak256(abi.encodePacked(tokenIn, tokenOut))`
- Separate key for each direction (A→B ≠ B→A)

**Events:**
- `DefaultFeeUpdated(oldFee, newFee)`
- `PairFeeUpdated(tokenIn, tokenOut, oldFee, newFee)`
- `PairFeeRemoved(tokenIn, tokenOut)`

---

## Limiter

Per-token, per-holder deposit/balance limits.

**Proxy:** Yes (ERC1967)

**Storage:**
- `limits` - Mapping of token => holder => limit
- `writers` - Addresses that can set limits

**Key Functions:**
- `initialize(owner)` - Set owner
- `limitOf(token, holder)` - Get limit for holder
- `setLimit(token, holder, limit)` - Set limit (owner or writer only)
- `addWriter(address)` - Grant writer permission (owner only)
- `deleteWriter(address)` - Revoke writer permission (owner only)
- `isWriter(address)` - Check if address is writer

**Validation:**
- Only owner or writers can set limits
- Holder cannot be zero address

**Events:**
- `LimitSet(token, holder, value)`
- `WriterAdded(writer)`
- `WriterRemoved(writer)`

---

## RelativeQuoter

Price quoter using exchange rates relative to a base unit.

**Proxy:** Yes (ERC1967)

**Storage:**
- `priceIndex` - Mapping of token => exchange rate

**Constants:**
- `PPM = 1_000_000` (default rate if not set)

**Key Functions:**
- `initialize(owner)` - Set owner
- `setPriceIndexValue(token, exchangeRate)` - Set exchange rate (owner only)
- `valueFor(outToken, inToken, value)` - Calculate output amount for swap

**Calculation:**
```
outValue = (value * inExchangeRate * 10^outDecimals) / (outExchangeRate * 10^inDecimals)
```

Where:
- Exchange rate defaults to PPM if not set
- Adjusts for token decimal differences

**Events:**
- `PriceIndexUpdated(tokenAddress, exchangeRate)`

---

## ProtocolFeeController

Protocol-level fee configuration and recipient management.

**Proxy:** Yes (ERC1967)

**Storage:**
- `protocolFee` - Protocol fee in PPM
- `protocolFeeRecipient` - Address that receives protocol fees
- `active` - Whether protocol fees are enabled

**Constants:**
- `PPM = 1_000_000` (100%)

**Key Functions:**
- `initialize(owner, initialFee, initialRecipient)` - Set up protocol fee
- `getProtocolFee()` - Get current protocol fee (0 if inactive)
- `getProtocolFeeRecipient()` - Get fee recipient
- `isActive()` - Check if protocol fees are enabled
- `setProtocolFee(fee)` - Update protocol fee (owner only)
- `setProtocolFeeRecipient(recipient)` - Update recipient (owner only)
- `setActiveState(active)` - Enable/disable protocol fees (owner only)

**Validation:**
- Fee cannot exceed PPM (100%)
- Recipient cannot be zero address

**Events:**
- `ProtocolFeeUpdated(oldFee, newFee)`
- `ProtocolFeeRecipientUpdated(oldRecipient, newRecipient)`
- `ActiveStateUpdated(active)`

---

## DecimalQuoter

Simple quoter that adjusts values based on token decimal differences.

**Proxy:** No (stateless utility)

**Key Functions:**
- `valueFor(outToken, inToken, value)` - Calculate output based on decimals

**Calculation:**
```
if inDecimals == outDecimals:
    return value
if inDecimals > outDecimals:
    return value / 10^(inDecimals - outDecimals)
if inDecimals < outDecimals:
    return value * 10^(outDecimals - inDecimals)
```

**Use Case:**
- 1:1 exchange rate adjusted for decimal places
- No price index or exchange rate logic
- Pure decimal conversion

---

## Common Patterns

### Initialization
All proxy-based contracts use `_disableInitializers()` in constructor and `initialize()` function for setup. Only callable once per proxy.

### Ownership
All stateful contracts inherit Solady's `Ownable` for owner-based access control.

### Writer Pattern
`GiftableToken` and `Limiter` support a "writer" role - addresses with specific permissions beyond owner.

### PPM (Parts Per Million)
Fee and allocation percentages use PPM where `1_000_000 = 100%`:
- 10,000 = 1%
- 100,000 = 10%
- 500,000 = 50%

### Seal Pattern
`SwapPool` uses progressive sealing to lock configuration during initialization phases.
