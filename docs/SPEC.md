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

ERC20 token with minting, optional expiry, and writer permissions.

**Proxy:** Yes (ERC1967)

**Key Functions:**
- `initialize(name, symbol, decimals, owner, expiresAt)` — `expiresAt = 0` means no expiry
- `mintTo(to, amount)` — mint tokens (owner or writer only)
- `burn(amount)` — burn from owner's own balance (owner only)
- `applyExpiry()` — trigger expiry check; callable by anyone; no-op if `expiresAt == 0`
- `addWriter(address)` / `deleteWriter(address)` / `isWriter(address)` — manage minters (owner only to add/remove)

**Behaviour:**
- All transfers (including mint) revert with `TokenExpired` once the token is expired
- Expiry is triggered automatically on the first transfer after `block.timestamp >= expiresAt`, or explicitly via `applyExpiry()`
- `expired` and `totalMinted` / `totalBurned` are public state variables

**Events:**
- `Mint(minter, beneficiary, value)`
- `Burn(from, value)`
- `Expired(timestamp)`
- `WriterAdded(writer)` / `WriterRemoved(writer)`

---

## SwapPool

Automated Market Maker (AMM) for token swaps with configurable fees, limits, and quoters.

**Proxy:** Yes (ERC1967)

**Storage:**
- `tokenRegistry` - Optional registry for token whitelist
- `tokenLimiter` - Contract that defines per-token deposit limits
- `quoter` - Price quoter for swap calculations
- `feeAddress` - Recipient of accumulated pool fees
- `feePolicy` - Contract that determines swap fees
- `protocolFeeController` - Protocol-level fee controller
- `feesDecoupled` - Whether accumulated fees are excluded from available liquidity
- `fees` - Mapping of accumulated pool fees per token
- Token metadata (name, symbol, decimals) for pool's LP token representation
- `sealState` - Bitmask tracking which configuration fields are permanently locked

**Constants:**
- `PPM = 1_000_000` (100%)
- `DEFAULT_FEE_PPM = 10_000` (1%) — floor used in protocol fee calculation

**Key Functions:**

_Liquidity:_
- `initialize(name, symbol, decimals, owner, feePolicy, feeAddress, tokenRegistry, tokenLimiter, quoter, feesDecoupled, protocolFeeController)` - Initialize pool
- `deposit(token, value)` - Add liquidity (transfers `value` of `token` from caller into pool)
- `withdrawLiquidity(token, to, amount)` - Owner emergency withdrawal of pool liquidity (owner only)

_Swapping:_
- `withdraw(tokenOut, tokenIn, value)` - Swap `value` of `tokenIn` for `tokenOut`, output sent to `msg.sender`
- `withdraw(tokenOut, tokenIn, value, recipient)` - Same swap but output sent to `recipient` instead of caller; reverts with `InvalidRecipient` if `recipient` is zero address

_Fee collection (owner only):_
- `withdraw(tokenOut)` - Withdraw all accumulated pool fees for `tokenOut` to `feeAddress`
- `withdraw(tokenOut, value)` - Withdraw a specific `value` of accumulated pool fees for `tokenOut` to `feeAddress`

_Configuration (owner only):_
- `seal(state)` - Permanently lock one or more configuration fields (bitmask)
- `setFeePolicy(address)` - Update fee policy; reverts if `FEE_STATE` is sealed
- `setFeeAddress(address)` - Update fee recipient; reverts if `FEEADDRESS_STATE` is sealed
- `setQuoter(address)` - Update quoter; reverts if `QUOTER_STATE` is sealed
- `setTokenRegistry(address)` - Update token registry (no seal restriction)
- `setTokenLimiter(address)` - Update token limiter (no seal restriction)

_Queries:_
- `isSealed(state)` - Returns true if the given seal bitmask is fully set; pass `0` to check if fully sealed
- `getQuote(tokenOut, tokenIn, value)` - Get raw quoted output from quoter before any fees
- `getFee(inToken, outToken, value)` - Get pool fee amount for a given quoted value
- `getAmountOut(tokenOut, tokenIn, amountIn)` - Get net output amount after pool fee (does not include protocol fee)
- `getAmountIn(tokenOut, tokenIn, amountOut)` - Get required input amount to receive a desired net output

**Seal States:**

Seal is a bitmask; each bit permanently locks one configuration field. Once set, a bit cannot be cleared.

| Constant | Value | Locks |
|---|---|---|
| `FEE_STATE` | 1 | `feePolicy` (via `setFeePolicy`) |
| `FEEADDRESS_STATE` | 2 | `feeAddress` (via `setFeeAddress`) |
| `QUOTER_STATE` | 4 | `quoter` (via `setQuoter`) |
| `maxSealState` | 7 | All three fields — fully sealed |

**Swap Mechanics:**

For `withdraw(tokenOut, tokenIn, value[, recipient])`:

1. Caller's `tokenIn` is deposited into the pool (registry and limiter checks apply)
2. A raw quote is obtained: `quotedValue = quoter.valueFor(tokenOut, tokenIn, value)` (defaults to `value` if no quoter)
3. Pool fee is calculated: `totalFee = quotedValue * feePpm / PPM`
4. Protocol fee is calculated (see below)
5. Net amount transferred to recipient: `netValue = quotedValue - totalFee - protocolFee`
6. Accumulated pool fee is recorded in `fees[tokenOut]` (if `feeAddress != address(0)`)
7. `Swap` event is emitted with `msg.sender` as `initiator` regardless of recipient

**Protocol Fee:**

Charged on top of the pool fee — both reduce the user's output. The pool owner always receives their full `totalFee`.

- Calculated as: `protocolFee = effectiveFee * protocolFeePpm / PPM`
- `effectiveFee = max(totalFee, assumedFee)` where `assumedFee = quotedValue * DEFAULT_FEE_PPM / PPM` (1% floor)
- The floor prevents pool operators from setting a tiny fee to minimise the protocol's cut
- Protocol fee is skipped if `protocolFeeController` is zero, `protocolFeePpm` is zero, or `protocolFeeRecipient` is zero

**Fee Modes:**

- `feesDecoupled = false` (default): accumulated fees remain in the pool balance and count as liquidity
- `feesDecoupled = true`: accumulated fees are tracked separately; available liquidity = `balance - fees[token]`; the `InsufficientBalance` check uses this reduced figure

**Validation:**
- Token must pass registry `have(token)` check (if `tokenRegistry` is set)
- Deposit must not push pool balance above limiter limit (if `tokenLimiter` is set)
- Pool must hold sufficient `tokenOut` to cover `quotedValue`
- `feeAddress` must be non-zero to collect fees (`withdraw(tokenOut)` / `withdraw(tokenOut, value)`)
- `recipient` must be non-zero for the 4-argument `withdraw` overload

**Errors:**
- `InvalidRecipient` - `recipient` argument is `address(0)`
- `InvalidFeeAddress` - `feeAddress` is `address(0)` when collecting fees
- `InsufficientBalance` - Pool lacks sufficient `tokenOut` liquidity
- `InsufficientFees` - Accumulated fees are zero or less than requested
- `UnauthorizedToken` - Token not whitelisted in `tokenRegistry`
- `LimitExceeded` - Deposit would exceed the limiter limit
- `Sealed` - Attempted to modify a sealed configuration field
- `AlreadyLocked` - Seal bit already set

**Events:**
- `Deposit(initiator, tokenIn, amountIn)` - Emitted on explicit `deposit()` call
- `Swap(initiator, tokenIn, tokenOut, amountIn, amountOut, fee)` - Emitted on every swap; `initiator` is always `msg.sender`; `fee` is the pool fee (not protocol fee)
- `Collect(feeAddress, tokenOut, amountOut)` - Emitted when owner withdraws accumulated fees
- `SealStateChange(final, sealState)` - Emitted on each `seal()` call; `final` is true when `sealState == maxSealState`

---

## Splitter

Distributes ETH and ERC20 token balances among a fixed set of recipients.

**Proxy:** Yes (ERC1967)

**Key Functions:**
- `initialize(owner, accounts, percentAllocations)` — set recipients and shares
- `updateSplit(accounts, percentAllocations)` — replace recipients/shares (owner only)
- `distributeETH(accounts, percentAllocations)` — distribute contract's ETH balance
- `distributeERC20(token, accounts, percentAllocations)` — distribute contract's ERC20 balance
- `getHash()` — returns `keccak256(abi.encodePacked(accounts, percentAllocations))`

**Important:**
- The contract accepts ETH via `receive()`; send tokens/ETH to the contract, then call distribute
- Callers of `distributeETH`/`distributeERC20` must pass the **exact same** accounts and allocations arrays used in `initialize`/`updateSplit` — the call reverts with `InvalidHash` otherwise
- Allocations use PPM (`1_000_000 = 100%`); must sum exactly to `1_000_000`
- At least 2 recipients; no duplicates; no zero allocations
- Rounding remainder goes to the **last** recipient in the array
- Empty balance is a no-op (no revert)

---

## FeePolicy

Per-pair or default swap fee configuration consumed by SwapPool.

**Proxy:** Yes (ERC1967)

**Key Functions:**
- `initialize(owner, defaultFee)` — fee in PPM (`1_000_000 = 100%`)
- `getFee(tokenIn, tokenOut)` — returns pair-specific fee if set, otherwise `defaultFee`
- `calculateFee(tokenIn, tokenOut, amount)` — convenience: returns `amount * fee / PPM`
- `setDefaultFee(fee)` — owner only; fee must be ≤ PPM
- `setPairFee(tokenIn, tokenOut, fee)` — owner only; direction-sensitive (`A→B ≠ B→A`)
- `removePairFee(tokenIn, tokenOut)` — owner only; reverts to default for that pair

**Events:**
- `DefaultFeeUpdated(oldFee, newFee)`
- `PairFeeUpdated(tokenIn, tokenOut, oldFee, newFee)`
- `PairFeeRemoved(tokenIn, tokenOut)`

---

## Limiter

Per-token, per-holder maximum balance limits enforced by SwapPool on deposit.

**Proxy:** Yes (ERC1967)

**Key Functions:**
- `initialize(owner)` — set owner
- `limitOf(token, holder)` — returns the limit; `0` means no limit has been set (SwapPool treats 0 as blocked — all deposits rejected)
- `setLimitFor(token, holder, value)` — set limit (owner or writer only); `holder` must be a **deployed contract** (EOAs are rejected)
- `addWriter(address)` / `deleteWriter(address)` / `isWriter(address)` — manage writers (owner only to add/remove)

**Events:**
- `LimitSet(token, holder, value)`
- `WriterAdded(writer)` / `WriterRemoved(writer)`

---

## RelativeQuoter

Price quoter using configurable per-token exchange rates relative to a common unit.

**Proxy:** Yes (ERC1967)

**Key Functions:**
- `initialize(owner)` — set owner
- `setPriceIndexValue(token, exchangeRate)` — set exchange rate in PPM (owner only); unset tokens default to `PPM = 1_000_000`
- `valueFor(outToken, inToken, value)` — calculate output for a swap

**Calculation:**

Adjusts for decimal differences between tokens, then applies exchange rates:
```
outValue = adjustedValue * inExchangeRate / outExchangeRate
```
where `adjustedValue = value / 10^(inDecimals-outDecimals)` if `inDecimals > outDecimals`, or `value * 10^(outDecimals-inDecimals)` if `outDecimals > inDecimals`.

Tokens with no rate set trade at `PPM` (i.e. rate = 1.0 in PPM terms). Two tokens both at default rate trade 1:1 (decimal-adjusted).

**Events:**
- `PriceIndexUpdated(tokenAddress, exchangeRate)`

---

## OracleQuoter

Price quoter using Chainlink oracle feeds.

**Proxy:** Yes (ERC1967)

**Key Functions:**
- `initialize(owner, baseCurrency)` — `baseCurrency` must be non-zero; it is metadata only (does not affect pricing), used to communicate the common quote denomination to operators
- `setOracle(token, oracleAddress)` — map a token to its Chainlink `AggregatorV3` feed (owner only)
- `removeOracle(token)` — remove a token's oracle mapping (owner only)
- `setMaxStaleness(seconds)` — set maximum age of oracle price before rejecting (default: 86400 = 1 day, owner only)
- `setMultiplier(multiplier)` — adjust quoted rates by a factor in PPM (owner only); range `900_000` (0.9x) to `1_100_000` (1.1x); unset (`0`) or `1_000_000` means no adjustment
- `valueFor(outToken, inToken, value)` — calculate output using live oracle prices, then apply the rate multiplier

**Calculation:**
```
rawOutput = value * inRate * 10^outTokenDecimals * 10^outOracleDecimals
             / (outRate * 10^inTokenDecimals * 10^inOracleDecimals)
outValue = rawOutput * effectiveMultiplier / 1_000_000
```
where `effectiveMultiplier` is `multiplier` if set, otherwise `1_000_000` (1x — no adjustment).

All four decimal adjustments are applied so feeds with different precisions (e.g. 8-decimal USD feeds vs 18-decimal Celo feeds) compose correctly.

**Constraints:**
- Both tokens must have oracles configured; reverts with `OracleNotSet(token)` otherwise
- Price must be > 0 (`InvalidOraclePrice`) and within `maxStaleness` (`StaleOraclePrice`)
- No fallback rates — reverts on any missing or failed oracle call

**Setup guide:**

Map each token to a Chainlink feed in the **same quote denomination** (e.g. all `/USD`). The quoter cross-rates any two tokens through that shared denominator — you do not need a direct feed for every pair.

Example: a pool supporting `MBUNI` (KES-pegged), `USDT`, `cUSD`, and `SANTOS` (BRL-pegged) on Celo:

| Token | Feed | Feed address |
|---|---|---|
| `MBUNI` | `KES / USD` | `0x0826492a24b1dBd1d8fcB4701b38C557CE685e9D` |
| `USDT` | `USDT / USD` | `0x5e37AF40A7A344ec9b03CCD34a250F3dA9a20B02` |
| `cUSD` | `CUSD / USD` | `0xe38A27BE4E7d866327e09736F3C570F256FFd048` |
| `SANTOS` | `BRL / USD` | `0xe8EcaF727080968Ed5F6DBB595B91e50eEb9F8B3` |

With this mapping the quoter can price any combination: `KES → cUSD`, `BRL → KES`, `KES → KES` (two different KES-pegged tokens, 1:1), `USDT → cUSD`, etc.

Set `baseCurrency` to the settlement token your pool treats as primary (e.g. `cUSD`). This is stored as metadata and emitted in the `Initialized` event — it does not affect `valueFor` pricing.

**Events:**
- `Initialized(owner, baseCurrency)`
- `OracleUpdated(token, oracle)`
- `OracleRemoved(token)`
- `MaxStalenessUpdated(maxStaleness)`
- `MultiplierUpdated(oldMultiplier, newMultiplier)`

**Backward Compatibility:** Existing proxies upgraded in-place will read `multiplier` as `0` from uninitialized storage — the code treats `0` as `1_000_000` (1x), preserving current behavior with no migration needed.

---

## ProtocolFeeController

Protocol-level fee configuration consumed by SwapPool. See [SwapPool — Protocol Fee](#swappool) for how the fee is applied.

**Proxy:** Yes (ERC1967)

**Key Functions:**
- `initialize(owner, initialFee, initialRecipient)` — fee in PPM; recipient must be non-zero; starts **active**
- `getProtocolFee()` — returns fee in PPM, or `0` if inactive
- `getProtocolFeeRecipient()` — returns recipient address
- `setProtocolFee(fee)` — owner only; fee must be ≤ PPM
- `setProtocolFeeRecipient(recipient)` — owner only; recipient must be non-zero
- `setActive(bool)` — owner only; disabling sets `getProtocolFee()` to return `0`

**Events:**
- `ProtocolFeeUpdated(oldFee, newFee)`
- `ProtocolFeeRecipientUpdated(oldRecipient, newRecipient)`
- `ActiveStateUpdated(active)`

---

## DecimalQuoter

Stateless quoter that normalises a token amount across different decimal precisions. No exchange rate — assumes 1:1 value parity between tokens.

**Proxy:** No (stateless, deploy once)

**Key Functions:**
- `valueFor(outToken, inToken, value)` — scales `value` from `inToken` decimals to `outToken` decimals

**Use case:** pools where tokens have the same real-world value but different decimal representations (e.g. 6-decimal vs 18-decimal stablecoins).

---

## EthFaucet

ETH faucet with optional whitelist and cooldown enforcement.

**Proxy:** Yes (ERC1967)

**Key Functions:**
- `initialize(owner, amount)` — set owner and ETH amount per claim
- `gimme()` — claim ETH for caller
- `giveTo(recipient)` — claim ETH for another address
- `check(recipient)` — returns true if recipient can currently claim (does not poke)
- `nextTime(subject)` — returns the timestamp when `subject` can next claim (requires `periodChecker`)
- `setAmount(value)` — update claim amount (owner only; reverts if `VALUE_STATE` sealed)
- `setRegistry(address)` — set whitelist contract (owner only; reverts if `REGISTRY_STATE` sealed)
- `setPeriodChecker(address)` — set cooldown contract (owner only; reverts if `PERIODCHECKER_STATE` sealed)
- `seal(state)` — permanently lock configuration fields (owner only)

**Seal state bitmask:** `REGISTRY_STATE=1`, `PERIODCHECKER_STATE=2`, `VALUE_STATE=4`, `maxSealState=7`

**External interfaces expected:**
- `registry.have(address) → bool` — whitelist check
- `periodChecker.have(address) → bool` — cooldown check
- `periodChecker.poke(address) → bool` — record usage
- `periodChecker.next(address) → uint256` — next allowed timestamp

**Events:**
- `Give(recipient, token, amount)` — `token` is always `address(0)` (ETH)
- `FaucetAmountChange(amount)`
- `SealStateChange(sealState, registry, periodChecker)`

---

## PeriodSimple

Cooldown checker used by EthFaucet to enforce time limits between claims.

**Proxy:** Yes (ERC1967)

**Key Functions:**
- `initialize(owner, poker)` — set owner and initial poker address
- `have(subject) → bool` — returns true if `subject` is eligible: first-time users always eligible; otherwise `block.timestamp > lastUsed + period`; ineligible if `balanceThreshold > 0` and `subject.balance >= balanceThreshold`
- `poke(subject) → bool` — record usage (`lastUsed[subject] = block.timestamp`); returns false if not eligible; callable by owner or `poker`
- `next(subject) → uint256` — returns `lastUsed[subject] + period`
- `setPeriod(seconds)` / `setPoker(address)` / `setBalanceThreshold(amount)` — owner only

**Events:**
- `PeriodChange(value)`
- `BalanceThresholdChange(value)`

---

## CAT

On-chain registry where accounts declare their preferred ERC20 settlement tokens in priority order.

**Proxy:** Yes (ERC1967)

**Key Functions:**
- `initialize(owner)` — set owner
- `setTokens(tokens[])` — set caller's own preference list (1–5 tokens, no zero addresses)
- `setTokensFor(account, tokens[])` — set on behalf of another account (owner or writer only)
- `getTokens(account) → address[]` — full ordered list (index 0 = most preferred)
- `tokenAt(account, index)` / `tokenCount(account)` — individual access
- `addWriter(address)` / `deleteWriter(address)` / `isWriter(address)` — manage writers (owner only to add/remove)

**Important:** `setTokens` is a **full replace** — always submit the complete desired list. Max 5 tokens per account.

**Events:**
- `TokensSet(account, tokens)`
- `WriterAdded(writer)` / `WriterRemoved(writer)`

---

## TokenUniqueSymbolIndex

Token registry indexed by unique ERC20 symbol. Used as a SwapPool `tokenRegistry`.

**Proxy:** Yes (ERC1967)

**Key Functions:**
- `initialize(owner, initialTokens[], initialSymbols[])` — pre-register tokens with explicit symbols (arrays must be same length)
- `register(token)` / `add(token)` — read `symbol()` from token and register; symbol must be ≤ 32 bytes; duplicates rejected (owner or writer only)
- `remove(token)` — deregister a token (owner or writer only)
- `have(token) → bool` — check if registered (called by SwapPool)
- `addressOf(symbolKey) → address` — look up by bytes32 symbol key
- `entry(idx) → address` / `entryCount()` — enumerate registered tokens (0-based)
- `addWriter(address)` / `deleteWriter(address)` — manage writers (owner only)

**Events:**
- `AddressKey(symbol, token)` / `AddressAdded(token)` / `AddressRemoved(token)`
- `WriterAdded(writer)` / `WriterDeleted(writer)`

---

## ContractRegistry

Write-once key→address registry. Identifiers are fixed at deploy time; each can only be set once.

**Proxy:** Yes (ERC1967)

**Key Functions:**
- `initialize(owner, identifiers[])` — set owner and the allowed bytes32 identifier keys
- `set(identifier, address)` — assign an address to an identifier (owner only); reverts if identifier unknown, address is zero, or already set
- `addressOf(identifier) → address` — returns `address(0)` if not yet set
- `identifierCount()` — number of allowed identifiers
- `identifier(idx)` — get identifier by index (public array getter)

**Events:**
- `AddressKey(identifier, address)`

---

## AccountsIndex

Enumerable address registry with activation/deactivation and addition timestamps.

**Proxy:** Yes (ERC1967)

**Key Functions:**
- `initialize(owner)` — set owner
- `add(account)` — add address (owner or writer only); reverts if already present
- `remove(account)` — remove address (owner or writer only); does not preserve ordering
- `activate(account)` / `deactivate(account)` — toggle active state (owner or writer only)
- `have(account) → bool` — check if address is in the index
- `isActive(account) → bool` — check if present and not deactivated
- `time(account) → uint256` — block timestamp when account was added
- `entry(idx) → address` / `entryCount()` — enumerate entries (0-based)
- `addWriter(address)` / `deleteWriter(address)` / `isWriter(address)` — manage writers (owner only to add/remove)

**Events:**
- `AddressAdded(account)` / `AddressRemoved(account)`
- `AddressActive(account, active)` — emitted on activate/deactivate
- `WriterAdded(writer)` / `WriterDeleted(writer)`

---

## Common Patterns

### PPM (Parts Per Million)
Fees and allocations use PPM where `1_000_000 = 100%` (e.g. `10_000 = 1%`, `100_000 = 10%`).

### Writer Role
`GiftableToken`, `Limiter`, `CAT`, `AccountsIndex`, and `TokenUniqueSymbolIndex` support a writer role — addresses granted specific write permissions by the owner without full ownership.

### Proxy & Initialization
All proxied contracts call `initialize()` once at deploy time. Calling `initialize()` again on an existing proxy reverts.
