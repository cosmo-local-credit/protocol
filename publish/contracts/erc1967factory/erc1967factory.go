package erc1967factory

import (
	_ "embed"

	"github.com/cosmo-local-credit/protocol/publish"
)

const (
	name            = "ERC1967Factory"
	version         = "0.1.0"
	license         = "AGPL-3.0"
	solidityVersion = "0.8.30"
	evmFork         = "shanghai"
	GasLimit        = 1_000_000
)

//go:embed ERC1967Factory.bin
var bytecodeHex string

func Name() string            { return name }
func Version() string         { return version }
func License() string         { return license }
func SolidityVersion() string { return solidityVersion }
func EVMFork() string         { return evmFork }
func MaxGasLimit() uint64     { return GasLimit }

func Bytecode() []byte {
	return publish.MustHexDecode(bytecodeHex)
}
