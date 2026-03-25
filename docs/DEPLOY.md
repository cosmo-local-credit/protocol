# Deploy Guide

This guide covers deploying to Celo mainnet. For Alfajores testnet substitute `--chain-id 44787` and `--verifier-url https://api.etherscan.io/v2/api?chainid=44787`.

## Prerequisites

```bash
# build the deploy tool
go build -o ./ge-publish ./cmd/ge-publish

# build + extract bytecode artifacts
make all

# environment — set once, used throughout
export RPC_URL=https://forno.celo.org
export CHAIN_ID=42220
export PRIVATE_KEY=<deployer hex key>
export OWNER=<owner address>
export ETHERSCAN_API_KEY=<api key from etherscan.io — works for all chains via V2>

# shorthand used in every command below
GAS="--gas-fee-cap 35000000000 --gas-tip-cap 100"
BASE="--rpc-url $RPC_URL --chain-id $CHAIN_ID --private-key $PRIVATE_KEY $GAS"
```

---

## 1. Deploy the Factory

The factory is deployed once per deployer key via the Arachnid CREATE2 factory. The resulting address is the same on every EVM chain as long as the same deployer key is used.

```bash
./ge-publish publish-one --contract erc1967factory $BASE
```

Output:
```json
{ "factory": "0x..." }
```

```bash
export FACTORY=0x...   # save this
```

The factory address is deterministic. If you run this command again on a different chain with the same key, you will get the same address.

---

## 2. Deploy All Implementations

Implementations are plain `CREATE` contracts — no factory involved. Deploy each once. The resulting address can be reused across as many proxies as needed.

```bash
./ge-publish deploy-impl --contract accountsindex        $BASE
./ge-publish deploy-impl --contract cat                  $BASE
./ge-publish deploy-impl --contract contractregistry     $BASE
./ge-publish deploy-impl --contract ethfaucet            $BASE
./ge-publish deploy-impl --contract feepolicy            $BASE
./ge-publish deploy-impl --contract giftabletoken        $BASE
./ge-publish deploy-impl --contract limiter              $BASE
./ge-publish deploy-impl --contract oraclequoter         $BASE
./ge-publish deploy-impl --contract periodsimple         $BASE
./ge-publish deploy-impl --contract pfc                  $BASE
./ge-publish deploy-impl --contract relativequoter       $BASE
./ge-publish deploy-impl --contract splitter             $BASE
./ge-publish deploy-impl --contract swappool             $BASE
./ge-publish deploy-impl --contract tokenuniquesymbolindex $BASE
```

Each command outputs:
```json
{ "implementations": { "<contract>": "0x..." } }
```

Save all implementation addresses:
```bash
export IMPL_ACCOUNTSINDEX=0x...
export IMPL_CAT=0x...
export IMPL_CONTRACTREGISTRY=0x...
export IMPL_ETHFAUCET=0x...
export IMPL_FEEPOLICY=0x...
export IMPL_GIFTABLETOKEN=0x...
export IMPL_LIMITER=0x...
export IMPL_ORACLEQUOTER=0x...
export IMPL_PERIODSIMPLE=0x...
export IMPL_PFC=0x...
export IMPL_RELATIVEQUOTER=0x...
export IMPL_SPLITTER=0x...
export IMPL_SWAPPOOL=0x...
export IMPL_TOKENUNIQUESYMBOLINDEX=0x...
```

---

## 3. Non-Implementation Contracts

These two contracts are not proxied and do not use the factory. Deploy them directly:

```bash
# ERC1967Factory — already done in step 1

# DecimalQuoter — stateless, no proxy needed
./ge-publish publish-one --contract decimalquoter $BASE

# SwapRouter — stateless, no proxy needed
./ge-publish publish-one --contract swaprouter $BASE
```

Outputs:
```json
{ "decimal_quoter": "0x..." }
```

```json
{ "implementations": { "swaprouter": "0x..." } }
```

```bash
export DECIMAL_QUOTER=0x...
export SWAP_ROUTER=0x...
```

---

## 4. Verify All Implementations on Celoscan

Common flags for every verify call:
```bash
VERIFY="--chain-id 42220 --compiler-version 0.8.34 --evm-version osaka --num-of-optimizations 200 --verifier etherscan --verifier-url https://api.etherscan.io/v2/api?chainid=42220 --etherscan-api-key $ETHERSCAN_API_KEY"
```

```bash
forge verify-contract $IMPL_ACCOUNTSINDEX        src/AccountsIndex.sol:AccountsIndex               $VERIFY
forge verify-contract $IMPL_CAT                  src/CAT.sol:CAT                                    $VERIFY
forge verify-contract $IMPL_CONTRACTREGISTRY     src/ContractRegistry.sol:ContractRegistry          $VERIFY
forge verify-contract $IMPL_ETHFAUCET            src/EthFaucet.sol:EthFaucet                        $VERIFY
forge verify-contract $IMPL_FEEPOLICY            src/FeePolicy.sol:FeePolicy                        $VERIFY
forge verify-contract $IMPL_GIFTABLETOKEN        src/GiftableToken.sol:GiftableToken                $VERIFY
forge verify-contract $IMPL_LIMITER              src/Limiter.sol:Limiter                            $VERIFY
forge verify-contract $IMPL_ORACLEQUOTER         src/OracleQuoter.sol:OracleQuoter                  $VERIFY
forge verify-contract $IMPL_PERIODSIMPLE         src/PeriodSimple.sol:PeriodSimple                  $VERIFY
forge verify-contract $IMPL_PFC                  src/ProtocolFeeController.sol:ProtocolFeeController $VERIFY
forge verify-contract $IMPL_RELATIVEQUOTER       src/RelativeQuoter.sol:RelativeQuoter              $VERIFY
forge verify-contract $IMPL_SPLITTER             src/Splitter.sol:Splitter                          $VERIFY
forge verify-contract $IMPL_SWAPPOOL             src/SwapPool.sol:SwapPool                          $VERIFY
forge verify-contract $IMPL_TOKENUNIQUESYMBOLINDEX src/TokenUniqueSymbolIndex.sol:TokenUniqueSymbolIndex $VERIFY

# DecimalQuoter (non-proxied)
forge verify-contract $DECIMAL_QUOTER            src/DecimalQuoter.sol:DecimalQuoter                $VERIFY

# SwapRouter (non-proxied)
forge verify-contract $SWAP_ROUTER               src/SwapRouter.sol:SwapRouter                      $VERIFY

# ERC1967Factory (from solady library)
forge verify-contract $FACTORY \
  lib/solady/src/utils/ERC1967Factory.sol:ERC1967Factory $VERIFY
```

Celoscan will auto-detect ERC1967 proxy addresses and link them to their verified implementation. You do not need to separately verify proxy contracts.

---

## 5. Deploy Proxies

Each proxy is an independent instance with its own storage (owner, state). Multiple proxies can share one implementation.

### Contracts with no extra required args

```bash
./ge-publish deploy-proxy --contract accountsindex $BASE \
  --factory-address $FACTORY --impl-address $IMPL_ACCOUNTSINDEX --owner $OWNER

./ge-publish deploy-proxy --contract cat $BASE \
  --factory-address $FACTORY --impl-address $IMPL_CAT --owner $OWNER

./ge-publish deploy-proxy --contract limiter $BASE \
  --factory-address $FACTORY --impl-address $IMPL_LIMITER --owner $OWNER

./ge-publish deploy-proxy --contract relativequoter $BASE \
  --factory-address $FACTORY --impl-address $IMPL_RELATIVEQUOTER --owner $OWNER

./ge-publish deploy-proxy --contract periodsimple $BASE \
  --factory-address $FACTORY --impl-address $IMPL_PERIODSIMPLE --owner $OWNER
  # --period-poker <addr>   optional, defaults to owner
```

### FeePolicy

```bash
./ge-publish deploy-proxy --contract feepolicy $BASE \
  --factory-address $FACTORY --impl-address $IMPL_FEEPOLICY --owner $OWNER \
  --fee-policy-default 5000   # 0.5% in PPM (parts per million)
```

### ProtocolFeeController

```bash
./ge-publish deploy-proxy --contract pfc $BASE \
  --factory-address $FACTORY --impl-address $IMPL_PFC --owner $OWNER \
  --protocol-fee 1000 \          # 0.1% in PPM
  --protocol-recipient $OWNER    # address that receives the protocol fee
```

### OracleQuoter

```bash
./ge-publish deploy-proxy --contract oraclequoter $BASE \
  --factory-address $FACTORY --impl-address $IMPL_ORACLEQUOTER --owner $OWNER \
  --base-currency $USDC_ADDRESS  # all oracle feeds must be priced in this token
```

After deployment, set oracle feeds for each token (as owner):
```bash
cast send $ORACLEQUOTER_PROXY \
  "setOracle(address,address)" $TOKEN_ADDRESS $CHAINLINK_FEED_ADDRESS \
  --rpc-url $RPC_URL --private-key $PRIVATE_KEY --gas-price 35gwei
```

### GiftableToken

```bash
./ge-publish deploy-proxy --contract giftabletoken $BASE \
  --factory-address $FACTORY --impl-address $IMPL_GIFTABLETOKEN --owner $OWNER \
  --token-name "Sarafu" --token-symbol "SRF" --token-decimals 6
```

### ContractRegistry

```bash
./ge-publish deploy-proxy --contract contractregistry $BASE \
  --factory-address $FACTORY --impl-address $IMPL_CONTRACTREGISTRY --owner $OWNER \
  --registry-identifiers "SwapPool,GiftableToken,Limiter"  # comma-separated
```

### TokenUniqueSymbolIndex

```bash
./ge-publish deploy-proxy --contract tokenuniquesymbolindex $BASE \
  --factory-address $FACTORY --impl-address $IMPL_TOKENUNIQUESYMBOLINDEX --owner $OWNER
  # --token-index-tokens  "0xA,0xB"   optional: pre-register tokens
  # --token-index-symbols "SRF,MBAO"  optional: must match token count
```

### EthFaucet

```bash
./ge-publish deploy-proxy --contract ethfaucet $BASE \
  --factory-address $FACTORY --impl-address $IMPL_ETHFAUCET --owner $OWNER \
  --faucet-amount 1000000000000000  # drip amount in wei (0.001 CELO)
```

### Splitter

Allocations are in PPM (parts per million) and must sum to 1,000,000.

```bash
./ge-publish deploy-proxy --contract splitter $BASE \
  --factory-address $FACTORY --impl-address $IMPL_SPLITTER --owner $OWNER \
  --splitter-accounts   "0xADDR1,0xADDR2" \
  --splitter-allocations "700000,300000"   # 70% / 30%
```

### SwapPool

Requires `feepolicy`, `limiter`, and `pfc` proxy addresses. `--pool-quoter` must be the quoter proxy address (either a RelativeQuoter or OracleQuoter proxy).

```bash
./ge-publish deploy-proxy --contract swappool $BASE \
  --factory-address $FACTORY --impl-address $IMPL_SWAPPOOL --owner $OWNER \
  --pool-name "Sarafu Pool" --pool-symbol "SRFp" --pool-decimals 6 \
  --pool-quoter              $RELATIVEQUOTER_PROXY \
  --pool-fee-policy          $FEEPOLICY_PROXY \
  --pool-token-limiter       $LIMITER_PROXY \
  --pool-protocol-fee-controller $PFC_PROXY
  # --pool-fee-address        <addr>   optional, defaults to owner
  # --pool-token-registry     <addr>   optional
  # --pool-fees-decoupled              optional flag
```

---

## 6. Upgrading an Implementation

Upgrading replaces the logic behind all proxies that point to an implementation, without changing any proxy address or stored state. Only the proxy admin can upgrade.

### Step 1 — deploy the new implementation

```bash
./ge-publish deploy-impl --contract giftabletoken $BASE
# → {"implementations": {"giftabletoken": "0xNEW_IMPL"}}
export NEW_IMPL=0x...
```

### Step 2 — verify the new implementation

```bash
forge verify-contract $NEW_IMPL src/GiftableToken.sol:GiftableToken $VERIFY
```

### Step 3 — point the proxy at the new implementation

If no re-initialization is needed:
```bash
cast send $FACTORY \
  "upgrade(address,address)" $PROXY_ADDRESS $NEW_IMPL \
  --rpc-url $RPC_URL --private-key $ADMIN_KEY \
  --gas-limit 100000 --gas-price 35gwei
```

If the new implementation added new state that requires initializing via a `reinitialize` function:
```bash
cast send $FACTORY \
  "upgradeAndCall(address,address,bytes)" \
  $PROXY_ADDRESS $NEW_IMPL \
  $(cast calldata "reinitialize(uint64)" 2) \
  --rpc-url $RPC_URL --private-key $ADMIN_KEY \
  --gas-limit 200000 --gas-price 35gwei
```

The upgrade takes effect immediately. All callers of the proxy address automatically use the new logic. The proxy address does not change.

### Upgrading multiple proxies

Each proxy must be upgraded individually — there is no batch upgrade. Repeat step 3 for each proxy that should use the new implementation.

---

## Reference

### Gas limits

| Contract | Implementation gas |
|---|---|
| AccountsIndex | 2,000,000 |
| CAT | 2,000,000 |
| ContractRegistry | 2,000,000 |
| EthFaucet | 2,000,000 |
| GiftableToken | 2,000,000 |
| PeriodSimple | 2,000,000 |
| SwapPool | 2,500,000 |
| TokenUniqueSymbolIndex | 2,000,000 |
| FeePolicy | 1,000,000 |
| Limiter | 1,000,000 |
| OracleQuoter | 1,500,000 |
| ProtocolFeeController | 1,000,000 |
| RelativeQuoter | 1,000,000 |
| Splitter | 5,000,000 |
| DecimalQuoter (plain) | 1,000,000 |
| SwapRouter (plain) | 1,000,000 |
| ERC1967Factory (plain) | 1,000,000 |
| Proxy deployment | 500,000 |

### Compiler settings

| Setting | Value |
|---|---|
| Solidity | 0.8.34 |
| EVM target | osaka |
| Optimizer | enabled |
| Optimizer runs | 200 |

### Chain IDs

| Network | Chain ID | RPC | Etherscan V2 API |
|---|---|---|---|
| Celo mainnet | 42220 | `https://forno.celo.org` | `https://api.etherscan.io/v2/api?chainid=42220` |
| Alfajores testnet | 44787 | `https://alfajores-forno.celo-testnet.org` | `https://api.etherscan.io/v2/api?chainid=44787` |
