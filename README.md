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

#### Celo Mainnet (chain ID 42220)

Compiler: Solidity 0.8.34, EVM fork: osaka, optimizer: 200 runs. Deployer: `0x469723CbE3C164F818bD49E3dFa9823616282FDD`.

| Contract | Implementation Address (v0.5.0) |
|---|---|
| ERC1967Factory | [0x3e302C5965954D84Ab3dac664C6152b54D7daa00](https://celoscan.io/address/0x3e302C5965954D84Ab3dac664C6152b54D7daa00) |
| AccountsIndex | [0x35113F67fd55450E625f6979dF21aDCB73E6DBb7](https://celoscan.io/address/0x35113F67fd55450E625f6979dF21aDCB73E6DBb7) |
| CAT | [0xE7ecf774a875A315b21104e1Dc667C57D314EE1C](https://celoscan.io/address/0xE7ecf774a875A315b21104e1Dc667C57D314EE1C) |
| ContractRegistry | [0x09537711A99d0611ac129e9F5c18C19DFDe4a7cD](https://celoscan.io/address/0x09537711A99d0611ac129e9F5c18C19DFDe4a7cD) |
| EthFaucet | [0x4Ed5662BEE1B8cDEbF0Eb0A628271a84188153d0](https://celoscan.io/address/0x4Ed5662BEE1B8cDEbF0Eb0A628271a84188153d0) |
| FeePolicy | [0xa4dF0D9713D42dbEBE139B3F020E2f14AF8fb37e](https://celoscan.io/address/0xa4dF0D9713D42dbEBE139B3F020E2f14AF8fb37e) |
| GiftableToken | [0x1F74298ff3CCF718c50c557d2b9a54040F295012](https://celoscan.io/address/0x1F74298ff3CCF718c50c557d2b9a54040F295012) |
| Limiter | [0x392d269E5AB4d6024AccD3b2F7dE0b79E0f7602f](https://celoscan.io/address/0x392d269E5AB4d6024AccD3b2F7dE0b79E0f7602f) |
| OracleQuoter | [0x0F753b191d01538d24B89968A90b5A1aE3753E0d](https://celoscan.io/address/0x0F753b191d01538d24B89968A90b5A1aE3753E0d) |
| PeriodSimple | [0xe64aA3BAef319CcF3D8Cd6d3295e8C41561835ff](https://celoscan.io/address/0xe64aA3BAef319CcF3D8Cd6d3295e8C41561835ff) |
| ProtocolFeeController | [0xFD68aFA98be59702F6450D4d073fa05d32D3014a](https://celoscan.io/address/0xFD68aFA98be59702F6450D4d073fa05d32D3014a) |
| RelativeQuoter | [0x9107e667aB5F1F05dB5285B2E93c50C3Af47B710](https://celoscan.io/address/0x9107e667aB5F1F05dB5285B2E93c50C3Af47B710) |
| Splitter | [0x396F8e22feF0e2f4F7BCA10E39B22A3B20094891](https://celoscan.io/address/0x396F8e22feF0e2f4F7BCA10E39B22A3B20094891) |
| SwapPool | [0xCF879ADd8c34083b48c8a638D3C166eFcF35D454](https://celoscan.io/address/0xCF879ADd8c34083b48c8a638D3C166eFcF35D454) |
| TokenUniqueSymbolIndex | [0xA2d04499e68B0B295bf0331D516DcA8A30Fc51c6](https://celoscan.io/address/0xA2d04499e68B0B295bf0331D516DcA8A30Fc51c6) |
| DecimalQuoter | [0x7ff73c1833FdA7C0f458c079496015F9D22f64f4](https://celoscan.io/address/0x7ff73c1833FdA7C0f458c079496015F9D22f64f4) |
| SwapRouter | [0x204653A89FF5F2A935c88b0c750cAcdaA9e7368d](https://celoscan.io/address/0x204653A89FF5F2A935c88b0c750cAcdaA9e7368d) |

### License and Attributions

All smart contracts under `src`, including modifications or additions to Louis Holbrook, 0xSplits and Solady snippets, are licensed under [AGPL-3.0](LICENSE) except as noted below:

* Unmodified Solady contracts remain under their original MIT license.

See [NOTICE](NOTICE) for attributions and full license texts.
