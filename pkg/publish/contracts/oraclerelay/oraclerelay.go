package oraclerelay

import (
	_ "embed"

	"github.com/ethereum/go-ethereum/common"
	"github.com/lmittmann/w3"

	"github.com/cosmo-local-credit/protocol/pkg/publish"
)

const (
	name            = "OracleRelay"
	version         = "0.1.0"
	license         = "AGPL-3.0"
	solidityVersion = "0.8.36"
	evmFork         = "osaka"
	ImplGasLimit    = 1_000_000
)

//go:embed OracleRelay.bin
var bytecodeHex string

var funcInitialize = w3.MustNewFunc(
	"initialize(address,address,uint8,string)", "",
)

type InitArgs struct {
	Owner       common.Address
	Writer      common.Address
	Decimals    uint8
	Description string
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
	return funcInitialize.EncodeArgs(args.Owner, args.Writer, args.Decimals, args.Description)
}
