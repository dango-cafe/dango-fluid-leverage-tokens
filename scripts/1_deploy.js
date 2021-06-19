const { ethers } = require("hardhat");
const { encodeCall } = require("@openzeppelin/upgrades");
const RLP = require('rlp');
const { parseEther } = ethers.utils;


async function main() {
  const deployerAddress = '0xe0468E2A40877F0FB0839895b4eCC81A19C6Cd4d'
  const aaveLendingPoolAddressProvider = '0x88757f2f99175387aB4C6a4b3067c77A695b0349'
  const aaveProtocolDataProvider = '0x3c73A5E5785cAC854D468F727c606C07488a29D6'
  const wbtc = '0xD1B98B6607330172f1D991521145A22BCe793277'
  const usdc = '0xe22da380ee6B445bb8273C81944ADEB6E8450422'
  const sushiRouter = '0x1b02dA8Cb0d097eB8D57A175b88c7D8b47997506'
  const targetLeverRatio = parseEther('2').toString()
  const lowerLeverRatio = parseEther('1.7').toString()
  const upperLeverRatio = parseEther('2.3').toString()
  const tenBaseFifteen = ethers.BigNumber.from(10).pow(15)

  const FluidLeverage = await ethers.getContractFactory("DangoFluidLeverageToken")
  const fluidLeverageLogic = await FluidLeverage.deploy(
    aaveLendingPoolAddressProvider,
    aaveProtocolDataProvider,
    wbtc,
    usdc,
    targetLeverRatio,
    lowerLeverRatio,
    upperLeverRatio
  )

  await fluidLeverageLogic.deployed()

  console.log("FluidLeverage deployed: ", fluidLeverageLogic.address)

  const txCount = await hre.ethers.provider.getTransactionCount(deployerAddress) + 1
  const proxyAddress = '0x' + hre.ethers.utils.keccak256(RLP.encode([deployerAddress, txCount])).slice(12).substring(14)

  const FlashloanAdapter = await ethers.getContractFactory("DangoFlashloanAdapter")
  const flashloanAdapter = await FlashloanAdapter.deploy(
    aaveLendingPoolAddressProvider,
    aaveProtocolDataProvider,
    sushiRouter,
    300,
    [proxyAddress]
  )

  await flashloanAdapter.deployed()

  console.log("FlashloanAdapter deployed: ", flashloanAdapter.address)

  const initBytes = encodeCall(
    "initialize",
    ["string", "string", "address", "address", "uint256", "uint256", "uint256"],
    [
      "WBTC 2x Fluid Leverage Index",
      "dFLI-WBTC-2x",
      flashloanAdapter.address,
      deployerAddress,
      ethers.BigNumber.from('5').mul(tenBaseFifteen).toString(),
      ethers.BigNumber.from('10').mul(tenBaseFifteen).toString(),
      parseEther('100').toString()
    ]
  )

  // console.log(initBytes)

  const AdminUpgradeabilityProxy = await ethers.getContractFactory("AdminUpgradeabilityProxy")
  const adminUpgradeabilityProxy = await AdminUpgradeabilityProxy.deploy(
    fluidLeverageLogic.address,
    deployerAddress,
    initBytes
  )

  await adminUpgradeabilityProxy.deployed()

  console.log("AdminUpgradeabilityProxy deployed: ", adminUpgradeabilityProxy.address)

  await flashloanAdapter.__addTradePath(usdc, wbtc, [usdc, wbtc])
  await flashloanAdapter.__addTradePath(wbtc, usdc, [wbtc, usdc])

  await hre.run("verify:verify", {
    address: fluidLeverageLogic.address,
    constructorArguments: [
      aaveLendingPoolAddressProvider,
      aaveProtocolDataProvider,
      wbtc,
      usdc,
      targetLeverRatio,
      lowerLeverRatio,
      upperLeverRatio
    ]
  })

  await hre.run("verify:verify", {
    address: flashloanAdapter.address,
    constructorArguments: [
      aaveLendingPoolAddressProvider,
      aaveProtocolDataProvider,
      sushiRouter,
      300,
      [proxyAddress]
    ]
  })

  await hre.run("verify:verify", {
    address: adminUpgradeabilityProxy.address,
    constructorArguments: [
      fluidLeverageLogic.address,
      deployerAddress,
      initBytes
    ]
  })
  
}

main()
  .then(() => process.exit(0))
  .catch(error => {
    console.error(error);
    process.exit(1);
  });
