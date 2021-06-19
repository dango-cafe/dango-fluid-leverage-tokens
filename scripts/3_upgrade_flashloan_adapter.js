const { ethers } = require("hardhat");
const { parseEther } = ethers.utils;

async function main() {
  const aaveLendingPoolAddressProvider = '0x88757f2f99175387aB4C6a4b3067c77A695b0349'
  const aaveProtocolDataProvider = '0x3c73A5E5785cAC854D468F727c606C07488a29D6'
  const wbtc = '0xD1B98B6607330172f1D991521145A22BCe793277'
  const usdc = '0xe22da380ee6B445bb8273C81944ADEB6E8450422'
  const sushiRouter = '0x1b02dA8Cb0d097eB8D57A175b88c7D8b47997506'

  const fluidLevProxy = '0xfe76398e095d30a4e76d31de9379bcab5773e237'

  // const FlashloanAdapter = await ethers.getContractFactory("FlashloanAdapter")
  // const flashloanAdapter = await FlashloanAdapter.deploy(
  //   aaveLendingPoolAddressProvider,
  //   aaveProtocolDataProvider,
  //   sushiRouter,
  //   300,
  //   [fluidLevProxy]
  // )

  // await flashloanAdapter.deployed()

  // console.log("FlashloanAdapter deployed: ", flashloanAdapter.address)

  // await flashloanAdapter.__addTradePath(usdc, wbtc, [usdc, wbtc])
  // await flashloanAdapter.__addTradePath(wbtc, usdc, [wbtc, usdc])

  await hre.run("verify:verify", {
    address: '0x8b72841DcC545eaf9f12Eda071E8C44A45703574',
    constructorArguments: [
      aaveLendingPoolAddressProvider,
      aaveProtocolDataProvider,
      sushiRouter,
      300,
      [fluidLevProxy]
    ]
  })
}

main()
  .then(() => process.exit(0))
  .catch(error => {
    console.error(error);
    process.exit(1);
  });