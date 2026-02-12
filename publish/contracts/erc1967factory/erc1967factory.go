package erc1967factory

import (
	_ "embed"

	"github.com/cosmo-local-credit/protocol/publish"
)

const GasLimit uint64 = 1_000_000

//go:embed ERC1967Factory.bin
var bytecodeHex string

func Bytecode() []byte {
	return publish.MustHexDecode(bytecodeHex)
}
