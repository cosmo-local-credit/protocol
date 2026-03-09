## clc-protocol

> Core smart contracts related to the CLC protocol 

Includes smart contracts around:

* Community asset vouchers
* Commitment pooling
* Protocol fees

### Requirements

* [Foundry toolchain](https://getfoundry.sh/introduction/overview)

### Publish library

Go library for programmatic deployment and management of protocol contracts using the ERC1967 proxy pattern. Handles implementation deployment, proxy creation, upgrades, and deterministic deployments.

* See [docs/PUBLISH](docs/PUBLISH.md) for complete API reference, usage scenarios, and examples.
* See [docs/SPEC](docs/SPEC.md) for individual smart contract spec.

### Deployments

#### Celo Mainnet (chain ID 42220)

Compiler: Solidity 0.8.34, EVM fork: osaka, optimizer: 200 runs. Deployer: `0x469723CbE3C164F818bD49E3dFa9823616282FDD`.

| Contract | Implementation Address (v0.4.0) |
|---|---|
| ERC1967Factory | [0x3e302C5965954D84Ab3dac664C6152b54D7daa00](https://celoscan.io/address/0x3e302C5965954D84Ab3dac664C6152b54D7daa00) |
| AccountsIndex | [0x35113F67fd55450E625f6979dF21aDCB73E6DBb7](https://celoscan.io/address/0x35113F67fd55450E625f6979dF21aDCB73E6DBb7) |
| CAT | [0xE7ecf774a875A315b21104e1Dc667C57D314EE1C](https://celoscan.io/address/0xE7ecf774a875A315b21104e1Dc667C57D314EE1C) |
| ContractRegistry | [0x09537711A99d0611ac129e9F5c18C19DFDe4a7cD](https://celoscan.io/address/0x09537711A99d0611ac129e9F5c18C19DFDe4a7cD) |
| EthFaucet | [0x4Ed5662BEE1B8cDEbF0Eb0A628271a84188153d0](https://celoscan.io/address/0x4Ed5662BEE1B8cDEbF0Eb0A628271a84188153d0) |
| FeePolicy | [0xa4dF0D9713D42dbEBE139B3F020E2f14AF8fb37e](https://celoscan.io/address/0xa4dF0D9713D42dbEBE139B3F020E2f14AF8fb37e) |
| GiftableToken | [0x1F74298ff3CCF718c50c557d2b9a54040F295012](https://celoscan.io/address/0x1F74298ff3CCF718c50c557d2b9a54040F295012) |
| Limiter | [0x392d269E5AB4d6024AccD3b2F7dE0b79E0f7602f](https://celoscan.io/address/0x392d269E5AB4d6024AccD3b2F7dE0b79E0f7602f) |
| OracleQuoter | [0x9AD8F1E0679cCAe584dC9745b371246Dc3688343](https://celoscan.io/address/0x9AD8F1E0679cCAe584dC9745b371246Dc3688343) |
| PeriodSimple | [0xe64aA3BAef319CcF3D8Cd6d3295e8C41561835ff](https://celoscan.io/address/0xe64aA3BAef319CcF3D8Cd6d3295e8C41561835ff) |
| ProtocolFeeController | [0xFD68aFA98be59702F6450D4d073fa05d32D3014a](https://celoscan.io/address/0xFD68aFA98be59702F6450D4d073fa05d32D3014a) |
| RelativeQuoter | [0x8854A3ABD3bA61Cd40361c3d411258D0050dbbfe](https://celoscan.io/address/0x8854A3ABD3bA61Cd40361c3d411258D0050dbbfe) |
| Splitter | [0x396F8e22feF0e2f4F7BCA10E39B22A3B20094891](https://celoscan.io/address/0x396F8e22feF0e2f4F7BCA10E39B22A3B20094891) |
| SwapPool | [0x106f799430a52D8cf875786346ac0202DEe1214B](https://celoscan.io/address/0x106f799430a52D8cf875786346ac0202DEe1214B) |
| TokenUniqueSymbolIndex | [0xA2d04499e68B0B295bf0331D516DcA8A30Fc51c6](https://celoscan.io/address/0xA2d04499e68B0B295bf0331D516DcA8A30Fc51c6) |

### License and Attributions

All smart contracts under `src`, including modifications or additions to Louis Holbrook, 0xSplits and Solady snippets, are licensed under [AGPL-3.0](LICENSE) except as noted below:

* Unmodified Solady contracts remain under their original MIT license.

See [NOTICE](NOTICE) for attributions and full license texts.
