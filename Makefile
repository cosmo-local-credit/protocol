FORGE_OUT := out
CONTRACTS := ERC1967Factory GiftableToken SwapPool Limiter FeePolicy \
				RelativeQuoter ProtocolFeeController DecimalQuoter Splitter \
				EthFaucet PeriodSimple TokenUniqueSymbolIndex ContractRegistry AccountsIndex CAT

ERC1967Factory_DIR           := publish/contracts/erc1967factory
GiftableToken_DIR            := publish/contracts/giftabletoken
SwapPool_DIR                 := publish/contracts/swappool
Limiter_DIR                  := publish/contracts/limiter
FeePolicy_DIR                := publish/contracts/feepolicy
RelativeQuoter_DIR           := publish/contracts/relativequoter
ProtocolFeeController_DIR    := publish/contracts/protocolfeecontroller
DecimalQuoter_DIR            := publish/contracts/decimalquoter
Splitter_DIR                := publish/contracts/splitter
EthFaucet_DIR                := publish/contracts/ethfaucet
PeriodSimple_DIR             := publish/contracts/periodsimple
TokenUniqueSymbolIndex_DIR    := publish/contracts/tokenuniquesymbolindex
ContractRegistry_DIR          := publish/contracts/contractregistry
AccountsIndex_DIR            := publish/contracts/accountsindex
CAT_DIR                     := publish/contracts/cat

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
