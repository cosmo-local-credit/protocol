package publish

import (
	"context"
	"crypto/ecdsa"
	"encoding/hex"
	"errors"
	"fmt"
	"math/big"
	"time"

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/core/types"
	"github.com/ethereum/go-ethereum/crypto"
	"github.com/lmittmann/w3"
	"github.com/lmittmann/w3/module/eth"
)

const ProxyGasLimit uint64 = 500_000

var (
	funcDeployAndCall = w3.MustNewFunc(
		"deployAndCall(address,address,bytes)", "address",
	)
	eventDeployed = w3.MustNewEvent(
		"Deployed(address indexed,address indexed,address indexed)",
	)
)

type (
	DeployResult struct {
		TxHash          common.Hash
		ContractAddress common.Address
	}

	Deployer struct {
		client    *w3.Client
		signer    types.Signer
		key       *ecdsa.PrivateKey
		address   common.Address
		gasFeeCap *big.Int
		gasTipCap *big.Int
	}
)

func NewDeployer(rpcURL string, chainID int64, privateKey *ecdsa.PrivateKey, gasFeeCap, gasTipCap *big.Int) (*Deployer, error) {
	client, err := w3.Dial(rpcURL)
	if err != nil {
		return nil, fmt.Errorf("dial rpc: %w", err)
	}
	return &Deployer{
		client:    client,
		signer:    types.NewLondonSigner(big.NewInt(chainID)),
		key:       privateKey,
		address:   crypto.PubkeyToAddress(privateKey.PublicKey),
		gasFeeCap: gasFeeCap,
		gasTipCap: gasTipCap,
	}, nil
}

func (d *Deployer) Address() common.Address {
	return d.address
}

func (d *Deployer) Close() error {
	return d.client.Close()
}

func (d *Deployer) getNonce(ctx context.Context) (uint64, error) {
	var nonce uint64
	if err := d.client.CallCtx(ctx, eth.Nonce(d.address, nil).Returns(&nonce)); err != nil {
		return 0, fmt.Errorf("get nonce: %w", err)
	}
	return nonce, nil
}

func (d *Deployer) sendTx(ctx context.Context, tx *types.Transaction) (common.Hash, error) {
	signedTx, err := types.SignTx(tx, d.signer, d.key)
	if err != nil {
		return common.Hash{}, fmt.Errorf("sign tx: %w", err)
	}
	if err := d.client.CallCtx(ctx, eth.SendTx(signedTx).Returns(nil)); err != nil {
		return common.Hash{}, fmt.Errorf("send tx: %w", err)
	}
	return signedTx.Hash(), nil
}

func (d *Deployer) DeployImplementation(ctx context.Context, bytecode []byte, gasLimit uint64) (DeployResult, error) {
	nonce, err := d.getNonce(ctx)
	if err != nil {
		return DeployResult{}, err
	}

	contractAddr := crypto.CreateAddress(d.address, nonce)

	//  EIP-1559 only
	tx := types.NewTx(&types.DynamicFeeTx{
		Nonce:     nonce,
		GasFeeCap: d.gasFeeCap,
		GasTipCap: d.gasTipCap,
		Gas:       gasLimit,
		Data:      bytecode,
	})

	txHash, err := d.sendTx(ctx, tx)
	if err != nil {
		return DeployResult{}, err
	}

	return DeployResult{
		TxHash:          txHash,
		ContractAddress: contractAddr,
	}, nil
}

func (d *Deployer) DeployProxy(ctx context.Context, factory, implementation, admin common.Address, initData []byte, gasLimit uint64) (common.Hash, error) {
	calldata, err := funcDeployAndCall.EncodeArgs(implementation, admin, initData)
	if err != nil {
		return common.Hash{}, fmt.Errorf("encode deployAndCall: %w", err)
	}

	nonce, err := d.getNonce(ctx)
	if err != nil {
		return common.Hash{}, err
	}

	tx := types.NewTx(&types.DynamicFeeTx{
		Nonce:     nonce,
		To:        &factory,
		GasFeeCap: d.gasFeeCap,
		GasTipCap: d.gasTipCap,
		Gas:       gasLimit,
		Data:      calldata,
	})

	return d.sendTx(ctx, tx)
}

func (d *Deployer) WaitForReceipt(ctx context.Context, txHash common.Hash) (*types.Receipt, error) {
	ticker := time.NewTicker(2 * time.Second)
	defer ticker.Stop()

	for {
		var receipt *types.Receipt
		err := d.client.CallCtx(ctx, eth.TxReceipt(txHash).Returns(&receipt))
		if err == nil {
			return receipt, nil
		}

		select {
		case <-ctx.Done():
			return nil, ctx.Err()
		case <-ticker.C:
		}
	}
}

func ProxyAddressFromReceipt(receipt *types.Receipt) (common.Address, error) {
	for _, log := range receipt.Logs {
		var (
			proxy          common.Address
			implementation common.Address
			admin          common.Address
		)
		if err := eventDeployed.DecodeArgs(log, &proxy, &implementation, &admin); err == nil {
			return proxy, nil
		}
	}
	return common.Address{}, errors.New("Deployed event not found in receipt logs")
}

func MustHexDecode(hexStr string) []byte {
	b, err := hex.DecodeString(hexStr)
	if err != nil {
		panic(fmt.Sprintf("decode hex: %v", err))
	}
	return b
}
