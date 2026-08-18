package main

import (
	"context"
	"errors"
	"strings"
	"testing"

	"github.com/ethereum/go-ethereum/common"
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
