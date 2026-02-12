# Publish Library

Go library for deploying Sarafu Network Protocol contracts programmatically.

All contracts use the **ERC1967 proxy pattern**: an implementation contract is deployed once (empty constructor with `_disableInitializers()`), then one or more proxies are created via Solady's `ERC1967Factory`, each initialized independently through their `initialize()` function.

## Table of Contents

- [Prerequisites](#prerequisites)
- [Installation](#installation)
- [Building Artifacts](#building-artifacts)
- [Architecture Overview](#architecture-overview)
- [API Reference](#api-reference)
- [Scenarios](#scenarios)
  - [1. Deploy the ERC1967Factory](#1-deploy-the-erc1967factory)
  - [2. Deploy an Implementation](#2-deploy-an-implementation)
  - [3. Deploy a Proxy (Single Token)](#3-deploy-a-proxy-single-token)
  - [4. Deploy Multiple Tokens from One Implementation](#4-deploy-multiple-tokens-from-one-implementation)
  - [5. Deploy a Stateless Contract (No Proxy)](#5-deploy-a-stateless-contract-no-proxy)
  - [6. Full System Deployment](#6-full-system-deployment)
  - [7. Upgrade an Implementation](#7-upgrade-an-implementation)
  - [8. Upgrade a Single Proxy](#8-upgrade-a-single-proxy)
  - [9. Batch Upgrade Multiple Proxies](#9-batch-upgrade-multiple-proxies)
  - [10. Deterministic Deployment (CREATE2)](#10-deterministic-deployment-create2)
  - [11. Deterministic Proxy via ERC1967Factory](#11-deterministic-proxy-via-erc1967factory)
  - [12. Predict Deterministic Proxy Address](#12-predict-deterministic-proxy-address)
  - [13. Change Proxy Admin](#13-change-proxy-admin)
  - [14. Query Proxy Admin](#14-query-proxy-admin)
- [Contract Reference](#contract-reference)
- [Gas Limits](#gas-limits)
- [Error Handling](#error-handling)

## Prerequisites

- Go 1.21+
- [Foundry](https://book.getfoundry.sh/) (`forge` for building Solidity)
- An EVM RPC endpoint
- A funded deployer private key

## Installation

```bash
go get github.com/cosmo-local-credit/protocol/publish@latest
```

## Building Artifacts

The `.bin` files (embedded bytecode) must be built from the Solidity source before the Go code compiles:

```bash
cd publish
make          # runs forge build + extracts .bin files
go build ./...
```

To rebuild only the artifacts (if Solidity changed):

```bash
make artifacts
```

To clean artifacts:

```bash
make clean
```


## API Reference

### Deployer

```go
// Create a new deployer. gasFeeCap and gasTipCap are EIP-1559 fee parameters.
func NewDeployer(rpcURL string, chainID int64, privateKey *ecdsa.PrivateKey,
    gasFeeCap, gasTipCap *big.Int) (*Deployer, error)

// Returns the deployer's Ethereum address.
func (d *Deployer) Address() common.Address

// Closes the RPC connection.
func (d *Deployer) Close() error
```

### Deployment

```go
// Sends a contract creation transaction. Returns the tx hash and the
// predicted contract address (via CREATE: keccak(sender, nonce)).
// Non-blocking: returns after the tx is sent, not after it is mined.
func (d *Deployer) DeployImplementation(ctx context.Context, bytecode []byte,
    gasLimit uint64) (DeployResult, error)

// Calls ERC1967Factory.deployAndCall(implementation, admin, initData).
// Returns the tx hash. The proxy address must be extracted from the receipt.
func (d *Deployer) DeployProxy(ctx context.Context, factory, implementation,
    admin common.Address, initData []byte, gasLimit uint64) (common.Hash, error)
```

### Receipts

```go
// Polls for a transaction receipt every 2 seconds. Blocks until the receipt
// is available or the context is cancelled.
func (d *Deployer) WaitForReceipt(ctx context.Context,
    txHash common.Hash) (*types.Receipt, error)

// Extracts the proxy address from the Deployed(proxy, implementation, admin)
// event in the receipt logs.
func ProxyAddressFromReceipt(receipt *types.Receipt) (common.Address, error)
```

### Constants

```go
const ProxyGasLimit uint64 = 500_000
```

### Contract Packages

Each contract package under `contracts/` exports:

| Export | Description |
|--------|-------------|
| `Bytecode() []byte` | Returns the embedded implementation bytecode |
| `EncodeInit(args InitArgs) ([]byte, error)` | ABI-encodes the `initialize()` calldata |
| `InitArgs` | Struct with typed fields matching the Solidity `initialize()` signature |
| `ImplGasLimit` / `GasLimit` | Suggested gas limit for deploying the implementation |

## Scenarios

Every example assumes this common setup:

```go
import (
    "context"
    "crypto/ecdsa"
    "math/big"

    "github.com/ethereum/go-ethereum/common"
    "github.com/ethereum/go-ethereum/crypto"
    "github.com/lmittmann/w3"

    "github.com/cosmo-local-credit/protocol/publish"
    "github.com/cosmo-local-credit/protocol/publish/contracts/decimalquoter"
    "github.com/cosmo-local-credit/protocol/publish/contracts/erc1967factory"
    "github.com/cosmo-local-credit/protocol/publish/contracts/feepolicy"
    "github.com/cosmo-local-credit/protocol/publish/contracts/giftabletoken"
    "github.com/cosmo-local-credit/protocol/publish/contracts/limiter"
    "github.com/cosmo-local-credit/protocol/publish/contracts/protocolfeecontroller"
    "github.com/cosmo-local-credit/protocol/publish/contracts/relativequoter"
    "github.com/cosmo-local-credit/protocol/publish/contracts/swappool"
)

ctx := context.Background()
privateKey, _ := crypto.HexToECDSA("06b50d6701d61f02a0c7630a6bd38d8773c2cb681c824a47ce1505069721ce67")

gasFeeCap := big.NewInt(2_000_000_000)
gasTipCap := big.NewInt(1_000_000_000)

d, err := publish.NewDeployer("http://localhost:8545", 31337, privateKey, gasFeeCap, gasTipCap)
if err != nil {
    log.Fatal(err)
}
defer d.Close()

admin := d.Address()
```

---

### 1. Deploy the ERC1967Factory

The factory is a plain contract (no proxy, no initialize). Deploy it once per chain.

```go
result, err := d.DeployImplementation(ctx, erc1967factory.Bytecode(), erc1967factory.GasLimit)
if err != nil {
    log.Fatal(err)
}

factoryAddr := result.ContractAddress
fmt.Printf("ERC1967Factory: %s\n", factoryAddr)
```

---

### 2. Deploy an Implementation

Implementation contracts have empty constructors (`_disableInitializers()`). They are never called directly — proxies delegate to them.

```go
implResult, err := d.DeployImplementation(ctx, giftabletoken.Bytecode(), giftabletoken.ImplGasLimit)
if err != nil {
    log.Fatal(err)
}

implAddr := implResult.ContractAddress
fmt.Printf("GiftableToken implementation: %s\n", implAddr)
```

---

### 3. Deploy a Proxy (Single Token)

Once the implementation is deployed, create a proxy that points to it. The proxy is initialized atomically via `deployAndCall`.

```go
initData, err := giftabletoken.EncodeInit(giftabletoken.InitArgs{
    Name:      "Sarafu",
    Symbol:    "SRF",
    Decimals:  6,
    Owner:     d.Address(),
    ExpiresAt: big.NewInt(0),
})
if err != nil {
    log.Fatal(err)
}

txHash, err := d.DeployProxy(ctx, factoryAddr, implAddr, admin, initData, publish.ProxyGasLimit)
if err != nil {
    log.Fatal(err)
}

receipt, err := d.WaitForReceipt(ctx, txHash)
if err != nil {
    log.Fatal(err)
}

if receipt.Status != 1 {
    log.Fatal("proxy deployment failed")
}

proxyAddr, err := publish.ProxyAddressFromReceipt(receipt)
if err != nil {
    log.Fatal(err)
}

fmt.Printf("SRF token (proxy): %s\n", proxyAddr)
```

---

### 4. Deploy Multiple Tokens from One Implementation

A single implementation can back unlimited proxies. Each proxy has its own storage and initialization.

```go
// Implementation is already deployed at implAddr (from scenario 2)
tokens := []giftabletoken.InitArgs{
    {Name: "Sarafu", Symbol: "SRF", Decimals: 6, Owner: admin, ExpiresAt: big.NewInt(0)},
    {Name: "Mbao", Symbol: "MBAO", Decimals: 6, Owner: admin, ExpiresAt: big.NewInt(0)},
    {Name: "Muu", Symbol: "MUU", Decimals: 6, Owner: admin, ExpiresAt: big.NewInt(0)},
}

for _, t := range tokens {
    initData, err := giftabletoken.EncodeInit(t)
    if err != nil {
        log.Fatal(err)
    }

    txHash, err := d.DeployProxy(ctx, factoryAddr, implAddr, admin, initData, publish.ProxyGasLimit)
    if err != nil {
        log.Fatal(err)
    }

    receipt, err := d.WaitForReceipt(ctx, txHash)
    if err != nil {
        log.Fatal(err)
    }

    proxyAddr, err := publish.ProxyAddressFromReceipt(receipt)
    if err != nil {
        log.Fatal(err)
    }

    fmt.Printf("%s (%s): %s\n", t.Name, t.Symbol, proxyAddr)
}
```

Output:
```
Sarafu (SRF): 0x...
Mbao (MBAO): 0x...
Muu (MUU): 0x...
```

---

### 5. Deploy a Stateless Contract (No Proxy)

`DecimalQuoter` is stateless — no proxy, no initialize. Deploy it directly like the factory.

```go
result, err := d.DeployImplementation(ctx, decimalquoter.Bytecode(), decimalquoter.GasLimit)
if err != nil {
    log.Fatal(err)
}

receipt, err := d.WaitForReceipt(ctx, result.TxHash)
if err != nil {
    log.Fatal(err)
}

quoterAddr := result.ContractAddress
fmt.Printf("DecimalQuoter: %s\n", quoterAddr)
```

---

### 6. Full System Deployment

Deploy the complete protocol stack: factory, all implementations, then proxies.

```go
// 1. Factory
factoryResult, _ := d.DeployImplementation(ctx, erc1967factory.Bytecode(), erc1967factory.GasLimit)
d.WaitForReceipt(ctx, factoryResult.TxHash)
factoryAddr := factoryResult.ContractAddress

// 2. All implementations 
feeImplResult, _ := d.DeployImplementation(ctx, feepolicy.Bytecode(), feepolicy.ImplGasLimit)
d.WaitForReceipt(ctx, feeImplResult.TxHash)

limiterImplResult, _ := d.DeployImplementation(ctx, limiter.Bytecode(), limiter.ImplGasLimit)
d.WaitForReceipt(ctx, limiterImplResult.TxHash)

quoterImplResult, _ := d.DeployImplementation(ctx, relativequoter.Bytecode(), relativequoter.ImplGasLimit)
d.WaitForReceipt(ctx, quoterImplResult.TxHash)

pfcImplResult, _ := d.DeployImplementation(ctx, protocolfeecontroller.Bytecode(), protocolfeecontroller.ImplGasLimit)
d.WaitForReceipt(ctx, pfcImplResult.TxHash)

tokenImplResult, _ := d.DeployImplementation(ctx, giftabletoken.Bytecode(), giftabletoken.ImplGasLimit)
d.WaitForReceipt(ctx, tokenImplResult.TxHash)

poolImplResult, _ := d.DeployImplementation(ctx, swappool.Bytecode(), swappool.ImplGasLimit)
d.WaitForReceipt(ctx, poolImplResult.TxHash)

decimalQuoterResult, _ := d.DeployImplementation(ctx, decimalquoter.Bytecode(), decimalquoter.GasLimit)
d.WaitForReceipt(ctx, decimalQuoterResult.TxHash)

// 3. Proxies (in correct dependency order)

// FeePolicy proxy
feePolicyInit, _ := feepolicy.EncodeInit(feepolicy.InitArgs{
    Owner:      admin,
    // 0.5% (in PPM where 1_000_000 = 100%)
    DefaultFee: big.NewInt(5000), 
})
feePolicyTx, _ := d.DeployProxy(ctx, factoryAddr, feeImplResult.ContractAddress, admin, feePolicyInit, publish.ProxyGasLimit)
feePolicyReceipt, _ := d.WaitForReceipt(ctx, feePolicyTx)
feePolicyAddr, _ := publish.ProxyAddressFromReceipt(feePolicyReceipt)

// Limiter proxy
limiterInit, _ := limiter.EncodeInit(limiter.InitArgs{Owner: admin})
limiterTx, _ := d.DeployProxy(ctx, factoryAddr, limiterImplResult.ContractAddress, admin, limiterInit, publish.ProxyGasLimit)
limiterReceipt, _ := d.WaitForReceipt(ctx, limiterTx)
limiterAddr, _ := publish.ProxyAddressFromReceipt(limiterReceipt)

// RelativeQuoter proxy
quoterInit, _ := relativequoter.EncodeInit(relativequoter.InitArgs{Owner: admin})
quoterTx, _ := d.DeployProxy(ctx, factoryAddr, quoterImplResult.ContractAddress, admin, quoterInit, publish.ProxyGasLimit)
quoterReceipt, _ := d.WaitForReceipt(ctx, quoterTx)
quoterAddr, _ := publish.ProxyAddressFromReceipt(quoterReceipt)

// ProtocolFeeController proxy
pfcInit, _ := protocolfeecontroller.EncodeInit(protocolfeecontroller.InitArgs{
    Owner:            admin,
     // 0.1%
    InitialFee:       big.NewInt(1000),
    InitialRecipient: admin,
})
pfcTx, _ := d.DeployProxy(ctx, factoryAddr, pfcImplResult.ContractAddress, admin, pfcInit, publish.ProxyGasLimit)
pfcReceipt, _ := d.WaitForReceipt(ctx, pfcTx)
pfcAddr, _ := publish.ProxyAddressFromReceipt(pfcReceipt)

// Token proxy
tokenInit, _ := giftabletoken.EncodeInit(giftabletoken.InitArgs{
    Name: "Sarafu", Symbol: "SRF", Decimals: 6,
    Owner: admin, ExpiresAt: big.NewInt(0),
})
tokenTx, _ := d.DeployProxy(ctx, factoryAddr, tokenImplResult.ContractAddress, admin, tokenInit, publish.ProxyGasLimit)
tokenReceipt, _ := d.WaitForReceipt(ctx, tokenTx)
tokenAddr, _ := publish.ProxyAddressFromReceipt(tokenReceipt)

// SwapPool proxy (references all the above)
poolInit, _ := swappool.EncodeInit(swappool.InitArgs{
    Name: "Sarafu Pool", Symbol: "SRFp", Decimals: 6,
    Owner:                 admin,
    FeePolicy:             feePolicyAddr,
    FeeAddress:            admin,
    // zero = no registry
    TokenRegistry:         common.Address{}, 
    TokenLimiter:          limiterAddr,
    Quoter:                quoterAddr,
    FeesDecoupled:         false,
    ProtocolFeeController: pfcAddr,
})
poolTx, _ := d.DeployProxy(ctx, factoryAddr, poolImplResult.ContractAddress, admin, poolInit, publish.ProxyGasLimit)
poolReceipt, _ := d.WaitForReceipt(ctx, poolTx)
poolAddr, _ := publish.ProxyAddressFromReceipt(poolReceipt)

fmt.Printf("Factory:               %s\n", factoryAddr)
fmt.Printf("FeePolicy (proxy):     %s\n", feePolicyAddr)
fmt.Printf("Limiter (proxy):       %s\n", limiterAddr)
fmt.Printf("RelativeQuoter (proxy):%s\n", quoterAddr)
fmt.Printf("ProtocolFeeCtrl (proxy):%s\n", pfcAddr)
fmt.Printf("DecimalQuoter:         %s\n", decimalQuoterResult.ContractAddress)
fmt.Printf("GiftableToken (proxy): %s\n", tokenAddr)
fmt.Printf("SwapPool (proxy):      %s\n", poolAddr)
```

---

### 7. Upgrade an Implementation

To upgrade, deploy a **new** implementation, then point existing proxies at it. The old implementation stays on-chain (immutable) — it just stops being used.

```go
// Deploy new implementation (e.g. GiftableToken v2 after recompiling Solidity)
newImplResult, err := d.DeployImplementation(ctx, giftabletoken.Bytecode(), giftabletoken.ImplGasLimit)
if err != nil {
    log.Fatal(err)
}

receipt, _ := d.WaitForReceipt(ctx, newImplResult.TxHash)
if receipt.Status != 1 {
    log.Fatal("new implementation deployment failed")
}

newImplAddr := newImplResult.ContractAddress
fmt.Printf("New GiftableToken impl: %s\n", newImplAddr)
// Now use scenario 8 or 9 to point proxies at this new implementation
```

---

### 8. Upgrade a Single Proxy

The ERC1967Factory exposes `upgrade(proxy, implementation)` and `upgradeAndCall(proxy, implementation, data)`. Only the proxy's admin can call these.

Since the publish library provides low-level tx building, encode the call manually with `w3`:

```go
var funcUpgrade = w3.MustNewFunc("upgrade(address,address)", "")

calldata, err := funcUpgrade.EncodeArgs(proxyAddr, newImplAddr)
if err != nil {
    log.Fatal(err)
}

nonce, _ := /* use d.Address() and eth.Nonce */

tx := types.NewTx(&types.DynamicFeeTx{
    Nonce:     nonce,
    To:        &factoryAddr,
    GasFeeCap: gasFeeCap,
    GasTipCap: gasTipCap,
    Gas:       100_000,
    Data:      calldata,
})

// Sign and send (use the admin's private key — must be the proxy's admin)
signedTx, _ := types.SignTx(tx, types.LatestSignerForChainID(big.NewInt(42220)), privateKey)
// ... send via client
```

With migration data (if the new implementation needs a re-initialization call):

```go
var funcUpgradeAndCall = w3.MustNewFunc("upgradeAndCall(address,address,bytes)", "")

// Encode migration function (defined in your new implementation)
var funcMigrateV2 = w3.MustNewFunc("migrateV2(uint256)", "")
migrateData, _ := funcMigrateV2.EncodeArgs(big.NewInt(42))

calldata, _ := funcUpgradeAndCall.EncodeArgs(proxyAddr, newImplAddr, migrateData)
// ... build, sign, send tx to factoryAddr
```

> **Important:** `upgrade` and `upgradeAndCall` emit the `Upgraded(address indexed proxy, address indexed implementation)` event.

---

### 9. Batch Upgrade Multiple Proxies

When you have many proxies pointing to the same old implementation, upgrade them one by one. Each proxy is independent.

```go
var funcUpgrade = w3.MustNewFunc("upgrade(address,address)", "")

proxies := []common.Address{srfProxy, mbaoProxy, muuProxy}

for _, proxy := range proxies {
    calldata, _ := funcUpgrade.EncodeArgs(proxy, newImplAddr)

    // Build and send tx to factoryAddr
    // Each proxy is upgraded independently
    // Must be called by the proxy's admin
}
```

> **Tip:** If all proxies share the same admin (your deployer), you can batch these in a loop. Each tx upgrades one proxy. The implementation deployment only happens once.

---

### 10. Deterministic Deployment (CREATE2)

To deploy a contract at a **predictable address** (same address across chains), use the Arachnid CREATE2 factory at `0x4e59b44847b379578588920cA78FbF26c0B4956C`.

This factory accepts `bytes32 salt ++ bytecode` as calldata and deploys via CREATE2. The resulting address is:

```
address = keccak256(0xff ++ factory ++ salt ++ keccak256(bytecode))[12:]
```

```go
var arachnidFactory = common.HexToAddress("0x4e59b44847b379578588920cA78FbF26c0B4956C")

// Salt — pick any 32-byte value. Same salt + same bytecode = same address on any chain.
salt := common.HexToHash("0x0000000000000000000000000000000000000000000000000000000000000001")

// Deterministic deployment of ERC1967Factory via CREATE2
bytecode := erc1967factory.Bytecode()

// The Arachnid factory expects: salt (32 bytes) ++ bytecode
payload := append(salt.Bytes(), bytecode...)

nonce, _ := /* get nonce */

tx := types.NewTx(&types.DynamicFeeTx{
    Nonce:     nonce,
    To:        &arachnidFactory,
    GasFeeCap: gasFeeCap,
    GasTipCap: gasTipCap,
    Gas:       erc1967factory.GasLimit,
    Data:      payload,
})

// Sign and send...
```

To predict the address before deploying:

```go
// CREATE2 address prediction
func predictCreate2(deployer common.Address, salt [32]byte, initCode []byte) common.Address {
    return crypto.CreateAddress2(deployer, salt, crypto.Keccak256(initCode))
}

predicted := predictCreate2(arachnidFactory, salt, erc1967factory.Bytecode())
fmt.Printf("ERC1967Factory will deploy to: %s\n", predicted)
```

This gives you the **same address on every EVM chain** as long as:
- The Arachnid factory is at `0x4e59b44847b379578588920cA78FbF26c0B4956C`
- You use the same salt
- The bytecode is identical

---

### 11. Deterministic Proxy via ERC1967Factory

The ERC1967Factory itself supports CREATE2 proxy deployment via `deployDeterministic` and `deployDeterministicAndCall`. This gives proxies predictable addresses.

```go
var funcDeployDeterministicAndCall = w3.MustNewFunc(
    "deployDeterministicAndCall(address,address,bytes32,bytes)", "address",
)

salt := common.HexToHash("0x00000000000000000000000000000000000000000000000000000000000000ff")

initData, _ := giftabletoken.EncodeInit(giftabletoken.InitArgs{
    Name:      "Sarafu",
    Symbol:    "SRF",
    Decimals:  6,
    Owner:     admin,
    ExpiresAt: big.NewInt(0),
})

calldata, _ := funcDeployDeterministicAndCall.EncodeArgs(
     // implementation
    implAddr,  
    // proxy admin
    admin,      
    // CREATE2 salt
    salt,      
     // initialize() calldata 
    initData,  
)

nonce, _ := /* get nonce */

tx := types.NewTx(&types.DynamicFeeTx{
    Nonce:     nonce,
    To:        &factoryAddr,
    GasFeeCap: gasFeeCap,
    GasTipCap: gasTipCap,
    Gas:       publish.ProxyGasLimit,
    Data:      calldata,
})

// Sign, send, wait for receipt...
// The proxy address comes from the receipt's Deployed event (same as non-deterministic)
receipt, _ := d.WaitForReceipt(ctx, txHash)
proxyAddr, _ := publish.ProxyAddressFromReceipt(receipt)
```

Without initialization data (bare proxy):

```go
var funcDeployDeterministic = w3.MustNewFunc(
    "deployDeterministic(address,address,bytes32)", "address",
)

calldata, _ := funcDeployDeterministic.EncodeArgs(implAddr, admin, salt)
// ... build, sign, send tx to factoryAddr
```

> **Salt restriction:** If the first 20 bytes of the salt are non-zero, they must match `msg.sender`. This prevents front-running. Use a zero-prefixed salt (or prefix with your deployer address) to avoid `SaltDoesNotStartWithCaller()` errors.

---

### 12. Predict Deterministic Proxy Address

The ERC1967Factory has a view function to predict where a deterministic proxy will be deployed:

```go
var funcPredictAddress = w3.MustNewFunc(
    "predictDeterministicAddress(bytes32)", "address",
)

// Encode the call
calldata, _ := funcPredictAddress.EncodeArgs(salt)

// Call (read-only, no tx needed)
var predicted common.Address
err := client.CallCtx(ctx, eth.CallFunc(factoryAddr, funcPredictAddress, salt).Returns(&predicted))

fmt.Printf("Proxy will be at: %s\n", predicted)
```

You can also compute it off-chain. The factory's `initCodeHash()` returns the hash of the proxy init code:

```go
var funcInitCodeHash = w3.MustNewFunc("initCodeHash()", "bytes32")

var codeHash common.Hash
err := client.CallCtx(ctx, eth.CallFunc(factoryAddr, funcInitCodeHash).Returns(&codeHash))

// CREATE2 prediction: keccak256(0xff ++ factory ++ salt ++ initCodeHash)[12:]
predicted := crypto.CreateAddress2(factoryAddr, salt, codeHash.Bytes())
```

---

### 13. Change Proxy Admin

The admin is the only account that can upgrade a proxy or change its admin. Transfer admin rights via the factory:

```go
var funcChangeAdmin = w3.MustNewFunc("changeAdmin(address,address)", "")

newAdmin := common.HexToAddress("0x1234567890abcdef1234567890abcdef12345678")
calldata, _ := funcChangeAdmin.EncodeArgs(proxyAddr, newAdmin)

// Build and send tx to factoryAddr (must be signed by current admin)
```

> **Warning:** This is irreversible from the old admin's perspective. The new admin is the only one who can upgrade or change admin again. Double-check the new admin address. Emits `AdminChanged(proxy, admin)`.

---

### 14. Query Proxy Admin

Check who the current admin of a proxy is:

```go
var funcAdminOf = w3.MustNewFunc("adminOf(address)", "address")

var currentAdmin common.Address
err := client.CallCtx(ctx, eth.CallFunc(factoryAddr, funcAdminOf, proxyAddr).Returns(&currentAdmin))

fmt.Printf("Admin of %s: %s\n", proxyAddr, currentAdmin)
```

---

## Contract Reference

| Package | Contract | Proxy | `initialize()` Signature |
|---------|----------|-------|--------------------------|
| `erc1967factory` | ERC1967Factory | No | N/A (plain deploy) |
| `giftabletoken` | GiftableToken | Yes | `(string,string,uint8,address,uint256)` |
| `swappool` | SwapPool | Yes | `(string,string,uint8,address,address,address,address,address,address,bool,address)` |
| `limiter` | Limiter | Yes | `(address)` |
| `feepolicy` | FeePolicy | Yes | `(address,uint256)` |
| `relativequoter` | RelativeQuoter | Yes | `(address)` |
| `protocolfeecontroller` | ProtocolFeeController | Yes | `(address,uint256,address)` |
| `decimalquoter` | DecimalQuoter | No | N/A (stateless, plain deploy) |

### InitArgs Fields

**GiftableToken:**

| Field | Type | Description |
|-------|------|-------------|
| `Name` | `string` | Token name |
| `Symbol` | `string` | Token symbol |
| `Decimals` | `uint8` | Decimal places |
| `Owner` | `common.Address` | Owner (can mint, manage writers) |
| `ExpiresAt` | `*big.Int` | Expiry timestamp (0 = never) |

**SwapPool:**

| Field | Type | Description |
|-------|------|-------------|
| `Name` | `string` | Pool voucher name |
| `Symbol` | `string` | Pool voucher symbol |
| `Decimals` | `uint8` | Decimal places |
| `Owner` | `common.Address` | Pool owner |
| `FeePolicy` | `common.Address` | FeePolicy proxy address |
| `FeeAddress` | `common.Address` | Address that receives fees |
| `TokenRegistry` | `common.Address` | Token registry (zero = none) |
| `TokenLimiter` | `common.Address` | Limiter proxy address |
| `Quoter` | `common.Address` | Quoter proxy address |
| `FeesDecoupled` | `bool` | Whether fees are decoupled |
| `ProtocolFeeController` | `common.Address` | ProtocolFeeController proxy |

**FeePolicy:**

| Field | Type | Description |
|-------|------|-------------|
| `Owner` | `common.Address` | Owner |
| `DefaultFee` | `*big.Int` | Default fee in PPM (1_000_000 = 100%) |

**Limiter:**

| Field | Type | Description |
|-------|------|-------------|
| `Owner` | `common.Address` | Owner |

**RelativeQuoter:**

| Field | Type | Description |
|-------|------|-------------|
| `Owner` | `common.Address` | Owner |

**ProtocolFeeController:**

| Field | Type | Description |
|-------|------|-------------|
| `Owner` | `common.Address` | Owner |
| `InitialFee` | `*big.Int` | Initial protocol fee in PPM |
| `InitialRecipient` | `common.Address` | Initial fee recipient |

## Gas Limits

| Constant | Value | Used For |
|----------|-------|----------|
| `erc1967factory.GasLimit` | 1,000,000 | Deploying the factory |
| `giftabletoken.ImplGasLimit` | 2,000,000 | Deploying GiftableToken implementation |
| `swappool.ImplGasLimit` | 2,000,000 | Deploying SwapPool implementation |
| `limiter.ImplGasLimit` | 1,000,000 | Deploying Limiter implementation |
| `feepolicy.ImplGasLimit` | 1,000,000 | Deploying FeePolicy implementation |
| `relativequoter.ImplGasLimit` | 1,000,000 | Deploying RelativeQuoter implementation |
| `protocolfeecontroller.ImplGasLimit` | 1,000,000 | Deploying ProtocolFeeController implementation |
| `decimalquoter.GasLimit` | 1,000,000 | Deploying DecimalQuoter |
| `publish.ProxyGasLimit` | 500,000 | Any `deployAndCall` / `deployDeterministicAndCall` |
