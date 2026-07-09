# Contract Specifications

Technical reference for every Sarafu Network Protocol smart contract.

Conventions used throughout:

- **PPM (parts per million):** fees and allocations are expressed where `1_000_000 = 100%`. So `10_000 = 1%` and `100_000 = 10%`.
- **Proxy:** "Yes (ERC1967)" means the contract is deployed behind a proxy and configured via `initialize()`. "No" means it is deployed directly with a constructor.
- **Owner / writer:** `owner` has full control. Some contracts also support a `writer` role: addresses the owner grants limited write access without handing over ownership.

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
- [SwapRouter](#swaprouter)
- [EthFaucet](#ethfaucet)
- [PeriodSimple](#periodsimple)
- [CAT](#cat)
- [TokenUniqueSymbolIndex](#tokenuniquesymbolindex)
- [ContractRegistry](#contractregistry)
- [AccountsIndex](#accountsindex)
- [RescueVault](#rescuevault)
- [Common Patterns](#common-patterns)

---

## GiftableToken

ERC20 token with minting, optional expiry, and a writer role for delegated minting.

**Proxy:** Yes (ERC1967)

**Key Functions:**
- `initialize(name, symbol, decimals, owner, expiresAt)`: `expiresAt = 0` means the token never expires.
- `mintTo(to, amount)`: mint tokens. Owner or writer only.
- `burn(amount)`: burn from the caller's own balance. Owner only. Reverts with `InsufficientBalance` if the balance is too low.
- `applyExpiry()`: trigger the expiry check. Callable by anyone. No-op if `expiresAt == 0`.
- `addWriter(address)` / `deleteWriter(address)`: manage minters. Owner only.
- `isWriter(address)`: returns true for writers and for the owner.

**Behaviour:**
- Once expired, every transfer (including mint) reverts with `TokenExpired`.
- Expiry flips automatically on the first transfer at or after `block.timestamp >= expiresAt`, or explicitly via `applyExpiry()`.
- `expired`, `totalMinted`, and `totalBurned` are public state variables.

**Events:**
- `Mint(minter, beneficiary, value)`
- `Burn(from, value)`
- `Expired(timestamp)`
- `WriterAdded(writer)` / `WriterRemoved(writer)`

---

## SwapPool

Automated market maker for token swaps, with configurable fees, deposit limits, and pluggable price quoters. The pool itself is an ERC20-metadata contract (it carries a name, symbol, and decimals for LP representation) but does not mint LP tokens.

**Proxy:** Yes (ERC1967)

**Storage:**
- `tokenRegistry`: optional token whitelist. When unset, any token is allowed.
- `tokenLimiter`: optional per-token deposit cap. When unset, deposits are uncapped.
- `quoter`: price quoter for swap math. When unset, swaps are 1:1.
- `feeAddress`: recipient of collected pool fees.
- `feePolicy`: contract that returns the pool fee rate. When unset, the pool fee is 0.
- `protocolFeeController`: optional protocol-level fee controller.
- `feesDecoupled`: whether collected fees are excluded from available liquidity.
- `fees`: mapping of accumulated pool fees per token.
- `sealState`: bitmask of configuration fields that are permanently locked.

**Constants:**
- `PPM = 1_000_000` (100%).
- `DEFAULT_FEE_PPM = 10_000` (1%): the fee floor used in protocol fee calculation.

**Key Functions**

Liquidity:
- `initialize(name, symbol, decimals, owner, feePolicy, feeAddress, tokenRegistry, tokenLimiter, quoter, feesDecoupled, protocolFeeController)`: one-time setup.
- `deposit(token, value)`: add liquidity. Transfers `value` of `token` from the caller into the pool and emits `Deposit`.
- `withdrawLiquidity(token, to, amount)`: owner-only emergency withdrawal of pool liquidity. Use a timelock or multisig owner.

Swapping:
- `withdraw(tokenOut, tokenIn, value)`: swap `value` of `tokenIn` for `tokenOut`. Output goes to `msg.sender`.
- `withdraw(tokenOut, tokenIn, value, recipient)`: same swap, output goes to `recipient`. Reverts with `InvalidRecipient` if `recipient` is the zero address.

Fee collection (owner only):
- `withdraw(tokenOut)`: send all accumulated pool fees for `tokenOut` to `feeAddress`.
- `withdraw(tokenOut, value)`: send a specific `value` of accumulated pool fees for `tokenOut` to `feeAddress`.

Configuration (owner only):
- `seal(state)`: permanently lock one or more configuration fields (bitmask). Reverts with `AlreadyLocked` if a bit is already set, or `InvalidState` if `state > maxSealState`.
- `setFeePolicy(address)`: reverts with `Sealed` if `FEE_STATE` is sealed.
- `setFeeAddress(address)`: reverts with `Sealed` if `FEEADDRESS_STATE` is sealed.
- `setQuoter(address)`: reverts with `Sealed` if `QUOTER_STATE` is sealed.
- `setTokenRegistry(address)`: no seal restriction.
- `setTokenLimiter(address)`: no seal restriction.

Queries:
- `isSealed(state)`: pass a single seal bit (1, 2, or 4) to check if that field is locked, or pass `0` to check if the pool is fully sealed. Reverts with `InvalidState` if `state >= maxSealState`, so use `0` (not `7`) for the fully-sealed check.
- `getQuote(tokenOut, tokenIn, value)`: raw quoted output from the quoter, before any fees.
- `getFee(inToken, outToken, value)`: pool fee amount for a given quoted value.
- `getAmountOut(tokenOut, tokenIn, amountIn)`: net output after pool fee and protocol fee.
- `getAmountIn(tokenOut, tokenIn, amountOut)`: input required to receive a desired net output. Accounts for pool fee, protocol fee, and the quoter, and adds a +1 wei rounding safety margin.

**Seal States**

Seal is a bitmask. Each bit permanently locks one field. Bits can only be set, never cleared.

| Constant | Value | Locks |
|---|---|---|
| `FEE_STATE` | 1 | `feePolicy` (via `setFeePolicy`) |
| `FEEADDRESS_STATE` | 2 | `feeAddress` (via `setFeeAddress`) |
| `QUOTER_STATE` | 4 | `quoter` (via `setQuoter`) |
| `maxSealState` | 7 | all three fields (fully sealed) |

**Swap Mechanics**

For `withdraw(tokenOut, tokenIn, value[, recipient])`:

1. The caller's `tokenIn` is deposited into the pool. Registry and limiter checks apply, and a `Deposit` event is emitted.
2. A raw quote is taken: `quotedValue = quoter.valueFor(tokenOut, tokenIn, value)`, or `value` if no quoter is set.
3. Pool fee: `totalFee = quotedValue * feePpm / PPM`.
4. Protocol fee is computed (see below).
5. The recipient receives `netValue = quotedValue - totalFee - protocolFee`. The protocol fee, if any, is sent to the protocol recipient in the same call.
6. The pool fee is recorded in `fees[tokenOut]`, but only if `feeAddress != address(0)`.
7. A `Swap` event is emitted with `msg.sender` as `initiator`, regardless of `recipient`.

**Protocol Fee**

The protocol fee is charged on top of the pool fee. Both are deducted from the user's output, and the pool owner always receives the full `totalFee`.

- `protocolFee = effectiveFee * protocolFeePpm / PPM`
- `effectiveFee = max(totalFee, assumedFee)` where `assumedFee = quotedValue * DEFAULT_FEE_PPM / PPM` (the 1% floor).
- The floor stops a pool operator from setting a tiny pool fee just to shrink the protocol's cut.
- The protocol fee is skipped entirely if `protocolFeeController` is unset, `protocolFeePpm` is 0, or the protocol recipient is the zero address.

**Fee Modes**

- `feesDecoupled = false` (default): collected fees stay in the pool balance and count as available liquidity.
- `feesDecoupled = true`: collected fees are tracked separately. Available liquidity for a swap is `balance - fees[token]`, and the `InsufficientBalance` check uses this reduced figure.

**Validation:**
- The token must pass the registry `have(token)` check, if `tokenRegistry` is set.
- A deposit must not push the pool balance above the limiter cap, if `tokenLimiter` is set. Note that a limit of `0` blocks all deposits (see [Limiter](#limiter)).
- The pool must hold enough `tokenOut` to cover `quotedValue`.
- `feeAddress` must be non-zero to collect fees.
- `recipient` must be non-zero for the 4-argument `withdraw`.

**Errors:**
- `InvalidRecipient`: the `recipient` argument is the zero address.
- `InvalidFeeAddress`: `feeAddress` is the zero address when collecting fees.
- `InsufficientBalance`: the pool lacks enough `tokenOut` liquidity.
- `InsufficientFees`: accumulated fees are zero or below the requested amount.
- `UnauthorizedToken`: the token is not whitelisted in `tokenRegistry`.
- `LimitExceeded`: the deposit would exceed the limiter cap.
- `TransferFailed`: an ERC20 transfer returned false.
- `RegistryCallFailed`: the registry `have()` call reverted.
- `Sealed`: attempted to modify a sealed field.
- `AlreadyLocked`: the seal bit is already set.
- `InvalidState`: a seal bitmask argument is out of range.

**Events:**
- `Deposit(initiator, tokenIn, amountIn)`: emitted whenever tokens enter the pool. This fires on an explicit `deposit()` call and also at the start of every swap, because a swap deposits `tokenIn` first. Expect a `Deposit` immediately before each `Swap`.
- `Swap(initiator, tokenIn, tokenOut, amountIn, amountOut, fee)`: emitted on every swap. `initiator` is always `msg.sender`. Note that `amountOut` is the gross quoted value before fees, not the net amount the recipient received. `fee` is the pool fee only and excludes the protocol fee. The net amount received equals `amountOut - fee - protocolFee`.
- `Collect(feeAddress, tokenOut, amountOut)`: emitted when the owner withdraws accumulated fees.
- `SealStateChange(final, sealState)`: emitted on each `seal()` call. `final` is true once `sealState == maxSealState`.

---

## Splitter

Distributes an ETH or ERC20 balance among a fixed set of recipients by percentage.

**Proxy:** Yes (ERC1967)

**Key Functions:**
- `initialize(owner, accounts, percentAllocations)`: set the recipients and their shares.
- `updateSplit(accounts, percentAllocations)`: replace recipients and shares. Owner only.
- `distributeETH(accounts, percentAllocations)`: distribute the contract's entire ETH balance. Permissionless.
- `distributeERC20(token, accounts, percentAllocations)`: distribute the contract's entire balance of `token`. Permissionless.
- `getHash()`: returns `keccak256(abi.encodePacked(accounts, percentAllocations))`, the commitment stored at init or last update.

**How to use:**
1. Send ETH or tokens to the contract (it accepts ETH via `receive()`).
2. Call `distributeETH` or `distributeERC20`, passing the exact same `accounts` and `percentAllocations` used in `initialize` or `updateSplit`.

**Rules:**
- The passed arrays must hash to the stored split, or the call reverts with `InvalidHash`. Only the hash is stored on-chain, so callers must supply the full arrays each time.
- Allocations are in PPM and must sum to exactly `1_000_000`.
- At least 2 recipients. No duplicate addresses. No zero allocations.
- Any rounding remainder goes to the last recipient in the array.
- An empty balance is a no-op, not a revert.

**Errors:**
- `TooFewAccounts`, `AccountsAndAllocationsMismatch`, `InvalidAllocationsSum`, `DuplicateAccount`, `AllocationMustBePositive`, `InvalidHash`.

---

## FeePolicy

Per-pair or default swap fee configuration, consumed by SwapPool.

**Proxy:** Yes (ERC1967)

**Key Functions:**
- `initialize(owner, defaultFee)`: fee in PPM. Reverts with `InvalidFee` if `defaultFee > PPM`.
- `getFee(tokenIn, tokenOut)`: returns the pair-specific fee if one is set, otherwise `defaultFee`.
- `getDefaultFee()`: returns the current default fee.
- `calculateFee(tokenIn, tokenOut, amount)`: convenience helper returning `amount * fee / PPM`.
- `isActive()`: always returns true. Present for interface compatibility.
- `setDefaultFee(fee)`: owner only. Fee must be `<= PPM`.
- `setPairFee(tokenIn, tokenOut, fee)`: owner only. Direction-sensitive, so `A -> B` and `B -> A` are independent. Reverts on a zero token address or a fee above PPM.
- `removePairFee(tokenIn, tokenOut)`: owner only. Clears a pair override so the pair falls back to the default.

**Note on zero fees:**
A pair fee of `0` is treated as unset. `getFee` and `calculateFee` fall back to `defaultFee` when a pair's stored fee is `0`. You cannot set a pair to a literal zero fee; use `removePairFee` to clear an override instead.

**Events:**
- `DefaultFeeUpdated(oldFee, newFee)`
- `PairFeeUpdated(tokenIn, tokenOut, oldFee, newFee)`
- `PairFeeRemoved(tokenIn, tokenOut)`

---

## Limiter

Per-token, per-holder maximum balance caps. SwapPool enforces these on deposit.

**Proxy:** Yes (ERC1967)

**Key Functions:**
- `initialize(owner)`
- `limitOf(token, holder)`: returns the cap. A value of `0` means no cap has been set, which SwapPool treats as "block all deposits".
- `setLimitFor(token, holder, value)`: owner or writer only. `holder` must be a deployed contract.
- `addWriter(address)` / `deleteWriter(address)`: owner only.
- `isWriter(address)`: returns true for writers and for the owner.

**Deploy-time gotcha:**
`setLimitFor` rejects externally owned accounts (`InvalidHolder`) by checking `extcodesize`. Because `extcodesize` reads as `0` during a contract's own constructor, you cannot set a limit for a contract in the same transaction that deploys it. Set the limit in a later transaction.

**Events:**
- `LimitSet(token, holder, value)`
- `WriterAdded(writer)` / `WriterRemoved(writer)`

---

## RelativeQuoter

Price quoter using per-token exchange rates expressed relative to a common unit.

**Proxy:** Yes (ERC1967)

**Key Functions:**
- `initialize(owner)`
- `setPriceIndexValue(token, exchangeRate)`: set a token's rate in PPM. Owner only. Tokens with no rate set default to `PPM` (rate 1.0).
- `valueFor(outToken, inToken, value)`: forward quote (input to output).
- `reverseValueFor(outToken, inToken, value)`: inverse of `valueFor`. Given a desired output, returns the required input, rounded up. SwapPool uses this for `getAmountIn`.

**Calculation:**

The quoter first adjusts for the decimal difference between the two tokens, then applies the exchange rates:
```
outValue = adjustedValue * inExchangeRate / outExchangeRate
```
where `adjustedValue = value / 10^(inDecimals - outDecimals)` if `inDecimals > outDecimals`, or `value * 10^(outDecimals - inDecimals)` if `outDecimals > inDecimals`.

Two tokens both at the default rate trade 1:1, adjusted for decimals.

**Events:**
- `PriceIndexUpdated(tokenAddress, exchangeRate)`

---

## OracleQuoter

Price quoter using Chainlink oracle feeds.

**Proxy:** Yes (ERC1967)

**Key Functions:**
- `initialize(owner, baseCurrency)`: `baseCurrency` must be non-zero. It is metadata only and does not affect pricing. It records the common quote denomination for operators.
- `setOracle(token, oracleAddress)`: map a token to its Chainlink `AggregatorV3` feed. Owner only.
- `removeOracle(token)`: owner only.
- `setMaxStaleness(seconds)`: maximum age of an oracle price before it is rejected. Default is `86400` (1 day). Owner only.
- `setMultiplier(multiplier)`: adjust all quotes by a factor in PPM. Owner only. Allowed range is `900_000` (0.9x) to `1_100_000` (1.1x). A stored value of `0` or `1_000_000` means no adjustment.
- `valueFor(outToken, inToken, value)`: forward quote using live oracle prices, then the multiplier.
- `reverseValueFor(outToken, inToken, value)`: inverse of `valueFor`, rounded up. SwapPool uses this for `getAmountIn`.

**Calculation:**
```
rawOutput = value * inRate * 10^outTokenDecimals * 10^outOracleDecimals
             / (outRate * 10^inTokenDecimals * 10^inOracleDecimals)
outValue  = rawOutput * effectiveMultiplier / 1_000_000
```
where `effectiveMultiplier` is `multiplier` if set, otherwise `1_000_000` (no adjustment).

All four decimal adjustments are applied, so feeds with different precisions (for example 8-decimal USD feeds against 18-decimal Celo feeds) compose correctly.

**Constraints:**
- Both tokens must have oracles configured, otherwise the call reverts with `OracleNotSet(token)`.
- The price must be positive (`InvalidOraclePrice`) and no older than `maxStaleness` (`StaleOraclePrice`).
- There are no fallback rates. Any missing or failing oracle call reverts.

**Setup guide:**

Map each token to a Chainlink feed in the same quote denomination (for example, all `/USD`). The quoter cross-rates any two tokens through that shared denominator, so you do not need a direct feed for every pair.

Example: a pool supporting `MBUNI` (KES-pegged), `USDT`, `cUSD`, and `SANTOS` (BRL-pegged) on Celo:

| Token | Feed | Feed address |
|---|---|---|
| `MBUNI` | `KES / USD` | `0x0826492a24b1dBd1d8fcB4701b38C557CE685e9D` |
| `USDT` | `USDT / USD` | `0x5e37AF40A7A344ec9b03CCD34a250F3dA9a20B02` |
| `cUSD` | `CUSD / USD` | `0xe38A27BE4E7d866327e09736F3C570F256FFd048` |
| `SANTOS` | `BRL / USD` | `0xe8EcaF727080968Ed5F6DBB595B91e50eEb9F8B3` |

With this mapping the quoter can price any combination: `KES -> cUSD`, `BRL -> KES`, `KES -> KES` (two different KES-pegged tokens, 1:1), `USDT -> cUSD`, and so on.

Set `baseCurrency` to the settlement token your pool treats as primary (for example `cUSD`). It is stored as metadata and emitted in `Initialized`, and does not affect `valueFor` pricing.

**Events:**
- `Initialized(owner, baseCurrency)`
- `OracleUpdated(token, oracle)`
- `OracleRemoved(token)`
- `MaxStalenessUpdated(maxStaleness)`
- `MultiplierUpdated(oldMultiplier, newMultiplier)`

**Upgrade note:** Proxies upgraded in place read `multiplier` as `0` from uninitialized storage. The code treats `0` as `1_000_000` (no adjustment), so behaviour is preserved with no migration.

---

## ProtocolFeeController

Protocol-level fee configuration, consumed by SwapPool. See [SwapPool: Protocol Fee](#swappool) for how the fee is applied.

**Proxy:** Yes (ERC1967)

**Key Functions:**
- `initialize(owner, initialFee, initialRecipient)`: fee in PPM. `initialRecipient` must be non-zero. Starts active.
- `getProtocolFee()`: returns the fee in PPM, or `0` if inactive.
- `getProtocolFeeRecipient()`: returns the recipient address.
- `isActive()`: returns the active flag.
- `setProtocolFee(fee)`: owner only. Fee must be `<= PPM`.
- `setProtocolFeeRecipient(recipient)`: owner only. Recipient must be non-zero.
- `setActive(bool)`: owner only. Disabling makes `getProtocolFee()` return `0`, which switches the protocol fee off in SwapPool without changing the stored rate.

**Events:**
- `ProtocolFeeUpdated(oldFee, newFee)`
- `ProtocolFeeRecipientUpdated(oldRecipient, newRecipient)`
- `ActiveStateUpdated(active)`

---

## DecimalQuoter

Stateless quoter that only normalises for decimal differences. It assumes 1:1 value parity between tokens and applies no exchange rate.

**Proxy:** No (stateless, deploy once)

**Key Functions:**
- `valueFor(outToken, inToken, value)`: scales `value` from `inToken` decimals to `outToken` decimals.
- `reverseValueFor(outToken, inToken, value)`: inverse of `valueFor`, rounded up. SwapPool uses this for `getAmountIn`.

**Use case:** pools where tokens share the same real-world value but use different decimal precisions, for example a 6-decimal against an 18-decimal stablecoin.

---

## SwapRouter

Stateless multi-hop quoter that computes input and output amounts across a path of SwapPools. It does not hold funds or execute swaps. It only reports amounts.

**Proxy:** No (stateless, deploy once)

**Struct:**
```solidity
struct Hop {
    address pool;      // SwapPool address
    address tokenIn;   // token deposited into the pool
    address tokenOut;  // token received from the pool
}
```

**Key Functions:**
- `quoteExactInput(Hop[] path, uint256 amountIn) -> uint256 amountOut`: given an input amount, compute the final output after all hops.
- `quoteExactOutput(Hop[] path, uint256 amountOut) -> uint256 amountIn`: given a desired output, compute the required input across all hops.

**Errors:**
- `EmptyPath`: the `path` array is empty.

**How it works:**

`quoteExactInput` iterates forward. For each hop it calls `pool.getAmountOut(tokenOut, tokenIn, currentAmount)` and feeds the result into the next hop:
```
Hop 0: amountOut = poolA.getAmountOut(tokenOut, tokenIn, amountIn)
Hop 1: amountOut = poolB.getAmountOut(tokenOut, tokenIn, amountOut from hop 0)
...
```

`quoteExactOutput` iterates backward from the last hop. For each hop it calls `pool.getAmountIn(tokenOut, tokenIn, currentAmount)` and feeds the result into the previous hop:
```
Hop N-1: amountIn = poolB.getAmountIn(tokenOut, tokenIn, desiredAmountOut)
Hop N-2: amountIn = poolA.getAmountIn(tokenOut, tokenIn, amountIn from hop N-1)
...
```

**Roundtrip property:** for any desired output `X`, `quoteExactInput(path, quoteExactOutput(path, X)) >= X`. The +1 wei rounding safety in each pool's `getAmountIn` guarantees the computed input always yields at least the desired output.

**Usage examples:**

Single-hop quote (USDT to HAVANA via poolA):
```solidity
SwapRouter.Hop[] memory path = new SwapRouter.Hop[](1);
path[0] = SwapRouter.Hop(poolA, usdt, havana);

// How much HAVANA for 100 USDT?
uint256 amountOut = router.quoteExactInput(path, 100e6);

// How much USDT to receive exactly 99 HAVANA?
uint256 amountIn = router.quoteExactOutput(path, 99e6);
```

Multi-hop quote (USDT to HAVANA to TUKTUK via poolA then poolB):
```solidity
SwapRouter.Hop[] memory path = new SwapRouter.Hop[](2);
path[0] = SwapRouter.Hop(poolA, usdt, havana);
path[1] = SwapRouter.Hop(poolB, havana, tuktuk);

// How much TUKTUK for 100 USDT?
uint256 amountOut = router.quoteExactInput(path, 100e6);

// How much USDT to receive exactly 50 TUKTUK?
uint256 amountIn = router.quoteExactOutput(path, 50e6);
```

**Off-chain usage:** both functions are non-`view` (because `SwapPool.getAmountOut` / `getAmountIn` call a quoter that may be non-`view`), but they do not modify state. Call them via `eth_call` to get quotes without sending a transaction.

---

## EthFaucet

Native ETH faucet with an optional whitelist and an optional cooldown.

**Proxy:** Yes (ERC1967)

**Key Functions:**
- `initialize(owner, amount)`: set the owner and the ETH amount paid per claim.
- `gimme()`: claim ETH for the caller.
- `giveTo(recipient)`: claim ETH on behalf of another address.
- `check(recipient)`: returns true if `recipient` can claim right now. Does not record usage.
- `nextTime(subject)`: timestamp when `subject` may next claim. Requires a `periodChecker`.
- `setAmount(value)`: owner only. Reverts with `Sealed` if `VALUE_STATE` is sealed.
- `setRegistry(address)`: set the whitelist contract. Owner only. Reverts with `Sealed` if `REGISTRY_STATE` is sealed.
- `setPeriodChecker(address)`: set the cooldown contract. Owner only. Reverts with `Sealed` if `PERIODCHECKER_STATE` is sealed.
- `seal(state)`: permanently lock configuration fields. Owner only.

**Seal states:** `REGISTRY_STATE = 1`, `PERIODCHECKER_STATE = 2`, `VALUE_STATE = 4`, `maxSealState = 7`.

**Payout note:** claims pay out with a plain `transfer`, which forwards only 2300 gas. A contract recipient with a costly `receive`/`fallback` will cause the claim to revert.

**External interfaces expected:**
- `registry.have(address) -> bool`: whitelist check. Skipped when `registry` is unset.
- `periodChecker.have(address) -> bool`: cooldown eligibility. Skipped when `periodChecker` is unset.
- `periodChecker.poke(address) -> bool`: record usage.
- `periodChecker.next(address) -> uint256`: next allowed timestamp.

**Events:**
- `Give(recipient, token, amount)`: `token` is always `address(0)` (ETH).
- `FaucetAmountChange(amount)`
- `SealStateChange(sealState, registry, periodChecker)`: also emitted by `setRegistry` and `setPeriodChecker`, not just `seal`.

---

## PeriodSimple

Cooldown checker used by EthFaucet to rate-limit claims per address.

**Proxy:** Yes (ERC1967)

**Key Functions:**
- `initialize(owner, poker)`: set the owner and the initial poker.
- `have(subject) -> bool`: eligibility check, evaluated in this order:
  1. If `balanceThreshold > 0` and `subject.balance >= balanceThreshold`, return false. This overrides everything below, including first-time eligibility.
  2. If `subject` has never been poked (`lastUsed == 0`), return true.
  3. Otherwise return true only when `block.timestamp > lastUsed + period`.
- `poke(subject) -> bool`: record usage (`lastUsed[subject] = block.timestamp`). Returns false without recording if the subject is not eligible. Callable by the owner or the `poker`.
- `next(subject) -> uint256`: returns `lastUsed[subject] + period`.
- `setPeriod(seconds)` / `setPoker(address)` / `setBalanceThreshold(amount)`: owner only.

**Events:**
- `PeriodChange(value)`
- `BalanceThresholdChange(value)`

Note: `setPoker` does not emit an event.

---

## CAT

On-chain registry where accounts declare their preferred ERC20 settlement tokens, in priority order.

**Proxy:** Yes (ERC1967)

**Key Functions:**
- `initialize(owner)`
- `setTokens(tokens[])`: set the caller's own preference list. 1 to 5 tokens, no zero addresses.
- `setTokensFor(account, tokens[])`: set the list for another account. Owner or writer only.
- `getTokens(account) -> address[]`: the full ordered list. Index 0 is most preferred.
- `tokenAt(account, index)` / `tokenCount(account)`: individual access.
- `addWriter(address)` / `deleteWriter(address)`: owner only.
- `isWriter(address)`: returns true for writers and for the owner.

**Note:** `setTokens` and `setTokensFor` fully replace the list. Always submit the complete desired list, not a delta. Maximum 5 tokens per account (`MAX_TOKENS`).

**Events:**
- `TokensSet(account, tokens)`
- `WriterAdded(writer)` / `WriterRemoved(writer)`

---

## TokenUniqueSymbolIndex

Token registry indexed by unique ERC20 symbol. Used as a SwapPool `tokenRegistry`.

**Proxy:** Yes (ERC1967)

**Key Functions:**
- `initialize(owner, initialTokens[], initialSymbols[])`: pre-register tokens with explicit symbol keys. The two arrays must be the same length.
- `register(token)` / `add(token)`: read `symbol()` from the token and register it. The symbol must be 32 bytes or fewer. Duplicate symbols are rejected. Owner or writer only. (`register` and `add` are equivalent.)
- `remove(token)`: deregister a token. Owner or writer only.
- `have(token) -> bool`: whether the token is registered. Called by SwapPool.
- `addressOf(symbolKey) -> address`: look up a token by its bytes32 symbol key.
- `tokenIndex(token) -> bytes32`: the symbol key stored for a token.
- `entry(idx) -> address` / `entryCount()`: enumerate registered tokens (0-based).
- `identifier(idx) -> bytes32` / `identifierCount()`: enumerate registered symbol keys (0-based).
- `addWriter(address)` / `deleteWriter(address)`: owner only.
- `isWriter(address)`: public mapping. Returns the raw writer flag and does not treat the owner as a writer.

**Note:** `time`, `activate`, and `deactivate` exist as inert stubs for registry-interface compatibility. They return `0`/`false` and change no state.

**Events:**
- `AddressKey(symbol, token)` / `AddressAdded(token)` / `AddressRemoved(token)`
- `WriterAdded(writer)` / `WriterDeleted(writer)`

---

## ContractRegistry

Write-once key to address registry. The set of allowed identifiers is fixed at deploy time, and each identifier can be set exactly once.

**Proxy:** Yes (ERC1967)

**Key Functions:**
- `initialize(owner, identifiers[])`: set the owner and the allowed bytes32 identifier keys.
- `set(identifier, address)`: assign an address to an identifier. Owner only. Reverts if the identifier is unknown (`IdentifierNotFound`), the address is zero (`ZeroAddress`), or the identifier is already set (`IdentifierAlreadyExists`).
- `addressOf(identifier) -> address`: returns `address(0)` if not yet set.
- `identifier(idx)`: get an identifier by index (public array getter).
- `identifierCount()`: number of allowed identifiers.

**Events:**
- `AddressKey(identifier, address)`

---

## AccountsIndex

Enumerable address registry with per-entry activation state and an addition timestamp.

**Proxy:** Yes (ERC1967)

**Key Functions:**
- `initialize(owner)`
- `add(account)`: add an address. Owner or writer only. Reverts if already present.
- `remove(account)`: remove an address. Owner or writer only. Uses swap-and-pop, so entry order is not preserved.
- `activate(account)` / `deactivate(account)`: toggle active state. Owner or writer only.
- `have(account) -> bool`: whether the address is in the index.
- `isActive(account) -> bool`: whether the address is present and not deactivated.
- `time(account) -> uint256`: the block timestamp when the account was added. Reverts with `NotFound` if absent.
- `entry(idx) -> address` / `entryCount()`: enumerate entries (0-based).
- `addWriter(address)` / `deleteWriter(address)`: owner only.
- `isWriter(address)`: returns true for writers and for the owner.

**Events:**
- `AddressAdded(account)` / `AddressRemoved(account)`
- `AddressActive(account, active)`: emitted on activate and deactivate.
- `WriterAdded(writer)` / `WriterDeleted(writer)`

---

## RescueVault

Plain CREATE-deployed recovery contract for assets accidentally sent to a future contract address. The CREATE address depends only on the deployer address and nonce, not on constructor arguments, so a vault can occupy an address that another contract was expected to take.

**Proxy:** No

**Constructor:**
- `constructor(admin)` (payable): sets the sole address allowed to sweep assets. Reverts with `ZeroAddress` if `admin` is zero.

**Key Functions (admin only):**
- `sweepETH(to)`: send the full native ETH balance to `to`.
- `sweepERC20(token, to)` / `sweepERC20s(tokens, to)`: send the full balance of each named ERC20.
- `sweepERC721(token, tokenId, to)` / `sweepERC721s(token, tokenIds, to)`: transfer the named ERC721 token IDs.
- `sweepERC1155(token, id, to)` / `sweepERC1155Batch(token, ids, to)`: transfer the full ERC1155 balance for each named ID.

**Behaviour:**
- Only `admin` may sweep. The sweep recipient `to` must be non-zero.
- The contract accepts ETH via `receive()` and payable `fallback()`.
- It implements the ERC721 and ERC1155 receiver hooks, so NFTs can be sent with `safeTransferFrom`.
- Assets are not enumerable on-chain. The caller must supply token addresses and NFT IDs to sweep.

**Events:**
- `SweepETH(to, amount)`
- `SweepERC20(token, to, amount)`
- `SweepERC721(token, to, tokenId)`
- `SweepERC1155(token, to, id, amount)`
- `SweepERC1155Batch(token, to, ids, amounts)`

**Errors:**
- `Unauthorized`: caller is not `admin`.
- `ZeroAddress`: the constructor `admin` or a sweep recipient is zero.

---

## Common Patterns

### PPM (parts per million)
Fees and allocations use PPM, where `1_000_000 = 100%`. For example `10_000 = 1%` and `100_000 = 10%`.

### Writer role
`GiftableToken`, `Limiter`, `CAT`, `AccountsIndex`, and `TokenUniqueSymbolIndex` support a writer role: addresses granted specific write permissions by the owner, without full ownership. In most of these, `isWriter` also returns true for the owner. The exception is `TokenUniqueSymbolIndex`, where `isWriter` is a plain public mapping that reflects only the writer flag.

### Quoter interface
`RelativeQuoter`, `OracleQuoter`, and `DecimalQuoter` all implement `IQuoter`, which has two methods: `valueFor` (forward, input to output) and `reverseValueFor` (inverse, output to input, rounded up). SwapPool uses `valueFor` for `getAmountOut` and swaps, and `reverseValueFor` for `getAmountIn`, which powers exact-output routing through SwapRouter. The interface guarantees `valueFor(out, in, reverseValueFor(out, in, x)) >= x`.

### Proxy and initialization
Every contract marked "Proxy: Yes (ERC1967)" is set up by a one-time `initialize()` call at deploy time. Calling `initialize()` a second time on the same proxy reverts. Contracts marked "Proxy: No" are deployed directly with their constructor.
