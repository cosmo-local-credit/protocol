## clc-protocol

> Core smart contracts related to the CLC protocol 

Includes smart contracts around:

* Community asset vouchers
* Commitment pooling
* Protocol fees
* Multi-hop swap routing

### Requirements

* [Foundry toolchain](https://getfoundry.sh/introduction/overview)
* [Go toolchain](https://go.dev)

### Publish library

Go library for programmatic deployment of protocol contracts using the ERC1967 proxy pattern where applicable. The current package covers implementation deployment, proxy creation, receipt polling, deployed-code checks, and deterministic deployment via the Arachnid CREATE2 factory. Upgrade and admin workflows are documented as direct factory calls.

* See [docs/DEPLOY.md](docs/DEPLOY.md) for CLI commands and deployment / verification / upgrade recipes.
* See [docs/PUBLISH.md](docs/PUBLISH.md) for the Go API reference, CLI behavior, and usage examples.
* See [docs/SPEC.md](docs/SPEC.md) for individual smart contract spec.

### Deployments

#### Gnosis Mainnet (chain ID 100) - v1.0.0

Compiler: Solidity 0.8.36, EVM fork: osaka, optimizer: 200 runs (protocol). Calibur: 0.8.36 / osaka / 1000 runs. Deployer: `0x33a573149db22e759fb9a38bcc461c12855c2645`.

| Contract | Implementation Address (v1.0.0) |
|---|---|
| Calibur | [0x48A910C8e9FF0b14051b78d0c96dB069E57f0729](https://gnosisscan.io/address/0x48A910C8e9FF0b14051b78d0c96dB069E57f0729) |
| ERC1967Factory | [0xB286994c648F98fD3a3BA6C43934828a5b88162b](https://gnosisscan.io/address/0xB286994c648F98fD3a3BA6C43934828a5b88162b) |
| AccountsIndex | [0x3cA9AB9b8628b43f1A1c53f29e969BA84Ef88BeE](https://gnosisscan.io/address/0x3cA9AB9b8628b43f1A1c53f29e969BA84Ef88BeE) |
| CAT | [0xA12148B6eeb347298F17eCC5AC0377592850202E](https://gnosisscan.io/address/0xA12148B6eeb347298F17eCC5AC0377592850202E) |
| ContractRegistry | [0x273B65EA845E2832f41d8d4366E6Cc3a9Fc67186](https://gnosisscan.io/address/0x273B65EA845E2832f41d8d4366E6Cc3a9Fc67186) |
| EthFaucet | [0x3dF58d637f03CD5174c5533FB89cb9B6fd855Ad3](https://gnosisscan.io/address/0x3dF58d637f03CD5174c5533FB89cb9B6fd855Ad3) |
| FeePolicy | [0x1b97FfFAF2D2e16C8F7de6826F4F658dc898E5b6](https://gnosisscan.io/address/0x1b97FfFAF2D2e16C8F7de6826F4F658dc898E5b6) |
| GiftableToken | [0x34445d13F112A11f72C1d353a7dcdc407F3df2d8](https://gnosisscan.io/address/0x34445d13F112A11f72C1d353a7dcdc407F3df2d8) |
| Limiter | [0x258AAd6c933F70D7F071E112800a41Fb60434048](https://gnosisscan.io/address/0x258AAd6c933F70D7F071E112800a41Fb60434048) |
| OracleQuoter | [0x3334fd1eA4c7e4dCA51f5E62EE3F5f7Dcbd098BA](https://gnosisscan.io/address/0x3334fd1eA4c7e4dCA51f5E62EE3F5f7Dcbd098BA) |
| PeriodSimple | [0x8608051473603279EE982E87f765A78d3D080b00](https://gnosisscan.io/address/0x8608051473603279EE982E87f765A78d3D080b00) |
| ProtocolFeeController | [0x302E6d520e7D7AeFceA4813e456234B5daA23B4d](https://gnosisscan.io/address/0x302E6d520e7D7AeFceA4813e456234B5daA23B4d) |
| RelativeQuoter | [0x0B0986c0E580377389337C453Cc65A3933511165](https://gnosisscan.io/address/0x0B0986c0E580377389337C453Cc65A3933511165) |
| Splitter | [0x3b1F9bCC82f2dA5607dcDFCb21E47Cf64Ee54274](https://gnosisscan.io/address/0x3b1F9bCC82f2dA5607dcDFCb21E47Cf64Ee54274) |
| SwapPool | [0x9e694D342Cab02e295262B2290b0E64A0334160D](https://gnosisscan.io/address/0x9e694D342Cab02e295262B2290b0E64A0334160D) |
| TokenUniqueSymbolIndex | [0x0CEB18BA6562D3227717D98c044A5849bE8362EF](https://gnosisscan.io/address/0x0CEB18BA6562D3227717D98c044A5849bE8362EF) |
| DecimalQuoter | [0x336f493d5472FD59e9E05128804E2D05Be89c4B7](https://gnosisscan.io/address/0x336f493d5472FD59e9E05128804E2D05Be89c4B7) |
| SwapRouter | [0x16e3F29dDe22eF75C081A764C4d200Cd48647bcC](https://gnosisscan.io/address/0x16e3F29dDe22eF75C081A764C4d200Cd48647bcC) |
| RescueVault | [0x3E5D8d8f63c57EA5DD62cF5aeC7212C50bDA69EF](https://gnosisscan.io/address/0x3E5D8d8f63c57EA5DD62cF5aeC7212C50bDA69EF) |

Protocol implementations are published with `scripts/deploy-implementations.sh`.

### Security audit

* [Sarafu Network Protocol Smart Contract Security Assessment](audits/Sarafu-Protocol-Security-Audit.pdf): Internal engineering review of all protocol contracts at commit `f0944d9`; this is not an independent third-party certification.

### License and Attributions

All smart contracts under `src`, including modifications or additions to Louis Holbrook, 0xSplits and Solady snippets, are licensed under [AGPL-3.0](LICENSE) except as noted below:

* Unmodified Solady contracts remain under their original MIT license.

See [NOTICE](NOTICE) for attributions and full license texts.
