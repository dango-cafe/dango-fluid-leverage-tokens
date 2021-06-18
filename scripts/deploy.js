const hre = require("hardhat");
const RLP = require('rlp');

async function main() {
  const deployerAddress = '0xe0468E2A40877F0FB0839895b4eCC81A19C6Cd4d'
  const aaveAddrProvider = '0x88757f2f99175387ab4c6a4b3067c77a695b0349'
  
  console.log("Deploying proxy...")

  const ProxyFactory = await hre.ethers.getContractFactory("DangoProxyFactory")
  const factory = await ProxyFactory.deploy()
  await factory.deployed()

  console.log("DangoProxyFactory: ", factory.address)

  const txCount = await hre.ethers.provider.getTransactionCount(deployerAddress) + 1
  const executorAddress = '0x' + hre.ethers.utils.keccak256(RLP.encode([deployerAddress, txCount])).slice(12).substring(14)

  const Receiver = await hre.ethers.getContractFactory("DangoReceiver")
  const receiver = await Receiver.deploy(aaveAddrProvider, executorAddress)
  await receiver.deployed();

  const Executor = await hre.ethers.getContractFactory("DangoExecutor")
  const executor = await Executor.deploy(receiver.address, aaveAddrProvider, '0x3c73A5E5785cAC854D468F727c606C07488a29D6')
  await executor.deployed()

  console.log('DangoReceiver: ', receiver.address)
  console.log('DangoExecutor: ', executor.address)
  
}

main()
  .then(() => process.exit(0))
  .catch(error => {
    console.error(error);
    process.exit(1);
  });
