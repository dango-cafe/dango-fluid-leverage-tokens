const { ethers } = require("hardhat");
const { encodeCall } = require("@openzeppelin/upgrades");
const RLP = require('rlp');
const { parseEther } = ethers.utils;

const deployerAddress = '0xe0468E2A40877F0FB0839895b4eCC81A19C6Cd4d'
const aaveLendingPoolAddressProvider = '0xd05e3E715d945B59290df0ae8eF85c1BdB684744'
const aaveProtocolDataProvider = '0x7551b5D2763519d4e37e8B81929D336De671d46d'
const wbtc = '0x1bfd67037b42cf73acf2047067bd4f2c47d9bfd6'
const usdc = '0x2791bca1f2de4661ed88a30c99a7a9449aa84174'
const weth = '0x7ceb23fd6bc0add59e62ac25578270cff1b9f619'
const wmatic = '0x0d500B1d8E8eF31E21C99d1Db9A6444d3ADf1270'
const sushiRouter = '0x1b02dA8Cb0d097eB8D57A175b88c7D8b47997506'
const feeCollector = '0xbBcB0C42C30d1D58c81b44f8B4BbcF7D56dB1DA3'
const aaveIncentives = '0x357D51124f59836DeD84c8a1730D72B749d8BC23'
const targetLeverRatio = parseEther('2').toString()
const lowerLeverRatio = parseEther('1.7').toString()
const upperLeverRatio = parseEther('2.3').toString()
const tenBaseFourteen = ethers.BigNumber.from(10).pow(14)

async function deployFluidLeverage(FLT, Proxy, collateral, debt, flashloanAdapter, name, symbol, capacity) {
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

  const initBytes = encodeCall(
    "initialize",
    ["string", "string", "address", "address", "uint256", "uint256", "uint256", "address[]"],
    [
      name,
      symbol,
      flashloanAdapter,
      feeCollector,
      ethers.BigNumber.from('10').mul(tenBaseFourteen).toString(),
      ethers.BigNumber.from('30').mul(tenBaseFourteen).toString(),
      capacity,
      [ deployerAddress ]
    ]
  )

  const proxy = await Proxy.deploy(
    fluidLeverageLogic.address,
    deployerAddress,
    initBytes
  )

  await proxy.deployed()

  await hre.run("verify:verify", {
    address: proxy.address,
    constructorArguments: [
      fluidLeverageLogic.address,
      deployerAddress,
      initBytes
    ]
  })

  return { logic: fluidLeverageLogic, proxy }
}


async function main() {
  const txCount = await hre.ethers.provider.getTransactionCount(deployerAddress) + 9
  const flashloanAdapterAddr = '0x' + hre.ethers.utils.keccak256(RLP.encode([deployerAddress, txCount])).slice(12).substring(14)

  const FluidLeverage = await ethers.getContractFactory("DangoFluidLeverageToken")
  const AdminUpgradeabilityProxy = await ethers.getContractFactory("AdminUpgradeabilityProxy")
  
  const weth_usdc = await deployFluidLeverage(
    FluidLeverage, AdminUpgradeabilityProxy, weth, usdc, flashloanAdapterAddr, "ETH 2x Fluid Leverage Token", "dFLT-ETH", parseEther('1000').toString()
  )
  console.log("WETH/USDC FLT Logic Deployed: ", weth_usdc.logic.address)
  console.log("WETH/USDC FLT Proxy Deployed: ", weth_usdc.proxy.address)

  const wbtc_usdc = await deployFluidLeverage(
    FluidLeverage, AdminUpgradeabilityProxy, wbtc, usdc, flashloanAdapterAddr, "BTC 2x Fluid Leverage Token", "dFLT-BTC", parseEther('50').toString()
  )
  console.log("WBTC/USDC FLT Logic Deployed: ", wbtc_usdc.logic.address)
  console.log("WBTC/USDC FLT Proxy Deployed: ", wbtc_usdc.logic.address)

  const weth_wbtc = await deployFluidLeverage(
    FluidLeverage, AdminUpgradeabilityProxy, weth, wbtc, flashloanAdapterAddr, "ETH/BTC 2x Fluid Leverage Token", "dFLT-ETH-BTC", parseEther('1000').toString()
  )
  console.log("WETH/WBTC FLT Logic Deployed: ", weth_wbtc.logic.address)
  console.log("WETH/WBTC FLT Logic Deployed: ", weth_wbtc.proxy.address)

  const wbtc_weth = await deployFluidLeverage(
    FluidLeverage, AdminUpgradeabilityProxy, wbtc, weth, flashloanAdapterAddr, "BTC/ETH 2x Fluid Leverage Token", "dFLT-BTC-ETH", parseEther('50').toString()
  )
  console.log("WBTC/WETH FLT Logic Deployed: ", wbtc_weth.logic.address)
  console.log("WBTC/WETH FLT Logic Deployed: ", wbtc_weth.proxy.address)

  const FlashloanAdapter = await ethers.getContractFactory("DangoFlashloanAdapter")
  const flashloanAdapter = await FlashloanAdapter.deploy(
    aaveLendingPoolAddressProvider,
    aaveProtocolDataProvider,
    sushiRouter,
    aaveIncentives,
    wmatic,
    300,
    [
      weth_usdc.proxy.address,
      wbtc_usdc.proxy.address,
      weth_wbtc.proxy.address,
      wbtc_weth.proxy.address
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

  await hre.run("verify:verify", {
    address: flashloanAdapter.address,
    constructorArguments: [
      aaveLendingPoolAddressProvider,
      aaveProtocolDataProvider,
      sushiRouter,
      aaveIncentives,
      wmatic,
      300,
      [
        weth_usdc.proxy.address,
        wbtc_usdc.proxy.address,
        weth_wbtc.proxy.address,
        wbtc_weth.proxy.address
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
