package periodsimple

import (
	_ "embed"

	"github.com/ethereum/go-ethereum/common"
	"github.com/lmittmann/w3"

	"github.com/cosmo-local-credit/protocol/publish"
)

const ImplGasLimit uint64 = 2_000_000

//go:embed PeriodSimple.bin
var bytecodeHex string

var funcInitialize = w3.MustNewFunc(
	"initialize(address,address)", "",
)

type InitArgs struct {
	Owner common.Address
	Poker common.Address
}

func Bytecode() []byte {
	return publish.MustHexDecode(bytecodeHex)
}

func EncodeInit(args InitArgs) ([]byte, error) {
	return funcInitialize.EncodeArgs(args.Owner, args.Poker)
}
