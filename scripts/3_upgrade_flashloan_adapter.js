const { ethers } = require("hardhat");

const aaveLendingPoolAddressProvider = '0xd05e3E715d945B59290df0ae8eF85c1BdB684744'
const aaveProtocolDataProvider = '0x7551b5D2763519d4e37e8B81929D336De671d46d'
const wbtc = '0x1bfd67037b42cf73acf2047067bd4f2c47d9bfd6'
const usdc = '0x2791bca1f2de4661ed88a30c99a7a9449aa84174'
const weth = '0x7ceb23fd6bc0add59e62ac25578270cff1b9f619'
const wmatic = '0x0d500B1d8E8eF31E21C99d1Db9A6444d3ADf1270'
const sushiRouter = '0x1b02dA8Cb0d097eB8D57A175b88c7D8b47997506'

const weth_usdc = '0xabcd3c5e8aed3b8d8096f0f33c7aa1cb5d555dfb'
const wbtc_usdc = '0x12b6dc6c41460994f0471f0a665bebfc78f3f55c'
const weth_wbtc = '0x0093660a2f58c0c38ce2ce0f894c86f9011478ea'
const wbtc_weth = '0x540fbc594c455a8af6d238c16af2511c37cc0e9b'

async function main() {
  const FlashloanAdapter = await ethers.getContractFactory("DangoFlashloanAdapter")
  const flashloanAdapter = await FlashloanAdapter.deploy(
    aaveLendingPoolAddressProvider,
    aaveProtocolDataProvider,
    sushiRouter,
    wmatic,
    300,
    [
      weth_usdc,
      wbtc_usdc,
      weth_wbtc,
      wbtc_weth
    ]
  )

  await flashloanAdapter.deployed()

  console.log("FlashloanAdapter deployed: ", flashloanAdapter.address)

  await flashloanAdapter.__addTradePath(weth, wbtc, [weth, wbtc])
  await flashloanAdapter.__addTradePath(wbtc, weth, [wbtc, weth])

  await flashloanAdapter.__addTradePath(weth, usdc, [weth, usdc])
  await flashloanAdapter.__addTradePath(usdc, weth, [usdc, weth])

  await flashloanAdapter.__addTradePath(wbtc, usdc, [wbtc, weth, usdc])
  await flashloanAdapter.__addTradePath(usdc, wbtc, [usdc, weth, wbtc])

  await flashloanAdapter.__addTradePath(wmatic, weth, [wmatic, weth])
  await flashloanAdapter.__addTradePath(wmatic, wbtc, [wmatic, weth, wbtc])

  await hre.run("verify:verify", {
    address: flashloanAdapter.address,
    constructorArguments: [
      aaveLendingPoolAddressProvider,
      aaveProtocolDataProvider,
      sushiRouter,
      wmatic,
      300,
      [
        weth_usdc,
        wbtc_usdc,
        weth_wbtc,
        wbtc_weth
      ]
    ]
  })
}

main()
  .then(() => process.exit(0))
  .catch(error => {
    console.error(error);
    process.exit(1);
  });