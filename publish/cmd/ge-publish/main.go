package main

import (
	"context"
	"crypto/ecdsa"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"math/big"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/crypto"

	"github.com/cosmo-local-credit/protocol/publish"
	"github.com/cosmo-local-credit/protocol/publish/contracts/accountsindex"
	"github.com/cosmo-local-credit/protocol/publish/contracts/cat"
	"github.com/cosmo-local-credit/protocol/publish/contracts/contractregistry"
	"github.com/cosmo-local-credit/protocol/publish/contracts/decimalquoter"
	"github.com/cosmo-local-credit/protocol/publish/contracts/erc1967factory"
	"github.com/cosmo-local-credit/protocol/publish/contracts/ethfaucet"
	"github.com/cosmo-local-credit/protocol/publish/contracts/feepolicy"
	"github.com/cosmo-local-credit/protocol/publish/contracts/giftabletoken"
	"github.com/cosmo-local-credit/protocol/publish/contracts/limiter"
	"github.com/cosmo-local-credit/protocol/publish/contracts/oraclequoter"
	"github.com/cosmo-local-credit/protocol/publish/contracts/periodsimple"
	"github.com/cosmo-local-credit/protocol/publish/contracts/protocolfeecontroller"
	"github.com/cosmo-local-credit/protocol/publish/contracts/relativequoter"
	"github.com/cosmo-local-credit/protocol/publish/contracts/splitter"
	"github.com/cosmo-local-credit/protocol/publish/contracts/swappool"
	"github.com/cosmo-local-credit/protocol/publish/contracts/tokenuniquesymbolindex"
)

type config struct {
	Contract                  string
	RPCURL                    string
	ChainID                   int64
	PrivateKey                string
	PublicAddress             string
	Owner                     string
	Admin                     string
	GasFeeCap                 int64
	GasTipCap                 int64
	TimeoutSeconds            int
	FactoryAddress            string
	FactorySaltSuffix         string
	BaseCurrency              string
	PoolQuoter                string
	PoolTokenRegistry         string
	PoolFeeAddress            string
	PoolName                  string
	PoolSymbol                string
	PoolDecimals              uint
	PoolFeesDecoupled         bool
	PoolFeePolicy             string
	PoolTokenLimiter          string
	PoolProtocolFeeController string
	TokenName                 string
	TokenSymbol               string
	TokenDecimals             uint
	TokenExpiresAt            uint64
	FeePolicyDefault          int64
	ProtocolFee               int64
	ProtocolRecipient         string
	FaucetAmount              uint64
	PeriodPoker               string
	RegistryIDs               string
	TokenIndexTokens          string
	TokenIndexSymbols         string
	SplitterAccounts          string
	SplitterAllocs            string
}

type report struct {
	Factory         string            `json:"factory,omitempty"`
	DecimalQuoter   string            `json:"decimal_quoter,omitempty"`
	Implementations map[string]string `json:"implementations,omitempty"`
	Proxies         map[string]string `json:"proxies,omitempty"`
}

func main() {
	if len(os.Args) < 2 || os.Args[1] != "publish-one" {
		printUsage()
		os.Exit(2)
	}

	cfg, err := parseFlags(os.Args[2:])
	if err != nil {
		exitErr(err)
	}

	if err := run(cfg); err != nil {
		exitErr(err)
	}
}

func printUsage() {
	fmt.Println("Usage:")
	fmt.Println("  ge-publish publish-one --contract <name> [flags]")
	fmt.Println()
	fmt.Println("Core flags/env: --rpc-url(RPC_URL) --chain-id(CHAIN_ID) --private-key(PRIVATE_KEY) [--public-address(PUBLIC_ADDRESS)]")
}

func parseFlags(args []string) (config, error) {
	cfg := config{
		Contract:                  envOr("CONTRACT", ""),
		RPCURL:                    envOr("RPC_URL", ""),
		ChainID:                   envInt64("CHAIN_ID", 0),
		PrivateKey:                envOr("PRIVATE_KEY", ""),
		PublicAddress:             envOr("PUBLIC_ADDRESS", ""),
		Owner:                     envOr("OWNER", ""),
		Admin:                     envOr("ADMIN", ""),
		GasFeeCap:                 envInt64("GAS_FEE_CAP", 2_000_000_000),
		GasTipCap:                 envInt64("GAS_TIP_CAP", 1_000_000_000),
		TimeoutSeconds:            600,
		FactoryAddress:            envOr("FACTORY_ADDRESS", ""),
		FactorySaltSuffix:         envOr("FACTORY_SALT_SUFFIX", ""),
		BaseCurrency:              envOr("BASE_CURRENCY", ""),
		PoolQuoter:                envOr("POOL_QUOTER", "relative"),
		PoolTokenRegistry:         envOr("POOL_TOKEN_REGISTRY", ""),
		PoolFeeAddress:            envOr("POOL_FEE_ADDRESS", ""),
		PoolName:                  envOr("POOL_NAME", "Sarafu Pool"),
		PoolSymbol:                envOr("POOL_SYMBOL", "SRFp"),
		PoolDecimals:              uint(envInt64("POOL_DECIMALS", 6)),
		PoolFeesDecoupled:         false,
		PoolFeePolicy:             envOr("POOL_FEE_POLICY", ""),
		PoolTokenLimiter:          envOr("POOL_TOKEN_LIMITER", ""),
		PoolProtocolFeeController: envOr("POOL_PROTOCOL_FEE_CONTROLLER", ""),
		TokenName:                 envOr("TOKEN_NAME", "Sarafu"),
		TokenSymbol:               envOr("TOKEN_SYMBOL", "SRF"),
		TokenDecimals:             uint(envInt64("TOKEN_DECIMALS", 6)),
		TokenExpiresAt:            uint64(envInt64("TOKEN_EXPIRES_AT", 0)),
		FeePolicyDefault:          envInt64("FEE_POLICY_DEFAULT", 5000),
		ProtocolFee:               envInt64("PROTOCOL_FEE", 1000),
		ProtocolRecipient:         envOr("PROTOCOL_RECIPIENT", ""),
		FaucetAmount:              uint64(envInt64("FAUCET_AMOUNT", 0)),
		PeriodPoker:               envOr("PERIOD_POKER", ""),
		RegistryIDs:               envOr("REGISTRY_IDENTIFIERS", ""),
		TokenIndexTokens:          envOr("TOKEN_INDEX_TOKENS", ""),
		TokenIndexSymbols:         envOr("TOKEN_INDEX_SYMBOLS", ""),
		SplitterAccounts:          envOr("SPLITTER_ACCOUNTS", ""),
		SplitterAllocs:            envOr("SPLITTER_ALLOCATIONS", ""),
	}

	fs := flag.NewFlagSet("publish-one", flag.ContinueOnError)
	fs.StringVar(&cfg.Contract, "contract", cfg.Contract, "single contract to deploy (publish-one only)")
	fs.StringVar(&cfg.RPCURL, "rpc-url", cfg.RPCURL, "RPC URL")
	fs.Int64Var(&cfg.ChainID, "chain-id", cfg.ChainID, "chain id")
	fs.StringVar(&cfg.PrivateKey, "private-key", cfg.PrivateKey, "private key hex")
	fs.StringVar(&cfg.PublicAddress, "public-address", cfg.PublicAddress, "public address for validation")
	fs.StringVar(&cfg.Owner, "owner", cfg.Owner, "owner address (default deployer)")
	fs.StringVar(&cfg.Admin, "admin", cfg.Admin, "proxy admin (default owner)")
	fs.Int64Var(&cfg.GasFeeCap, "gas-fee-cap", cfg.GasFeeCap, "EIP-1559 fee cap")
	fs.Int64Var(&cfg.GasTipCap, "gas-tip-cap", cfg.GasTipCap, "EIP-1559 tip cap")
	fs.IntVar(&cfg.TimeoutSeconds, "timeout-seconds", cfg.TimeoutSeconds, "timeout in seconds")
	fs.StringVar(&cfg.FactoryAddress, "factory-address", cfg.FactoryAddress, "existing ERC1967Factory address")
	fs.StringVar(&cfg.FactorySaltSuffix, "factory-salt-suffix", cfg.FactorySaltSuffix, "optional suffix appended to factory Name() before salt derivation")
	fs.StringVar(&cfg.BaseCurrency, "base-currency", cfg.BaseCurrency, "base currency for OracleQuoter")
	fs.StringVar(&cfg.PoolQuoter, "pool-quoter", cfg.PoolQuoter, "relative|oracle")
	fs.StringVar(&cfg.PoolTokenRegistry, "pool-token-registry", cfg.PoolTokenRegistry, "override token registry")
	fs.StringVar(&cfg.PoolFeeAddress, "pool-fee-address", cfg.PoolFeeAddress, "pool fee address")
	fs.StringVar(&cfg.PoolName, "pool-name", cfg.PoolName, "pool name")
	fs.StringVar(&cfg.PoolSymbol, "pool-symbol", cfg.PoolSymbol, "pool symbol")
	fs.UintVar(&cfg.PoolDecimals, "pool-decimals", cfg.PoolDecimals, "pool decimals")
	fs.BoolVar(&cfg.PoolFeesDecoupled, "pool-fees-decoupled", cfg.PoolFeesDecoupled, "pool fees decoupled")
	fs.StringVar(&cfg.PoolFeePolicy, "pool-fee-policy", cfg.PoolFeePolicy, "existing FeePolicy proxy for publish-one swappool")
	fs.StringVar(&cfg.PoolTokenLimiter, "pool-token-limiter", cfg.PoolTokenLimiter, "existing Limiter proxy for publish-one swappool")
	fs.StringVar(&cfg.PoolProtocolFeeController, "pool-protocol-fee-controller", cfg.PoolProtocolFeeController, "existing ProtocolFeeController proxy for publish-one swappool")
	fs.StringVar(&cfg.TokenName, "token-name", cfg.TokenName, "token name")
	fs.StringVar(&cfg.TokenSymbol, "token-symbol", cfg.TokenSymbol, "token symbol")
	fs.UintVar(&cfg.TokenDecimals, "token-decimals", cfg.TokenDecimals, "token decimals")
	fs.Uint64Var(&cfg.TokenExpiresAt, "token-expires-at", cfg.TokenExpiresAt, "token expiry timestamp")
	fs.Int64Var(&cfg.FeePolicyDefault, "fee-policy-default", cfg.FeePolicyDefault, "fee policy default")
	fs.Int64Var(&cfg.ProtocolFee, "protocol-fee", cfg.ProtocolFee, "protocol fee")
	fs.StringVar(&cfg.ProtocolRecipient, "protocol-recipient", cfg.ProtocolRecipient, "protocol recipient")
	fs.Uint64Var(&cfg.FaucetAmount, "faucet-amount", cfg.FaucetAmount, "faucet amount")
	fs.StringVar(&cfg.PeriodPoker, "period-poker", cfg.PeriodPoker, "period poker address")
	fs.StringVar(&cfg.RegistryIDs, "registry-identifiers", cfg.RegistryIDs, "comma-separated identifiers")
	fs.StringVar(&cfg.TokenIndexTokens, "token-index-tokens", cfg.TokenIndexTokens, "comma-separated token addresses")
	fs.StringVar(&cfg.TokenIndexSymbols, "token-index-symbols", cfg.TokenIndexSymbols, "comma-separated symbols")
	fs.StringVar(&cfg.SplitterAccounts, "splitter-accounts", cfg.SplitterAccounts, "comma-separated splitter accounts")
	fs.StringVar(&cfg.SplitterAllocs, "splitter-allocations", cfg.SplitterAllocs, "comma-separated splitter allocations")

	if err := fs.Parse(args); err != nil {
		return config{}, err
	}

	if cfg.RPCURL == "" || cfg.ChainID == 0 || cfg.PrivateKey == "" {
		return config{}, errors.New("rpc-url, chain-id and private-key are required")
	}
	if strings.TrimSpace(cfg.Contract) == "" {
		return config{}, errors.New("--contract is required for publish-one")
	}

	return cfg, nil
}

func run(cfg config) error {
	key, deployerAddr, err := parsePrivateKey(cfg.PrivateKey)
	if err != nil {
		return err
	}

	if cfg.PublicAddress != "" {
		pub, err := parseAddress(cfg.PublicAddress)
		if err != nil {
			return err
		}
		if !strings.EqualFold(pub.Hex(), deployerAddr.Hex()) {
			return fmt.Errorf("public-address %s does not match private key address %s", pub.Hex(), deployerAddr.Hex())
		}
	}

	owner := deployerAddr
	if cfg.Owner != "" {
		owner, err = parseAddress(cfg.Owner)
		if err != nil {
			return err
		}
	}

	admin := owner
	if cfg.Admin != "" {
		admin, err = parseAddress(cfg.Admin)
		if err != nil {
			return err
		}
	}

	feeAddress := owner
	if cfg.PoolFeeAddress != "" {
		feeAddress, err = parseAddress(cfg.PoolFeeAddress)
		if err != nil {
			return err
		}
	}

	protocolRecipient := owner
	if cfg.ProtocolRecipient != "" {
		protocolRecipient, err = parseAddress(cfg.ProtocolRecipient)
		if err != nil {
			return err
		}
	}

	periodPoker := owner
	if cfg.PeriodPoker != "" {
		periodPoker, err = parseAddress(cfg.PeriodPoker)
		if err != nil {
			return err
		}
	}

	baseCurrency := common.Address{}
	if cfg.BaseCurrency != "" {
		baseCurrency, err = parseAddress(cfg.BaseCurrency)
		if err != nil {
			return err
		}
	}

	d, err := publish.NewDeployer(cfg.RPCURL, cfg.ChainID, key, big.NewInt(cfg.GasFeeCap), big.NewInt(cfg.GasTipCap))
	if err != nil {
		return err
	}
	defer d.Close()

	ctx, cancel := context.WithTimeout(context.Background(), time.Duration(cfg.TimeoutSeconds)*time.Second)
	defer cancel()

	return runOne(ctx, d, cfg, owner, admin, feeAddress, protocolRecipient, periodPoker, baseCurrency)
}

func runOne(ctx context.Context, d *publish.Deployer, cfg config, owner, admin, feeAddress, protocolRecipient, periodPoker, baseCurrency common.Address) error {
	contract := strings.ToLower(strings.TrimSpace(cfg.Contract))
	out := report{Implementations: map[string]string{}, Proxies: map[string]string{}}

	switch contract {
	case "erc1967factory", "factory":
		factoryAddr, err := ensureFactory(ctx, d, cfg)
		if err != nil {
			return err
		}
		out.Factory = factoryAddr.Hex()

	case "decimalquoter":
		addr, err := deployPlain(ctx, d, "DecimalQuoter", decimalquoter.Bytecode(), decimalquoter.GasLimit)
		if err != nil {
			return err
		}
		out.DecimalQuoter = addr.Hex()

	case "accountsindex":
		return runOneProxied(ctx, d, cfg, out, "accountsindex", "AccountsIndex", accountsindex.Bytecode(), accountsindex.ImplGasLimit, admin, func() ([]byte, error) {
			return accountsindex.EncodeInit(accountsindex.InitArgs{Owner: owner})
		})
	case "cat":
		return runOneProxied(ctx, d, cfg, out, "cat", "CAT", cat.Bytecode(), cat.ImplGasLimit, admin, func() ([]byte, error) {
			return cat.EncodeInit(cat.InitArgs{Owner: owner})
		})
	case "contractregistry":
		registryIDs := splitCSV(cfg.RegistryIDs)
		if len(registryIDs) == 0 {
			return errors.New("registry-identifiers is required for publish-one contractregistry")
		}
		ids := make([][]byte, len(registryIDs))
		for i, id := range registryIDs {
			ids[i] = []byte(id)
		}
		return runOneProxied(ctx, d, cfg, out, "contractregistry", "ContractRegistry", contractregistry.Bytecode(), contractregistry.ImplGasLimit, admin, func() ([]byte, error) {
			return contractregistry.EncodeInit(contractregistry.InitArgs{Owner: owner, Identifiers: ids})
		})
	case "ethfaucet":
		return runOneProxied(ctx, d, cfg, out, "ethfaucet", "EthFaucet", ethfaucet.Bytecode(), ethfaucet.ImplGasLimit, admin, func() ([]byte, error) {
			return ethfaucet.EncodeInit(ethfaucet.InitArgs{Owner: owner, Amount: new(big.Int).SetUint64(cfg.FaucetAmount)})
		})
	case "feepolicy":
		return runOneProxied(ctx, d, cfg, out, "feepolicy", "FeePolicy", feepolicy.Bytecode(), feepolicy.ImplGasLimit, admin, func() ([]byte, error) {
			return feepolicy.EncodeInit(feepolicy.InitArgs{Owner: owner, DefaultFee: big.NewInt(cfg.FeePolicyDefault)})
		})
	case "giftabletoken", "token":
		return runOneProxied(ctx, d, cfg, out, "giftabletoken", "GiftableToken", giftabletoken.Bytecode(), giftabletoken.ImplGasLimit, admin, func() ([]byte, error) {
			return giftabletoken.EncodeInit(giftabletoken.InitArgs{Name: cfg.TokenName, Symbol: cfg.TokenSymbol, Decimals: uint8(cfg.TokenDecimals), Owner: owner, ExpiresAt: new(big.Int).SetUint64(cfg.TokenExpiresAt)})
		})
	case "limiter":
		return runOneProxied(ctx, d, cfg, out, "limiter", "Limiter", limiter.Bytecode(), limiter.ImplGasLimit, admin, func() ([]byte, error) {
			return limiter.EncodeInit(limiter.InitArgs{Owner: owner})
		})
	case "oraclequoter":
		if baseCurrency == (common.Address{}) {
			return errors.New("base-currency is required for publish-one oraclequoter")
		}
		return runOneProxied(ctx, d, cfg, out, "oraclequoter", "OracleQuoter", oraclequoter.Bytecode(), oraclequoter.ImplGasLimit, admin, func() ([]byte, error) {
			return oraclequoter.EncodeInit(oraclequoter.InitArgs{Owner: owner, BaseCurrency: baseCurrency})
		})
	case "periodsimple":
		return runOneProxied(ctx, d, cfg, out, "periodsimple", "PeriodSimple", periodsimple.Bytecode(), periodsimple.ImplGasLimit, admin, func() ([]byte, error) {
			return periodsimple.EncodeInit(periodsimple.InitArgs{Owner: owner, Poker: periodPoker})
		})
	case "protocolfeecontroller", "pfc":
		return runOneProxied(ctx, d, cfg, out, "protocolfeecontroller", "ProtocolFeeController", protocolfeecontroller.Bytecode(), protocolfeecontroller.ImplGasLimit, admin, func() ([]byte, error) {
			return protocolfeecontroller.EncodeInit(protocolfeecontroller.InitArgs{Owner: owner, InitialFee: big.NewInt(cfg.ProtocolFee), InitialRecipient: protocolRecipient})
		})
	case "relativequoter":
		return runOneProxied(ctx, d, cfg, out, "relativequoter", "RelativeQuoter", relativequoter.Bytecode(), relativequoter.ImplGasLimit, admin, func() ([]byte, error) {
			return relativequoter.EncodeInit(relativequoter.InitArgs{Owner: owner})
		})
	case "splitter":
		splitAccounts, err := parseAddressList(cfg.SplitterAccounts)
		if err != nil {
			return err
		}
		splitAllocs, err := parseUint32List(cfg.SplitterAllocs)
		if err != nil {
			return err
		}
		if len(splitAccounts) == 0 || len(splitAccounts) != len(splitAllocs) {
			return errors.New("splitter-accounts and splitter-allocations are required and must have equal length")
		}
		return runOneProxied(ctx, d, cfg, out, "splitter", "Splitter", splitter.Bytecode(), splitter.ImplGasLimit, admin, func() ([]byte, error) {
			return splitter.EncodeInit(splitter.InitArgs{Owner: owner, Accounts: splitAccounts, PercentAllocations: splitAllocs})
		})
	case "tokenuniquesymbolindex", "tokenindex":
		indexTokens, err := parseAddressList(cfg.TokenIndexTokens)
		if err != nil {
			return err
		}
		indexSymbols := splitCSV(cfg.TokenIndexSymbols)
		if len(indexTokens) > 0 && len(indexSymbols) > 0 && len(indexTokens) != len(indexSymbols) {
			return fmt.Errorf("token-index lengths mismatch: %d != %d", len(indexTokens), len(indexSymbols))
		}
		initialSymbols := make([][]byte, len(indexSymbols))
		for i, s := range indexSymbols {
			initialSymbols[i] = []byte(s)
		}
		return runOneProxied(ctx, d, cfg, out, "tokenuniquesymbolindex", "TokenUniqueSymbolIndex", tokenuniquesymbolindex.Bytecode(), tokenuniquesymbolindex.ImplGasLimit, admin, func() ([]byte, error) {
			return tokenuniquesymbolindex.EncodeInit(tokenuniquesymbolindex.InitArgs{Owner: owner, InitialTokens: indexTokens, InitialSymbols: initialSymbols})
		})
	case "swappool":
		factoryAddr, err := ensureFactory(ctx, d, cfg)
		if err != nil {
			return err
		}
		feePolicy, err := parseAddress(cfg.PoolFeePolicy)
		if err != nil {
			return fmt.Errorf("pool-fee-policy is required for publish-one swappool: %w", err)
		}
		tokenLimiter, err := parseAddress(cfg.PoolTokenLimiter)
		if err != nil {
			return fmt.Errorf("pool-token-limiter is required for publish-one swappool: %w", err)
		}
		pfc, err := parseAddress(cfg.PoolProtocolFeeController)
		if err != nil {
			return fmt.Errorf("pool-protocol-fee-controller is required for publish-one swappool: %w", err)
		}

		quoterAddress := common.Address{}
		if strings.EqualFold(cfg.PoolQuoter, "oracle") {
			quoterAddress, err = parseAddress(cfg.BaseCurrency)
			if err != nil {
				return fmt.Errorf("for publish-one swappool, provide quoter proxy via pool-quoter='oracle' and set base-currency to quoter address is not supported")
			}
			_ = quoterAddress
		}
		if cfg.PoolQuoter != "" && cfg.PoolQuoter != "relative" && cfg.PoolQuoter != "oracle" {
			return errors.New("pool-quoter must be relative|oracle")
		}
		if !common.IsHexAddress(cfg.PoolQuoter) {
			return errors.New("for publish-one swappool, pass quoter proxy address in --pool-quoter")
		}
		quoterAddress, err = parseAddress(cfg.PoolQuoter)
		if err != nil {
			return err
		}

		tokenRegistry := common.Address{}
		if cfg.PoolTokenRegistry != "" {
			tokenRegistry, err = parseAddress(cfg.PoolTokenRegistry)
			if err != nil {
				return err
			}
		}

		implAddr, proxyAddr, err := deployProxied(ctx, d, factoryAddr, admin, "SwapPool", swappool.Bytecode(), swappool.ImplGasLimit, func() ([]byte, error) {
			return swappool.EncodeInit(swappool.InitArgs{
				Name:                  cfg.PoolName,
				Symbol:                cfg.PoolSymbol,
				Decimals:              uint8(cfg.PoolDecimals),
				Owner:                 owner,
				FeePolicy:             feePolicy,
				FeeAddress:            feeAddress,
				TokenRegistry:         tokenRegistry,
				TokenLimiter:          tokenLimiter,
				Quoter:                quoterAddress,
				FeesDecoupled:         cfg.PoolFeesDecoupled,
				ProtocolFeeController: pfc,
			})
		})
		if err != nil {
			return err
		}
		out.Factory = factoryAddr.Hex()
		out.Implementations["swappool"] = implAddr.Hex()
		out.Proxies["swappool"] = proxyAddr.Hex()

	default:
		return fmt.Errorf("unsupported contract: %s", cfg.Contract)
	}

	blob, err := json.MarshalIndent(out, "", "  ")
	if err != nil {
		return err
	}
	fmt.Println(string(blob))
	return nil
}

func runOneProxied(ctx context.Context, d *publish.Deployer, cfg config, out report, key, name string, bytecode []byte, gas uint64, admin common.Address, initFn func() ([]byte, error)) error {
	factoryAddr, err := ensureFactory(ctx, d, cfg)
	if err != nil {
		return err
	}
	implAddr, proxyAddr, err := deployProxied(ctx, d, factoryAddr, admin, name, bytecode, gas, initFn)
	if err != nil {
		return err
	}
	out.Factory = factoryAddr.Hex()
	out.Implementations[key] = implAddr.Hex()
	out.Proxies[key] = proxyAddr.Hex()
	blob, err := json.MarshalIndent(out, "", "  ")
	if err != nil {
		return err
	}
	fmt.Println(string(blob))
	return nil
}

func ensureFactory(ctx context.Context, d *publish.Deployer, cfg config) (common.Address, error) {
	if cfg.FactoryAddress != "" {
		addr, err := parseAddress(cfg.FactoryAddress)
		if err != nil {
			return common.Address{}, err
		}
		code, err := d.CodeAt(ctx, addr)
		if err != nil {
			return common.Address{}, err
		}
		if len(code) == 0 {
			return common.Address{}, fmt.Errorf("factory address %s has no code", addr.Hex())
		}
		return addr, nil
	}

	saltName := erc1967factory.Name()
	if strings.TrimSpace(cfg.FactorySaltSuffix) != "" {
		saltName = saltName + ":" + strings.TrimSpace(cfg.FactorySaltSuffix)
	}
	salt := publish.GenerateSalt(d.Address(), saltName)
	predicted := publish.PredictCreate2Address(publish.ArachnidCreate2Factory, salt, erc1967factory.Bytecode())
	code, err := d.CodeAt(ctx, predicted)
	if err != nil {
		return common.Address{}, err
	}
	if len(code) > 0 {
		return predicted, nil
	}

	result, err := d.DeployDeterministicViaArachnid(ctx, salt, erc1967factory.Bytecode(), erc1967factory.GasLimit)
	if err != nil {
		return common.Address{}, err
	}
	receipt, err := d.WaitForReceipt(ctx, result.TxHash)
	if err != nil {
		return common.Address{}, err
	}
	if receipt.Status != 1 {
		return common.Address{}, fmt.Errorf("deterministic factory deployment failed: %s", receipt.TxHash.Hex())
	}
	return result.ContractAddress, nil
}

func deployPlain(ctx context.Context, d *publish.Deployer, name string, bytecode []byte, gasLimit uint64) (common.Address, error) {
	result, err := d.DeployImplementation(ctx, bytecode, gasLimit)
	if err != nil {
		return common.Address{}, fmt.Errorf("deploy %s implementation: %w", name, err)
	}
	receipt, err := d.WaitForReceipt(ctx, result.TxHash)
	if err != nil {
		return common.Address{}, fmt.Errorf("wait %s implementation: %w", name, err)
	}
	if receipt.Status != 1 {
		return common.Address{}, fmt.Errorf("%s implementation deployment failed: %s", name, receipt.TxHash.Hex())
	}
	return result.ContractAddress, nil
}

func deployProxied(ctx context.Context, d *publish.Deployer, factory, admin common.Address, name string, bytecode []byte, implGasLimit uint64, initFn func() ([]byte, error)) (common.Address, common.Address, error) {
	implAddr, err := deployPlain(ctx, d, name, bytecode, implGasLimit)
	if err != nil {
		return common.Address{}, common.Address{}, err
	}

	initData, err := initFn()
	if err != nil {
		return common.Address{}, common.Address{}, fmt.Errorf("encode %s init: %w", name, err)
	}

	txHash, err := d.DeployProxy(ctx, factory, implAddr, admin, initData, publish.ProxyGasLimit)
	if err != nil {
		return common.Address{}, common.Address{}, fmt.Errorf("deploy %s proxy: %w", name, err)
	}
	receipt, err := d.WaitForReceipt(ctx, txHash)
	if err != nil {
		return common.Address{}, common.Address{}, fmt.Errorf("wait %s proxy: %w", name, err)
	}
	if receipt.Status != 1 {
		return common.Address{}, common.Address{}, fmt.Errorf("%s proxy deployment failed: %s", name, receipt.TxHash.Hex())
	}

	proxyAddr, err := publish.ProxyAddressFromReceipt(receipt)
	if err != nil {
		return common.Address{}, common.Address{}, err
	}

	return implAddr, proxyAddr, nil
}

func parsePrivateKey(v string) (*ecdsa.PrivateKey, common.Address, error) {
	v = strings.TrimPrefix(strings.TrimSpace(v), "0x")
	key, err := crypto.HexToECDSA(v)
	if err != nil {
		return nil, common.Address{}, fmt.Errorf("parse private key: %w", err)
	}
	return key, crypto.PubkeyToAddress(key.PublicKey), nil
}

func parseAddress(v string) (common.Address, error) {
	if !common.IsHexAddress(v) {
		return common.Address{}, fmt.Errorf("invalid address: %s", v)
	}
	return common.HexToAddress(v), nil
}

func parseAddressList(input string) ([]common.Address, error) {
	parts := splitCSV(input)
	if len(parts) == 0 {
		return nil, nil
	}
	out := make([]common.Address, len(parts))
	for i, part := range parts {
		addr, err := parseAddress(part)
		if err != nil {
			return nil, fmt.Errorf("address[%d]: %w", i, err)
		}
		out[i] = addr
	}
	return out, nil
}

func parseUint32List(input string) ([]uint32, error) {
	parts := splitCSV(input)
	if len(parts) == 0 {
		return nil, nil
	}
	out := make([]uint32, len(parts))
	for i, part := range parts {
		n, err := strconv.ParseUint(part, 10, 32)
		if err != nil {
			return nil, fmt.Errorf("allocation[%d]: %w", i, err)
		}
		out[i] = uint32(n)
	}
	return out, nil
}

func splitCSV(v string) []string {
	v = strings.TrimSpace(v)
	if v == "" {
		return nil
	}
	parts := strings.Split(v, ",")
	out := make([]string, 0, len(parts))
	for _, p := range parts {
		p = strings.TrimSpace(p)
		if p != "" {
			out = append(out, p)
		}
	}
	return out
}

func envOr(key, fallback string) string {
	v := strings.TrimSpace(os.Getenv(key))
	if v == "" {
		return fallback
	}
	return v
}

func envInt64(key string, fallback int64) int64 {
	v := strings.TrimSpace(os.Getenv(key))
	if v == "" {
		return fallback
	}
	n, err := strconv.ParseInt(v, 10, 64)
	if err != nil {
		return fallback
	}
	return n
}

func exitErr(err error) {
	fmt.Fprintf(os.Stderr, "error: %v\n", err)
	os.Exit(1)
}
