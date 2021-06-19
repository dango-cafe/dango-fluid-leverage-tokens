const { expect } = require("chai");
const { encodeCall } = require("@openzeppelin/upgrades");
const hre = require("hardhat");
const { ethers } = hre;
const { parseEther } = ethers.utils;

describe("Greeter", function() {
  let wallet0, wallet1;
  let fluidLeverage;
  let flashloanAdapter;

  // const deployerAddress = '0xe0468E2A40877F0FB0839895b4eCC81A19C6Cd4d'
  const aaveLendingPoolAddressProvider = '0x88757f2f99175387aB4C6a4b3067c77A695b0349'
  const aaveProtocolDataProvider = '0x3c73A5E5785cAC854D468F727c606C07488a29D6'
  const wbtc = '0xD1B98B6607330172f1D991521145A22BCe793277'
  const usdc = '0xe22da380ee6B445bb8273C81944ADEB6E8450422'
  const sushiRouter = '0x1b02dA8Cb0d097eB8D57A175b88c7D8b47997506'
  const targetLeverRatio = parseEther('2').toString()
  const lowerLeverRatio = parseEther('1.7').toString()
  const upperLeverRatio = parseEther('2.3').toString()
  const tenBaseFifteen = ethers.BigNumber.from(10).pow(15)

  before(async() => {
    [wallet0, wallet1] = await ethers.getSigners();

    const FluidLeverage = await ethers.getContractFactory("FluidLeverage")

    fluidLeverage = await FluidLeverage.deploy(
      aaveLendingPoolAddressProvider,
      aaveProtocolDataProvider,
      wbtc,
      usdc,
      targetLeverRatio,
      lowerLeverRatio,
      upperLeverRatio
    )

    await fluidLeverage.deployed()

    console.log("FluidLeverage deployed: ", fluidLeverage.address)

    const FlashloanAdapter = await ethers.getContractFactory("FlashloanAdapter")
    flashloanAdapter = await FlashloanAdapter.deploy(
      aaveLendingPoolAddressProvider,
      aaveProtocolDataProvider,
      sushiRouter,
      300,
      [fluidLeverage.address]
    )

    await flashloanAdapter.deployed()

    console.log("FlashloanAdapter deployed: ", flashloanAdapter.address)

    await fluidLeverage.initialize(
      "WBTC 2x Fluid Leverage Index",
      "dFLI-WBTC-2x",
      flashloanAdapter.address,
      wallet0.address,
      ethers.BigNumber.from('5').mul(tenBaseFifteen).toString(),
      ethers.BigNumber.from('10').mul(tenBaseFifteen).toString()
    )

    await flashloanAdapter.__addTradePath(usdc, wbtc, [usdc, wbtc])
    await flashloanAdapter.__addTradePath(wbtc, usdc, [wbtc, usdc])

    // Mint WBTC
    const mintBytes = encodeCall("mint", ["address", "uint256"], [wbtc, "10000000000"])
    await wallet0.sendTransaction({
      to: "0x600103d518cc5e8f3319d532eb4e5c268d32e604",
      data: mintBytes
    })
    await wallet1.sendTransaction({
      to: "0x600103d518cc5e8f3319d532eb4e5c268d32e604",
      data: mintBytes
    })

    // Approve WBTC
    const approveBytes = encodeCall("approve", ["address", "uint256"], [fluidLeverage.address, "10000000000000000000000"])
    await wallet0.sendTransaction({
      to: wbtc,
      data: approveBytes
    })
    await wallet1.sendTransaction({
      to: wbtc,
      data: approveBytes
    })
  })

  it("Should be deployed", async() => {
    expect(!!fluidLeverage.address).to.be.true;
    expect(!!flashloanAdapter.address).to.be.true;
  })

  it("Should deposit", async() => {
    const tx = await fluidLeverage.deposit("100000000")
    await tx.wait()

    expect(await fluidLeverage.balanceOf(wallet0.address)).to.be.equal(parseEther("1"))
  })
});
