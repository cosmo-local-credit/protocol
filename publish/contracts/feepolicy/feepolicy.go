package feepolicy

import (
	_ "embed"
	"math/big"

	"github.com/ethereum/go-ethereum/common"
	"github.com/lmittmann/w3"

	"github.com/cosmo-local-credit/protocol/publish"
)

const ImplGasLimit uint64 = 1_000_000

//go:embed FeePolicy.bin
var bytecodeHex string

var funcInitialize = w3.MustNewFunc(
	"initialize(address,uint256)", "",
)

type InitArgs struct {
	Owner      common.Address
	DefaultFee *big.Int
}

func Bytecode() []byte {
	return publish.MustHexDecode(bytecodeHex)
}

func EncodeInit(args InitArgs) ([]byte, error) {
	return funcInitialize.EncodeArgs(args.Owner, args.DefaultFee)
}
