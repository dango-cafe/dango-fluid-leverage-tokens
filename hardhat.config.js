require("@nomiclabs/hardhat-waffle");
require("@nomiclabs/hardhat-ethers");
require('@openzeppelin/hardhat-upgrades');
require("@nomiclabs/hardhat-etherscan");

require("dotenv").config();

const ALCHEMY_ID = process.env.ALCHEMY_ID;
const MORALIS = process.env.MORALIS;
const ETHERSCAN = process.env.ETHERSCAN;
const PRIVATE_KEY = process.env.PRIVATE_KEY;


module.exports = {
  solidity: {
    version: "0.7.6",
    settings: {
      optimizer: {
        enabled: true,
        runs: 200
      }
    }
  },
  networks: {
    hardhat: {
      forking: {
        url: `https://eth-kovan.alchemyapi.io/v2/${ALCHEMY_ID}`,
        blockNumber: 25560975,
      },
      blockGasLimit: 12000000,
    },
    kovan: {
      url: `https://eth-kovan.alchemyapi.io/v2/${ALCHEMY_ID}`,
      accounts: [`0x${PRIVATE_KEY}`]
    },
    polygon: {
      url: `https://speedy-nodes-nyc.moralis.io/${MORALIS}/polygon/mainnet`,
      accounts: [`0x${PRIVATE_KEY}`]
    }
  },
  etherscan: {
    apiKey: ETHERSCAN
  },
  mocha: {
    timeout: 100 * 1000
  }
};

