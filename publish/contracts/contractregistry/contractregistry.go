package contractregistry

import (
	_ "embed"

	"github.com/ethereum/go-ethereum/common"
	"github.com/lmittmann/w3"

	"github.com/cosmo-local-credit/protocol/publish"
)

const (
	name            = "ContractRegistry"
	version         = "0.1.0"
	license         = "AGPL-3.0"
	solidityVersion = "0.8.30"
	evmFork         = "shanghai"
	ImplGasLimit    = 2_000_000
)

//go:embed ContractRegistry.bin
var bytecodeHex string

var funcInitialize = w3.MustNewFunc(
	"initialize(address,bytes32[])", "",
)

type InitArgs struct {
	Owner       common.Address
	Identifiers [][]byte
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
	return funcInitialize.EncodeArgs(args.Owner, toBytes32Slice(args.Identifiers))
}

func toBytes32Slice(values [][]byte) [][32]byte {
	out := make([][32]byte, len(values))
	for i, value := range values {
		out[i] = common.BytesToHash(common.RightPadBytes(value, 32))
	}
	return out
}
