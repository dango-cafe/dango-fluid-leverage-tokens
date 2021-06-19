const { ethers } = require("hardhat");
const { parseEther } = ethers.utils;

async function main() {
  const aaveLendingPoolAddressProvider = '0x88757f2f99175387aB4C6a4b3067c77A695b0349'
  const aaveProtocolDataProvider = '0x3c73A5E5785cAC854D468F727c606C07488a29D6'
  const wbtc = '0xD1B98B6607330172f1D991521145A22BCe793277'
  const usdc = '0xe22da380ee6B445bb8273C81944ADEB6E8450422'
  const targetLeverRatio = parseEther('2').toString()
  const lowerLeverRatio = parseEther('1.7').toString()
  const upperLeverRatio = parseEther('2.3').toString()

  const fluidLevProxy = '0xfe76398e095d30a4e76d31de9379bcab5773e237'

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

  const AdminUpgradeabilityProxy = await ethers.getContractFactory("AdminUpgradeabilityProxy")
  const adminUpgradeabilityProxy = AdminUpgradeabilityProxy.attach(fluidLevProxy)

  const tx = await adminUpgradeabilityProxy.upgradeTo(fluidLeverageLogic.address)
  await tx.wait()

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
}

main()
  .then(() => process.exit(0))
  .catch(error => {
    console.error(error);
    process.exit(1);
  });
