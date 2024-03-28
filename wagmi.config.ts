import { defineConfig } from '@wagmi/cli';
import { foundry } from '@wagmi/cli/plugins';
import { readdirSync, readFileSync } from 'fs';

type ContractNames =
  | 'DropMetadataRenderer'
  | 'TransferPauserExtension'
  | 'CTGPlayerNFTProxy'
  | 'CTGPlayerNFT';

type Address = `0x${string}`;

const contractFilesToInclude: ContractNames[] = [
  'DropMetadataRenderer',
  'CTGPlayerNFT',
  'TransferPauserExtension',
  'CTGPlayerNFTProxy',
  'DropMetadataRenderer'
];

const BASE_CHAIN_ID = 8453;
const BASE_SEPOLIA_CHAIN_ID = 84532;

type Addresses = {
  [key in ContractNames]?: {
    [chainId: number]: Address;
  };
};

const getAddresses = () => {
  const addresses: Addresses = {};

  const addAddress = (
    contractName: ContractNames,
    chainId: number,
    address: Address
  ) => {
    if (!addresses[contractName]) {
      addresses[contractName] = {};
    }

    addresses[contractName]![chainId] = address;
  };

  addAddress('DropMetadataRenderer', BASE_SEPOLIA_CHAIN_ID, '0xf643704CfB538aF53Dea5DFE9B1e795b9abf3bBf');
  addAddress('CTGPlayerNFT', BASE_SEPOLIA_CHAIN_ID, '0x8e5f706ff23fdabd0c527577e4e0acfc98eac46f');
  addAddress('CTGPlayerNFTProxy', BASE_SEPOLIA_CHAIN_ID, '0xa80f737cC5BFdD1f1bD0e968F7deD6b624eA8935');
  addAddress('TransferPauserExtension', BASE_SEPOLIA_CHAIN_ID, '0xb62d3B471d55E9fBae2a6ec71F84f2D3af715f92');

  return addresses;
};

export default defineConfig({
  out: 'package/wagmiGenerated.ts',
  plugins: [
    foundry({
      deployments: getAddresses(),
      include: contractFilesToInclude.map(
        (contractName) => `${contractName}.json`
      )
    })
  ]
});
