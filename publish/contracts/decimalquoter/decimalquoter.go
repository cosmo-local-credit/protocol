package decimalquoter

import (
	_ "embed"

	"github.com/cosmo-local-credit/protocol/publish"
)

const GasLimit uint64 = 1_000_000

//go:embed DecimalQuoter.bin
var bytecodeHex string

func Bytecode() []byte {
	return publish.MustHexDecode(bytecodeHex)
}
