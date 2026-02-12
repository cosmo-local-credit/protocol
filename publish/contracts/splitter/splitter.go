package splitter

import (
	_ "embed"

	"github.com/ethereum/go-ethereum/common"
	"github.com/lmittmann/w3"

	"github.com/cosmo-local-credit/protocol/publish"
)

const ImplGasLimit uint64 = 500_000

//go:embed Splitter.bin
var bytecodeHex string

var funcInitialize = w3.MustNewFunc(
	"initialize(address,address[],uint32[])", "",
)

type InitArgs struct {
	Owner              common.Address
	Accounts           []common.Address
	PercentAllocations []uint32
}

func Bytecode() []byte {
	return publish.MustHexDecode(bytecodeHex)
}

func EncodeInit(args InitArgs) ([]byte, error) {
	return funcInitialize.EncodeArgs(
		args.Owner,
		args.Accounts,
		args.PercentAllocations,
	)
}
