package ethfaucet

import (
	_ "embed"

	"github.com/ethereum/go-ethereum/common"
	"github.com/lmittmann/w3"

	"github.com/cosmo-local-credit/protocol/publish"
)

const ImplGasLimit uint64 = 2_000_000

//go:embed EthFaucet.bin
var bytecodeHex string

var funcInitialize = w3.MustNewFunc(
	"initialize(address,uint256)", "",
)

type InitArgs struct {
	Owner  common.Address
	Amount *big.Int
}

func Bytecode() []byte {
	return publish.MustHexDecode(bytecodeHex)
}

func EncodeInit(args InitArgs) ([]byte, error) {
	return funcInitialize.EncodeArgs(args.Owner, args.Amount)
}
