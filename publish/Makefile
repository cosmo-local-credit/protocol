FORGE_OUT := ../out
CONTRACTS := ERC1967Factory GiftableToken SwapPool Limiter FeePolicy \
             RelativeQuoter ProtocolFeeController DecimalQuoter

# Map contract name → target directory
ERC1967Factory_DIR           := contracts/erc1967factory
GiftableToken_DIR            := contracts/giftabletoken
SwapPool_DIR                 := contracts/swappool
Limiter_DIR                  := contracts/limiter
FeePolicy_DIR                := contracts/feepolicy
RelativeQuoter_DIR           := contracts/relativequoter
ProtocolFeeController_DIR    := contracts/protocolfeecontroller
DecimalQuoter_DIR            := contracts/decimalquoter

.PHONY: all build artifacts clean

all: build artifacts

build:
	cd .. && forge build

artifacts: $(foreach c,$(CONTRACTS),artifact-$(c))

artifact-%:
	@mkdir -p $($*_DIR)
	@jq -r '.bytecode.object' $(FORGE_OUT)/$*.sol/$*.json | sed 's/^0x//' > $($*_DIR)/$*.bin

clean:
	$(foreach c,$(CONTRACTS),rm -f $($(c)_DIR)/$(c).bin;)
