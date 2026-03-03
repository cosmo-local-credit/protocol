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

| Contract | Implementation Address (v0.1.0) |
|---|---|
| ERC1967Factory | [0x3e302C5965954D84Ab3dac664C6152b54D7daa00](https://celoscan.io/address/0x3e302C5965954D84Ab3dac664C6152b54D7daa00) |
| AccountsIndex | [0x80163cAfD0d03F9c7251a19430E3449bb0408f76](https://celoscan.io/address/0x80163cAfD0d03F9c7251a19430E3449bb0408f76) |
| CAT | [0xE7ecf774a875A315b21104e1Dc667C57D314EE1C](https://celoscan.io/address/0xE7ecf774a875A315b21104e1Dc667C57D314EE1C) |
| ContractRegistry | [0x09537711A99d0611ac129e9F5c18C19DFDe4a7cD](https://celoscan.io/address/0x09537711A99d0611ac129e9F5c18C19DFDe4a7cD) |
| EthFaucet | [0x314Bf21025C5A53656060E26E02E8Dd5a5193937](https://celoscan.io/address/0x314Bf21025C5A53656060E26E02E8Dd5a5193937) |
| FeePolicy | [0xa4dF0D9713D42dbEBE139B3F020E2f14AF8fb37e](https://celoscan.io/address/0xa4dF0D9713D42dbEBE139B3F020E2f14AF8fb37e) |
| GiftableToken | [0x1F74298ff3CCF718c50c557d2b9a54040F295012](https://celoscan.io/address/0x1F74298ff3CCF718c50c557d2b9a54040F295012) |
| Limiter | [0x87d071631A310F6c588C833CCEe497b395ceDA35](https://celoscan.io/address/0x87d071631A310F6c588C833CCEe497b395ceDA35) |
| OracleQuoter | [0x4B10ED01332831Bf4d47ce75aB65f171c2AA736f](https://celoscan.io/address/0x4B10ED01332831Bf4d47ce75aB65f171c2AA736f) |
| PeriodSimple | [0xe64aA3BAef319CcF3D8Cd6d3295e8C41561835ff](https://celoscan.io/address/0xe64aA3BAef319CcF3D8Cd6d3295e8C41561835ff) |
| ProtocolFeeController | [0xFD68aFA98be59702F6450D4d073fa05d32D3014a](https://celoscan.io/address/0xFD68aFA98be59702F6450D4d073fa05d32D3014a) |
| RelativeQuoter | [0x8854A3ABD3bA61Cd40361c3d411258D0050dbbfe](https://celoscan.io/address/0x8854A3ABD3bA61Cd40361c3d411258D0050dbbfe) |
| Splitter | [0x396F8e22feF0e2f4F7BCA10E39B22A3B20094891](https://celoscan.io/address/0x396F8e22feF0e2f4F7BCA10E39B22A3B20094891) |
| SwapPool | [0x965cDB7bF8f46847750d548272Ee48fD01a3bB61](https://celoscan.io/address/0x965cDB7bF8f46847750d548272Ee48fD01a3bB61) |
| TokenUniqueSymbolIndex | [0x31eF6c327d5e6aC8364c1270ac3fa47AE926CCDa](https://celoscan.io/address/0x31eF6c327d5e6aC8364c1270ac3fa47AE926CCDa) |

### License and Attributions

All smart contracts under `src`, including modifications or additions to Louis Holbrook, 0xSplits and Solady snippets, are licensed under [AGPL-3.0](LICENSE) except as noted below:

* Unmodified Solady contracts remain under their original MIT license.

See [NOTICE](NOTICE) for attributions and full license texts.
