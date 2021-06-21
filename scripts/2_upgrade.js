const { ethers } = require("hardhat");
const { parseEther } = ethers.utils;

const aaveLendingPoolAddressProvider = '0xd05e3E715d945B59290df0ae8eF85c1BdB684744'
const aaveProtocolDataProvider = '0x7551b5D2763519d4e37e8B81929D336De671d46d'
const wbtc = '0x1bfd67037b42cf73acf2047067bd4f2c47d9bfd6'
const usdc = '0x2791bca1f2de4661ed88a30c99a7a9449aa84174'
const weth = '0x7ceb23fd6bc0add59e62ac25578270cff1b9f619'
const targetLeverRatio = parseEther('2').toString()
const lowerLeverRatio = parseEther('1.7').toString()
const upperLeverRatio = parseEther('2.3').toString()

async function deployFluidLeverage(FLT, collateral, debt) {
  const fluidLeverageLogic = await FLT.deploy(
    aaveLendingPoolAddressProvider,
    aaveProtocolDataProvider,
    collateral,
    debt,
    targetLeverRatio,
    lowerLeverRatio,
    upperLeverRatio
  )

  await fluidLeverageLogic.deployed()

  await hre.run("verify:verify", {
    address: fluidLeverageLogic.address,
    constructorArguments: [
      aaveLendingPoolAddressProvider,
      aaveProtocolDataProvider,
      collateral,
      debt,
      targetLeverRatio,
      lowerLeverRatio,
      upperLeverRatio
    ]
  })

  return fluidLeverageLogic.address
}

async function main() {
  const FluidLeverage = await ethers.getContractFactory("DangoFluidLeverageToken")

  const weth_usdc = await deployFluidLeverage(
    FluidLeverage, weth, usdc
  )
  console.log("WETH/USDC FLT Logic Deployed: ", weth_usdc)

  const wbtc_usdc = await deployFluidLeverage(
    FluidLeverage, wbtc, usdc
  )
  console.log("WBTC/USDC FLT Logic Deployed: ", wbtc_usdc)

  const weth_wbtc = await deployFluidLeverage(
    FluidLeverage, weth, wbtc
  )
  console.log("WETH/WBTC FLT Logic Deployed: ", weth_wbtc)

  const wbtc_weth = await deployFluidLeverage(
    FluidLeverage, wbtc, weth
  )
  console.log("WBTC/WETH FLT Logic Deployed: ", wbtc_weth)
}

main()
  .then(() => process.exit(0))
  .catch(error => {
    console.error(error);
    process.exit(1);
  });
