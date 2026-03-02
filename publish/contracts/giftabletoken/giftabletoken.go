package giftabletoken

import (
	_ "embed"
	"math/big"

	"github.com/ethereum/go-ethereum/common"
	"github.com/lmittmann/w3"

	"github.com/cosmo-local-credit/protocol/publish"
)

const (
	name            = "GiftableToken"
	version         = "0.1.0"
	license         = "AGPL-3.0"
	solidityVersion = "0.8.30"
	evmFork         = "shanghai"
	ImplGasLimit    = 2_000_000
)

//go:embed GiftableToken.bin
var bytecodeHex string

var funcInitialize = w3.MustNewFunc(
	"initialize(string,string,uint8,address,uint256)", "",
)

type InitArgs struct {
	Name      string
	Symbol    string
	Decimals  uint8
	Owner     common.Address
	ExpiresAt *big.Int
}

func Name() string            { return name }
func Version() string         { return version }
func License() string         { return license }
func SolidityVersion() string { return solidityVersion }
func EVMFork() string         { return evmFork }
func MaxGasLimit() uint64     { return ImplGasLimit }

func Bytecode() []byte {
	return publish.MustHexDecode(bytecodeHex)
}

func EncodeInit(args InitArgs) ([]byte, error) {
	return funcInitialize.EncodeArgs(args.Name, args.Symbol, args.Decimals, args.Owner, args.ExpiresAt)
}
