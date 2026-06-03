package rescuevault

import (
	_ "embed"

	"github.com/ethereum/go-ethereum/common"

	"github.com/cosmo-local-credit/protocol/pkg/publish"
)

const (
	name            = "RescueVault"
	version         = "0.1.0"
	license         = "AGPL-3.0"
	solidityVersion = "0.8.34"
	evmFork         = "osaka"
	GasLimit        = 1_000_000
)

//go:embed RescueVault.bin
var bytecodeHex string

type ConstructorArgs struct {
	Admin common.Address
}

func Name() string            { return name }
func Version() string         { return version }
func License() string         { return license }
func SolidityVersion() string { return solidityVersion }
func EVMFork() string         { return evmFork }
func MaxGasLimit() uint64     { return GasLimit }

func Bytecode() []byte {
	return publish.MustHexDecode(bytecodeHex)
}

func InitCode(args ConstructorArgs) []byte {
	initCode := append([]byte{}, Bytecode()...)
	return append(initCode, common.LeftPadBytes(args.Admin.Bytes(), 32)...)
}
