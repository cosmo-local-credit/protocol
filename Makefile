FORGE_OUT := out
CONTRACTS := ERC1967Factory GiftableToken SwapPool Limiter FeePolicy \
				RelativeQuoter ProtocolFeeController DecimalQuoter Splitter \
				EthFaucet PeriodSimple TokenUniqueSymbolIndex ContractRegistry AccountsIndex CAT OracleQuoter

ERC1967Factory_DIR           := pkg/publish/contracts/erc1967factory
GiftableToken_DIR            := pkg/publish/contracts/giftabletoken
SwapPool_DIR                 := pkg/publish/contracts/swappool
Limiter_DIR                  := pkg/publish/contracts/limiter
FeePolicy_DIR                := pkg/publish/contracts/feepolicy
RelativeQuoter_DIR           := pkg/publish/contracts/relativequoter
ProtocolFeeController_DIR    := pkg/publish/contracts/protocolfeecontroller
DecimalQuoter_DIR            := pkg/publish/contracts/decimalquoter
Splitter_DIR                := pkg/publish/contracts/splitter
EthFaucet_DIR                := pkg/publish/contracts/ethfaucet
PeriodSimple_DIR             := pkg/publish/contracts/periodsimple
TokenUniqueSymbolIndex_DIR    := pkg/publish/contracts/tokenuniquesymbolindex
ContractRegistry_DIR          := pkg/publish/contracts/contractregistry
AccountsIndex_DIR            := pkg/publish/contracts/accountsindex
CAT_DIR                     := pkg/publish/contracts/cat
OracleQuoter_DIR            := pkg/publish/contracts/oraclequoter

.PHONY: all build artifacts clean test

all: build artifacts

build:
	forge build

test:
	forge test -vvv

artifacts: $(foreach c,$(CONTRACTS),artifact-$(c))

artifact-%:
	@mkdir -p $($*_DIR)
	@jq -r '.bytecode.object' $(FORGE_OUT)/$*.sol/$*.json | sed 's/^0x//' > $($*_DIR)/$*.bin

clean:
	$(foreach c,$(CONTRACTS),rm -f $($(c)_DIR)/$(c).bin;)
