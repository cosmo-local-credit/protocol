# Contract Specifications

This document provides technical specifications for all Sarafu Network Protocol smart contracts.

## Table of Contents

- [GiftableToken](#giftabletoken)
- [SwapPool](#swappool)
- [Splitter](#splitter)
- [FeePolicy](#feepolicy)
- [Limiter](#limiter)
- [RelativeQuoter](#relativequoter)
- [OracleQuoter](#oraclequoter)
- [ProtocolFeeController](#protocolfeecontroller)
- [DecimalQuoter](#decimalquoter)
- [EthFaucet](#ethfaucet)
- [PeriodSimple](#periodsimple)
- [CAT](#cat)
- [TokenUniqueSymbolIndex](#tokenuniquesymbolindex)
- [ContractRegistry](#contractregistry)
- [AccountsIndex](#accountsindex)

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
- `withdraw(tokenOut, tokenIn, value)` - Execute token swap (deposit `tokenIn`, receive `tokenOut`)
- `withdraw(tokenOut)` - Withdraw accumulated owner fees for a token (owner only)
- `seal(state)` - Lock pool configuration at initialization stage
- `setFeePolicy(address)` - Update fee policy (owner only)
- `setQuoter(address)` - Update quoter (owner only)
- `getQuote(tokenOut, tokenIn, value)` - Get quoted output before fees
- `getAmountOut(tokenOut, tokenIn, amountIn)` - Get net output after fees
- `getAmountIn(tokenOut, tokenIn, amountOut)` - Get required input for desired output

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
- `Swap(initiator, tokenIn, tokenOut, inValue, outValue, fee)`
- `Collect(feeAddress, token, value)`

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
- `calculateFee(tokenIn, tokenOut, amount)` - Calculate fee amount for an input amount
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

## OracleQuoter

Price quoter using Chainlink oracles for exchange rates.

**Proxy:** Yes (ERC1967)

**Storage:**
- `oracles` - Mapping of token => Chainlink aggregator address
- `baseCurrency` - Base currency address for price references

**Constants:**
- None (normalizes token decimals and oracle decimals)

**Key Functions:**
- `initialize(owner, baseCurrency)` - Set owner and base currency
- `setOracle(token, oracleAddress)` - Set Chainlink oracle for token (owner only)
- `removeOracle(token)` - Remove oracle mapping (owner only)
- `valueFor(outToken, inToken, value)` - Calculate output using oracle rates

**`baseCurrency` in `initialize` (metadata):**
- `baseCurrency` is metadata, not a direct pricing input in `valueFor`.
- Must be a non-zero **token** address or initialization reverts with `InvalidBaseCurrency()`.
- Stored in `baseCurrency` and emitted in `Initialized(owner, baseCurrency)`.

It is only a metadata reference that helps pool operators and integrators understand expected accounting context. Set `baseCurrency` to the settlement/accounting token your pool treats as primary (for example `cUSD` or `USDT` or `cKES`).

**Calculation:**
```
outValue = value
    * inRate / outRate
    * 10^outTokenDecimals / 10^inTokenDecimals
    * 10^outOracleDecimals / 10^inOracleDecimals
```

Where:
- `inRate`, `inOracleDecimals` come from input token's Chainlink feed
- `outRate`, `outOracleDecimals` come from output token's Chainlink feed
- Feed decimals can differ (e.g. `KES / USD` uses 18 decimals on Celo, while many USD feeds use 8)

**Validation:**
- Oracle must be configured for both input and output tokens
- Oracle calls must succeed
- Oracle must return positive price (> 0)
- No fallback to default rates - reverts on missing or invalid oracles
- Supports tokens with any decimal precision (6, 8, 12, 18, etc.)

**Operator Setup Example (Celo):**

Goal: support swaps between
- `MBUNI` (pegged to 1 KES)
- `USDT`
- `cUSD`
- `SANTOS` (pegged to 1 BRL)

Map each token to a Chainlink feed in the same quote denomination (`/USD`):
- `MBUNI -> KES / USD` feed: `0x0826492a24b1dBd1d8fcB4701b38C557CE685e9D`
- `USDT -> USDT / USD` feed: `0x5e37AF40A7A344ec9b03CCD34a250F3dA9a20B02`
- `cUSD -> CUSD / USD` feed: `0xe38A27BE4E7d866327e09736F3C570F256FFd048`
- `SANTOS -> BRL / USD` feed: `0xe8EcaF727080968Ed5F6DBB595B91e50eEb9F8B3`

With this setup, the quoter can price all of the following directly:
- `KES -> cUSD` (MBUNI to cUSD)
- `BRL -> KES` (SANTOS to MBUNI)
- `KES -> KES` (between two different KES-pegged tokens)
- `USDT -> cUSD`

Implementation note:
- Use one feed per token peg/asset and keep all feeds in the same quote currency family (e.g. all `/USD`).
- If a token has no oracle mapping, `valueFor` reverts with `OracleNotSet(token)`.

**Events:**
- `Initialized(owner, baseCurrency)`
- `OracleUpdated(token, oracle)`
- `OracleRemoved(token)`

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
- `setActive(active)` - Enable/disable protocol fees (owner only)

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
`GiftableToken`, `Limiter`, and `CAT` support a "writer" role - addresses with specific permissions beyond owner.

### PPM (Parts Per Million)
Fee and allocation percentages use PPM where `1_000_000 = 100%`:
- 10,000 = 1%
- 100,000 = 10%
- 500,000 = 50%

### Seal Pattern
`SwapPool` uses progressive sealing to lock configuration during initialization phases.

---

## EthFaucet

ETH faucet that distributes tokens with configurable period limits and registry-based access control.

**Proxy:** Yes (ERC1967)

**Storage:**
- `registry` - Optional ACL contract for recipient whitelisting
- `periodChecker` - Contract that enforces time limits between uses
- `amount` - ETH amount distributed per faucet use
- `sealState` - Seal state (0-7) for progressive locking

**Constants:**
- `maxSealState = 7`
- `token = address(0)` (always ETH)

**Seal States:**
- `REGISTRY_STATE = 1` - Lock registry configuration
- `PERIODCHECKER_STATE = 2` - Lock period checker configuration
- `VALUE_STATE = 4` - Lock faucet amount

**Key Functions:**
- `gimme()` - Request ETH for caller
- `giveTo(recipient)` - Request ETH for another address
- `check(recipient)` - Check if recipient can receive ETH
- `setAmount(value)` - Set faucet amount (owner only, requires VALUE_STATE unsealed)
- `setRegistry(registry)` - Set ACL contract (owner only, requires REGISTRY_STATE unsealed)
- `setPeriodChecker(checker)` - Set period checker (owner only, requires PERIODCHECKER_STATE unsealed)
- `seal(state)` - Lock configuration (owner only)
- `nextTime(subject)` - Get next allowed time for recipient
- `tokenAmount()` - Get current faucet amount

**Validation:**
- Contract must have sufficient ETH balance
- Recipient must pass ACL check (if registry set)
- Recipient must pass period check (if periodChecker set)
- Cannot modify sealed configurations

**Period Checker Interface:**
- `have(address)` - Returns true if recipient can use faucet
- `poke(address)` - Record faucet usage and return success
- `next(address)` - Get next allowed timestamp for recipient
- `balanceThreshold()` - Optional balance threshold check

**Registry Interface:**
- `have(address)` - Returns true if address is whitelisted

**Events:**
- `Give(recipient, token, amount)` - Emitted on successful faucet use
- `FaucetAmountChange(amount)` - Emitted when amount changes
- `SealStateChange(sealState, registry, periodChecker)` - Emitted on state change

---

## PeriodSimple

Simple period checker that enforces time limits and optional balance thresholds.

**Proxy:** Yes (ERC1967)

**Storage:**
- `poker` - Address allowed to record faucet usage
- `period` - Minimum time between uses (in seconds)
- `balanceThreshold` - Maximum allowed balance for eligibility
- `lastUsed` - Mapping of address => last usage timestamp

**Key Functions:**
- `setPeriod(period)` - Set time between uses (owner only)
- `setPoker(poker)` - Set allowed poker address (owner only)
- `setBalanceThreshold(threshold)` - Set balance threshold (owner only)
- `have(subject)` - Check if subject is eligible to use faucet
- `poke(subject)` - Record faucet usage
- `next(subject)` - Get next allowed timestamp for subject

**Eligibility Logic:**
- Always eligible if `lastUsed[subject] == 0` (first use)
- Eligible if `block.timestamp > lastUsed[subject] + period`
- Ineligible if `balanceThreshold > 0` and `subject.balance >= balanceThreshold`

**Validation:**
- Only owner or poker can call `poke()`
- Owner can modify all settings

**Events:**
- `PeriodChange(value)` - Emitted when period changes
- `BalanceThresholdChange(value)` - Emitted when threshold changes

---

## CAT

Counterparty Active Token (CAT) — on-chain registry where accounts declare ERC20 settlement token preferences in order of priority. The same account list can be used whether that account acts as sender or receiver, since both are counterparties in a transfer.

**Proxy:** Yes (ERC1967)

**Storage:**
- `_tokens` - Mapping of account => ordered token address list (index 0 = most preferred)
- `writers` - Addresses authorized to set tokens on behalf of others

**Constants:**
- `MAX_TOKENS = 5` - Maximum tokens per account

**Key Functions:**
- `initialize(owner)` - Set owner
- `setTokens(tokens)` - Set caller's own preference list
- `setTokensFor(account, tokens)` - Set tokens for another account (owner or writer only)
- `getTokens(account)` - Get full ordered token list
- `tokenAt(account, index)` - Get token at specific preference index
- `tokenCount(account)` - Get number of configured preferred tokens
- `addWriter(address)` - Grant writer permission (owner only)
- `deleteWriter(address)` - Revoke writer permission (owner only)
- `isWriter(address)` - Check if address is writer

**Update Behavior:**
- `setTokens` is a full replace (not upsert). Every call overwrites the entire previous list with the new one. There is no append, remove-single, or merge — the caller always provides the complete desired list. To add a token, read the current list off-chain, append, and submit the new full list. To remove one, submit the list without it.

**Validation:**
- Token list must not be empty
- Token list must not exceed `MAX_TOKENS` (5)
- No zero addresses in the list
- Only owner or writers can call `setTokensFor`

**Events:**
- `TokensSet(account, tokens)` - Emitted on every update
- `WriterAdded(writer)`
- `WriterRemoved(writer)`

---

## TokenUniqueSymbolIndex

Token registry indexed by unique ERC20 symbol.

**Proxy:** Yes (ERC1967)

**Storage:**
- `tokens` - Array of registered token addresses
- `identifierList` - Array of symbol keys (bytes32)
- `registry` - Mapping of symbol key => token index
- `tokenIndex` - Mapping of token address => symbol key
- `isWriter` - Addresses authorized to register tokens

**Key Functions:**
- `initialize(owner, initialTokens, initialSymbols)` - Set owner and pre-register tokens
- `register(token)` - Register a token by reading its symbol (owner or writer only)
- `add(token)` - Alias for register
- `remove(token)` - Remove a token from registry (owner or writer only)
- `addressOf(key)` - Get token address by symbol key
- `entry(idx)` - Get token address by index
- `entryCount()` - Get number of registered tokens
- `identifier(idx)` - Get symbol key by index
- `identifierCount()` - Get number of identifiers
- `have(token)` - Check if token is registered
- `addWriter(writer)` - Grant writer permission (owner only)
- `deleteWriter(writer)` - Revoke writer permission (owner only)

**Registration Logic:**
- Calls `symbol()` on token contract to get symbol
- Converts symbol to bytes32 (padded or truncated to 32 bytes)
- Rejects if symbol length > 32
- Rejects if symbol already exists
- Adds token to registry with its symbol as key

**Removal Logic:**
- Swaps removed element with last element to maintain array compactness
- Updates all related mappings and arrays
- Clears token index mapping

**Time Function:**
- Always returns 0 (compatibility with AccountsIndex interface)

**Validation:**
- Only owner or writers can register/remove tokens
- Symbol must be <= 32 bytes
- Cannot register duplicate symbols
- Cannot remove non-existent tokens

**Events:**
- `AddressKey(symbol, token)` - Emitted when token is registered
- `AddressAdded(token)` - Emitted when token is added
- `AddressRemoved(token)` - Emitted when token is removed
- `WriterAdded(writer)` - Emitted when writer is added
- `WriterDeleted(writer)` - Emitted when writer is removed

---

## ContractRegistry

Keyed smart contract registry for storing contract addresses by identifiers.

**Proxy:** Yes (ERC1967)

**Storage:**
- `entries` - Mapping of identifier bytes32 => contract address
- `identifier` - Array of allowed identifiers

**Key Functions:**
- `initialize(owner, identifiers)` - Set owner and initialize allowed identifiers
- `set(identifier, address)` - Register a contract address for an identifier (owner only)
- `addressOf(identifier)` - Get contract address by identifier
- `identifier(idx)` - Get identifier at index
- `identifierCount()` - Get number of allowed identifiers

**Identifier Logic:**
- Identifiers are pre-defined during initialization
- Only pre-defined identifiers can be used to set addresses
- Each identifier can only be set once (cannot be overwritten)
- Cannot set address(0) as a contract address

**Validation:**
- Only owner can set addresses
- Address must not be zero
- Identifier must exist in allowed list
- Address must not already be set for that identifier

**Events:**
- `AddressKey(identifier, address)` - Emitted when address is set

---

## AccountsIndex

Index of Ethereum addresses with support for activation/deactivation and timestamping.

**Proxy:** Yes (ERC1967)

**Storage:**
- `entryList` - Array of indexed addresses
- `entryIndex` - Mapping of address => packed entry data (index | timestamp | blocked flag)
- `writers` - Addresses authorized to manage the index

**Constants:**
- `BLOCKED_FIELD = 1 << 128` - Bit flag for blocked/deactivated state

**Key Functions:**
- `initialize(owner)` - Set owner
- `add(account)` - Add address to index (owner or writer only)
- `remove(account)` - Remove address from index (owner or writer only)
- `activate(account)` - Activate a blocked address (owner or writer only)
- `deactivate(account)` - Deactivate/ban an address (owner or writer only)
- `entry(idx)` - Get address at index
- `entryCount()` - Get number of entries
- `time(account)` - Get timestamp when account was added
- `have(account)` - Check if account exists in index
- `isActive(account)` - Check if account exists and is active
- `addWriter(writer)` - Grant writer permission (owner only)
- `deleteWriter(writer)` - Revoke writer permission (owner only)
- `isWriter(writer)` - Check if address is writer

**Entry Data Structure:**
Each `entryIndex[address]` contains packed data:
- Bits 0-63: Index in entryList array (uint64)
- Bits 64-127: Timestamp of addition (block.timestamp << 64)
- Bit 128+: Blocked flag (BLOCKED_FIELD = 1 << 128)

**Activation States:**
- Active: `entryIndex[address] & BLOCKED_FIELD != BLOCKED_FIELD`
- Blocked/Deactivated: `entryIndex[address] & BLOCKED_FIELD == BLOCKED_FIELD`

**Activation Logic:**
- `activate()`: Shifts entry right by 129 bits, removing blocked flag
- `deactivate()`: Shifts entry left by 129 bits and adds blocked flag
- Cannot activate an already active account
- Cannot deactivate an already blocked account

**Removal Logic:**
- Swaps removed element with last element to maintain array compactness
- Does not preserve ordering of remaining elements

**Constraints:**
- Maximum 2^64 entries (index limited to uint64)
- Each address can only be added once

**Validation:**
- Only owner or writers can add/remove/activate/deactivate
- Cannot add duplicate addresses
- Cannot remove non-existent addresses
- Cannot activate/deactivate non-existent addresses

**Events:**
- `AddressAdded(account)` - Emitted when address is added
- `AddressRemoved(account)` - Emitted when address is removed
- `AddressActive(account, active)` - Emitted when activation state changes
- `WriterAdded(writer)` - Emitted when writer is added
- `WriterDeleted(writer)` - Emitted when writer is removed
