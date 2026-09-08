package main

import (
	"bytes"
	"context"
	"errors"
	"strings"
	"testing"

	"github.com/ethereum/go-ethereum/common"

	"github.com/cosmo-local-credit/protocol/pkg/publish/contracts/oraclerelay"
)

type fakeCodeReader struct {
	code map[common.Address][]byte
	err  error
}

func (f fakeCodeReader) CodeAt(_ context.Context, address common.Address) ([]byte, error) {
	if f.err != nil {
		return nil, f.err
	}
	return f.code[address], nil
}

func TestParseFlagsPoolQuoterHasNoImplicitDefault(t *testing.T) {
	t.Setenv("POOL_QUOTER", "")
	cfg, err := parseFlags([]string{
		"--contract", "swappool",
		"--rpc-url", "http://localhost:8545",
		"--chain-id", "1",
		"--private-key", strings.Repeat("1", 64),
	})
	if err != nil {
		t.Fatalf("parseFlags() error = %v", err)
	}
	if cfg.PoolQuoter != "" {
		t.Fatalf("PoolQuoter = %q, want empty", cfg.PoolQuoter)
	}
}

func TestResolveAdminRejectsZeroAddress(t *testing.T) {
	owner := common.HexToAddress("0x1000000000000000000000000000000000000001")
	_, err := resolveAdmin(config{
		Contract: "swappool",
		Admin:    common.Address{}.Hex(),
	}, owner)
	if err == nil || !strings.Contains(err.Error(), "must not be the zero address") {
		t.Fatalf("resolveAdmin() error = %v, want zero-address error", err)
	}
}

func TestRequireCode(t *testing.T) {
	ctx := context.Background()
	contract := common.HexToAddress("0x2000000000000000000000000000000000000002")

	if err := requireCode(ctx, fakeCodeReader{}, "implementation", common.Address{}); err == nil {
		t.Fatal("requireCode() accepted zero address")
	}
	if err := requireCode(ctx, fakeCodeReader{code: map[common.Address][]byte{}}, "implementation", contract); err == nil || !strings.Contains(err.Error(), "has no code") {
		t.Fatalf("requireCode() error = %v, want no-code error", err)
	}
	rpcErr := errors.New("rpc unavailable")
	if err := requireCode(ctx, fakeCodeReader{err: rpcErr}, "implementation", contract); !errors.Is(err, rpcErr) {
		t.Fatalf("requireCode() error = %v, want wrapped RPC error", err)
	}
	if err := requireCode(ctx, fakeCodeReader{code: map[common.Address][]byte{contract: {0x60, 0x00}}}, "implementation", contract); err != nil {
		t.Fatalf("requireCode() error = %v", err)
	}
}

func TestValidatePoolDependencies(t *testing.T) {
	addresses := []common.Address{
		common.HexToAddress("0x3000000000000000000000000000000000000003"),
		common.HexToAddress("0x4000000000000000000000000000000000000004"),
		common.HexToAddress("0x5000000000000000000000000000000000000005"),
		common.HexToAddress("0x6000000000000000000000000000000000000006"),
		common.HexToAddress("0x7000000000000000000000000000000000000007"),
	}
	cfg := config{
		PoolFeePolicy:             addresses[0].Hex(),
		PoolTokenLimiter:          addresses[1].Hex(),
		PoolProtocolFeeController: addresses[2].Hex(),
		PoolQuoter:                addresses[3].Hex(),
		PoolTokenRegistry:         addresses[4].Hex(),
	}
	code := make(map[common.Address][]byte)
	for _, address := range addresses {
		code[address] = []byte{0x60, 0x00}
	}

	if err := validatePoolDependencies(context.Background(), fakeCodeReader{code: code}, cfg); err != nil {
		t.Fatalf("validatePoolDependencies() error = %v", err)
	}

	cfg.PoolQuoter = "relative"
	if err := validatePoolDependencies(context.Background(), fakeCodeReader{code: code}, cfg); err == nil || !strings.Contains(err.Error(), "pool-quoter") {
		t.Fatalf("validatePoolDependencies() error = %v, want quoter-address error", err)
	}

	cfg.PoolQuoter = addresses[3].Hex()
	delete(code, addresses[1])
	if err := validatePoolDependencies(context.Background(), fakeCodeReader{code: code}, cfg); err == nil || !strings.Contains(err.Error(), "pool-token-limiter") {
		t.Fatalf("validatePoolDependencies() error = %v, want limiter no-code error", err)
	}
}

func TestRunOneProxiedEncodesBeforeNetworkAccess(t *testing.T) {
	encodeErr := errors.New("invalid initializer configuration")
	err := runOneProxied(
		context.Background(),
		nil,
		config{},
		report{},
		"test",
		"Test",
		nil,
		0,
		common.HexToAddress("0x8000000000000000000000000000000000000008"),
		func() ([]byte, error) { return nil, encodeErr },
	)
	if !errors.Is(err, encodeErr) {
		t.Fatalf("runOneProxied() error = %v, want initializer error before network access", err)
	}
}

func TestOracleRelayInitArgsRequiresWriter(t *testing.T) {
	owner := common.HexToAddress("0x9000000000000000000000000000000000000009")

	if _, err := oracleRelayInitArgs(config{}, owner); err == nil || !strings.Contains(err.Error(), "oracle-relay-writer is required") {
		t.Fatalf("oracleRelayInitArgs() error = %v, want required-writer error", err)
	}

	_, err := oracleRelayInitArgs(config{OracleRelayWriter: common.Address{}.Hex()}, owner)
	if err == nil || !strings.Contains(err.Error(), "must not be the zero address") {
		t.Fatalf("oracleRelayInitArgs() error = %v, want zero-address error", err)
	}

	if _, err := oracleRelayInitArgs(config{OracleRelayWriter: "not-an-address"}, owner); err == nil {
		t.Fatal("oracleRelayInitArgs() accepted a malformed writer address")
	}

	if _, err := oracleRelayInitArgs(config{
		OracleRelayWriter:   "0x000000000000000000000000000000000000dEaD",
		OracleRelayDecimals: 256,
	}, owner); err == nil || !strings.Contains(err.Error(), "oracle-relay-decimals") {
		t.Fatalf("oracleRelayInitArgs() error = %v, want decimals-range error", err)
	}
}

func TestOracleRelayInitArgsNeverDefaultsWriterToOwner(t *testing.T) {
	owner := common.HexToAddress("0x9000000000000000000000000000000000000009")
	writer := common.HexToAddress("0x000000000000000000000000000000000000dEaD")

	args, err := oracleRelayInitArgs(config{
		OracleRelayWriter:      writer.Hex(),
		OracleRelayDecimals:    8,
		OracleRelayDescription: "KES / USD",
	}, owner)
	if err != nil {
		t.Fatalf("oracleRelayInitArgs() error = %v", err)
	}
	if args.Owner != owner || args.Writer != writer {
		t.Fatalf("oracleRelayInitArgs() = %+v, want owner %s writer %s", args, owner.Hex(), writer.Hex())
	}
	if args.Decimals != 8 || args.Description != "KES / USD" {
		t.Fatalf("oracleRelayInitArgs() metadata = (%d, %q)", args.Decimals, args.Description)
	}
}

func TestEncodeInitForOracleRelay(t *testing.T) {
	owner := common.HexToAddress("0x9000000000000000000000000000000000000009")
	writer := common.HexToAddress("0x000000000000000000000000000000000000dEaD")

	if _, err := encodeInitFor("oraclerelay", config{}, owner, owner, owner, owner, owner, common.Address{}); err == nil {
		t.Fatal("encodeInitFor() encoded oraclerelay without a writer")
	}

	cfg := config{
		OracleRelayWriter:      writer.Hex(),
		OracleRelayDecimals:    8,
		OracleRelayDescription: "KES / USD",
	}
	data, err := encodeInitFor("oraclerelay", cfg, owner, owner, owner, owner, owner, common.Address{})
	if err != nil {
		t.Fatalf("encodeInitFor() error = %v", err)
	}

	want, err := oraclerelay.EncodeInit(oraclerelay.InitArgs{
		Owner:       owner,
		Writer:      writer,
		Decimals:    8,
		Description: "KES / USD",
	})
	if err != nil {
		t.Fatalf("EncodeInit() error = %v", err)
	}
	if !bytes.Equal(data, want) {
		t.Fatalf("encodeInitFor() = %x, want %x", data, want)
	}
}

func TestContractBytecodeOracleRelay(t *testing.T) {
	code, gas, err := contractBytecode("oraclerelay", common.Address{})
	if err != nil {
		t.Fatalf("contractBytecode() error = %v", err)
	}
	if len(code) == 0 {
		t.Fatal("contractBytecode() returned empty OracleRelay bytecode")
	}
	if gas != oraclerelay.ImplGasLimit {
		t.Fatalf("contractBytecode() gas = %d, want %d", gas, oraclerelay.ImplGasLimit)
	}
}

func TestParseFlagsOracleRelayWriterHasNoImplicitDefault(t *testing.T) {
	t.Setenv("ORACLE_RELAY_WRITER", "")
	cfg, err := parseFlags([]string{
		"--contract", "oraclerelay",
		"--rpc-url", "http://localhost:8545",
		"--chain-id", "1",
		"--private-key", strings.Repeat("1", 64),
	})
	if err != nil {
		t.Fatalf("parseFlags() error = %v", err)
	}
	if cfg.OracleRelayWriter != "" {
		t.Fatalf("OracleRelayWriter = %q, want empty", cfg.OracleRelayWriter)
	}
	if cfg.OracleRelayDecimals != 8 {
		t.Fatalf("OracleRelayDecimals = %d, want 8", cfg.OracleRelayDecimals)
	}
}
