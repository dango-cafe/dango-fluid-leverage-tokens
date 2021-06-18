//SPDX-License-Identifier: MIT
pragma solidity ^0.7.6;
pragma experimental ABIEncoderV2;

import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/Initializable.sol";
import { ERC20Upgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import { OwnableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import { SafeMathUpgradeable } from "@openzeppelin/contracts-upgradeable/math/SafeMathUpgradeable.sol";
import { ReentrancyGuardUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";

import {
  IERC20,
  ILendingPoolAddressesProvider,
  ILendingPool,
  IProtocolDataProvider,
  IPriceOracleGetter,
  IDebtToken,
  IFlashloanAdapter
} from "./utils/Interfaces.sol";
import { SafeERC20, DataTypes } from "./utils/Libraries.sol";
import { DangoMath } from "./utils/DangoMath.sol";

contract FluidLeverage is Initializable, ERC20Upgradeable, OwnableUpgradeable, ReentrancyGuardUpgradeable, DangoMath {
  using SafeMathUpgradeable for uint256;
  using SafeERC20 for IERC20;

  uint256 public constant REBALANCE_DELAY = 86400;
  uint256 public constant REBALANCE_GRACE_PERIOD = 7200;

  uint8 private immutable debtDecimals;
  uint8 private immutable collDecimals;

  ILendingPoolAddressesProvider public immutable AAVE_ADDRESSES_PROVIDER;
  IProtocolDataProvider public immutable AAVE_DATA_PROVIDER;
  IERC20 public immutable COLLATERAL_ASSET;
  IERC20 public immutable DEBT_ASSET;
  uint256 public immutable targetLeverageRatio;
  uint256 public immutable lowerLeverageLimit;
  uint256 public immutable upperLeverageLimit;

  ILendingPool public AAVE_LENDING_POOL;
  IPriceOracleGetter public AAVE_ORACLE;
  address public flashloanAdapter;
  address public feeCollector;
  uint256 public mintFee;
  uint256 public burnFee;
  uint256 public indexPrice;
  uint256 public lastRebalancingTime;

  constructor(
    ILendingPoolAddressesProvider _provider,
    IProtocolDataProvider _dataProvider,
    IERC20 _collateral,
    IERC20 _debt,
    uint256 _target,
    uint256 _lower,
    uint256 _upper
  ) {
    address _aToken;

    (_aToken, , ) = _dataProvider.getReserveTokensAddresses(address(_collateral));
    require(_aToken != address(0x0), "invalid-collateral-address");

    (_aToken, , ) = _dataProvider.getReserveTokensAddresses(address(_debt));
    require(_aToken != address(0x0), "invalid-collateral-address");

    require(_lower < _target && _upper > _target, "target-lev-out-of-range");
    require(_target > 1e18, "invalid-target-lev");

    AAVE_ADDRESSES_PROVIDER = _provider;
    AAVE_DATA_PROVIDER = _dataProvider;

    COLLATERAL_ASSET = _collateral;
    DEBT_ASSET = _debt;

    targetLeverageRatio = _target;
    lowerLeverageLimit = _lower;
    upperLeverageLimit = _upper;

    collDecimals = _collateral.decimals();
    debtDecimals = _debt.decimals();
  }

  function initialize(
    string calldata _name,
    string calldata _symbol,
    address _flashloanAdapter,
    address _feeCollector,
    uint256 _mintFee,
    uint256 _burnFee
  ) initializer public {
    require(_mintFee <= 1e16, "mint-fee-too-large");
    require(_burnFee <= 3e16, "burn-fee-too-large");

    __ERC20_init(_name, _symbol);

    AAVE_LENDING_POOL = ILendingPool(AAVE_ADDRESSES_PROVIDER.getLendingPool());
    AAVE_ORACLE = IPriceOracleGetter(AAVE_ADDRESSES_PROVIDER.getPriceOracle());

    indexPrice = 1e18;
    flashloanAdapter = _flashloanAdapter;
    feeCollector = _feeCollector;
    mintFee = _mintFee;
    burnFee = _burnFee;
    lastRebalancingTime = block.timestamp;
  }

  modifier onlyFlashloanAdapter() {
    require(msg.sender == flashloanAdapter, "access-denied-not-flashloan-adapter");
    _;
  }

  function deposit(uint256 _amt) external nonReentrant {
    (uint256 _fee, uint256 _finalAmt) = _calculateMintFee(_amt);
    COLLATERAL_ASSET.safeTransfer(feeCollector, _fee);
    COLLATERAL_ASSET.safeTransferFrom(msg.sender, flashloanAdapter, _finalAmt);

    DataTypes.FlashloanData memory _data;

    _data.opType = 2;
    _data.userDepositAmt = _finalAmt;
    _data.flashAsset = address(DEBT_ASSET);
    _data.targetAsset = address(COLLATERAL_ASSET);

    if (collDecimals != 18) {
      _finalAmt = wdiv(_finalAmt, 10 ** collDecimals);
    }

    uint256 _flashMultiplier = getCurrentLeverRatio().sub(1e18);
    uint256 _flashloanAmt = wmul(wdiv(_finalAmt, getDebtPrice()), _flashMultiplier);
    if (debtDecimals != 18) {
      _flashloanAmt = wmul(_flashloanAmt, 10 ** debtDecimals);
    }
    uint256 _amtToMint = wdiv(_finalAmt, getIndex());

    _data.flashAmt = _flashloanAmt;

    (,, address _variableDebtToken) = AAVE_DATA_PROVIDER.getReserveTokensAddresses(address(DEBT_ASSET));
    IDebtToken(_variableDebtToken).approveDelegation(flashloanAdapter, _flashloanAmt);

    _flashloan(address(DEBT_ASSET), _flashloanAmt, abi.encode(_data));
    _mint(msg.sender, _amtToMint);

    // Event emission
  }

  function withdraw(uint256 _amt) external nonReentrant {
    require(balanceOf(msg.sender) >= _amt, "not-enough-bal");

    uint256 _amtToReturn = wmul(_amt, getIndex());
    uint256 _multiplier = getCurrentLeverRatio().sub(1e18);
    uint256 _amtToFlash = wmul(_amtToReturn, _multiplier);
    uint256 _totalWithdraw = _amtToReturn.add(_amtToFlash);

    if (collDecimals != 18) {
      _amtToFlash = wmul(_amtToFlash, 10 ** collDecimals);
      _amtToReturn = wmul(_amtToReturn, 10 ** collDecimals);
    }

    _withdrawCollateral(_totalWithdraw, address(this));
    COLLATERAL_ASSET.safeTransfer(flashloanAdapter, _amtToFlash);
    IFlashloanAdapter(flashloanAdapter).executeWithdraw(_amtToFlash);

    (uint256 _fee, uint256 _finalAmt) = _calculateBurnFee(_amtToReturn);
    COLLATERAL_ASSET.safeTransfer(feeCollector, _fee);
    COLLATERAL_ASSET.safeTransfer(msg.sender, _finalAmt);

    _burn(msg.sender, _amt);

    // Event emission
  }

  function withdrawViaFlashloan(uint256 _amt) external nonReentrant {
    require(balanceOf(msg.sender) >= _amt, "not-enough-bal");

    uint256 _scaledAmt = wmul(_amt, getIndex());
    uint256 _multiplier = getCurrentLeverRatio().sub(1e18);
    uint256 _amtToFlash = wmul(_scaledAmt, _multiplier);
    uint256 _flashPremium = _amtToFlash.mul(AAVE_LENDING_POOL.FLASHLOAN_PREMIUM_TOTAL()).div(10000);
    uint256 _amtToReturn = _scaledAmt.sub(_flashPremium);

    if (collDecimals != 18) {
      _amtToFlash = wmul(_amtToFlash, 10 ** collDecimals);
      _amtToReturn = wmul(_amtToReturn, 10 ** collDecimals);
    }

    DataTypes.FlashloanData memory _data;
    _data.opType = 3;
    _data.flashAmt = _amtToFlash;
    _data.flashAsset = address(COLLATERAL_ASSET);
    _data.targetAsset = address(DEBT_ASSET);

    _flashloan(address(COLLATERAL_ASSET), _amtToFlash, abi.encode(_data));
    _withdrawCollateral(_amtToReturn, address(this));

    (uint256 _fee, uint256 _finalAmt) = _calculateBurnFee(_amtToReturn);
    COLLATERAL_ASSET.safeTransfer(feeCollector, _fee);
    COLLATERAL_ASSET.safeTransfer(msg.sender, _finalAmt);

    _burn(msg.sender, _amt);

    // Event emission
  }

  function rebalance() external nonReentrant {
    require(block.timestamp > lastRebalancingTime.add(REBALANCE_DELAY).sub(REBALANCE_GRACE_PERIOD), "too-soon-to-rebalance");
    require(block.timestamp < lastRebalancingTime.add(REBALANCE_DELAY).add(REBALANCE_GRACE_PERIOD), "rebalancing-time-over");

    _rebalance();

    lastRebalancingTime = block.timestamp;

    // Event emission
  }

  function emergencyRebalance() external nonReentrant {
    bool _leverCondition = getCurrentLeverRatio() < lowerLeverageLimit || getCurrentLeverRatio() > upperLeverageLimit;
    bool _timeCondition = block.timestamp > lastRebalancingTime.add(REBALANCE_DELAY).add(REBALANCE_DELAY.div(2));

    require(_leverCondition || _timeCondition, "cannot-invoke-emergency-rebalance");

    _rebalance();

    lastRebalancingTime = block.timestamp;

    // Event emission
  }

  function getCurrentLeverRatio() public view returns (uint256 _leverRatio) {
    if (totalSupply() == 0) {
      return targetLeverageRatio;
    }

    uint256 _debtPrice = getDebtPrice();

    (uint256 _collBal,,,,,,,,) = AAVE_DATA_PROVIDER.getUserReserveData(address(COLLATERAL_ASSET), address(this));
    (,, uint256 _debtBal,,,,,,) = AAVE_DATA_PROVIDER.getUserReserveData(address(DEBT_ASSET), address(this));

    if (collDecimals != 18) {
      uint256 _tokenUnit = 10 ** collDecimals;
      _collBal = wdiv(_collBal, _tokenUnit);
    }
    if (debtDecimals != 18) {
      uint256 _tokenUnit = 10 ** debtDecimals;
      _debtBal = wdiv(_debtBal, _tokenUnit);
    }

    uint256 _realExposure = _collBal.sub(wmul(_debtBal, _debtPrice));

    _leverRatio = wdiv(_collBal, _realExposure);
  }

  function getDebtPrice() public view returns (uint256 _debtPrice) {
    uint256 _collateralPriceEth = AAVE_ORACLE.getAssetPrice(address(COLLATERAL_ASSET));
    uint256 _debtPriceEth = AAVE_ORACLE.getAssetPrice(address(DEBT_ASSET));

    _debtPrice = wdiv(_debtPriceEth, _collateralPriceEth);
  }

  function getIndex() public view returns (uint256 _newIndex) {
    if (totalSupply() == 0) {
      return 1e18;
    }

    uint256 _debtPrice = getDebtPrice();

    (uint256 _collBal,,,,,,,,) = AAVE_DATA_PROVIDER.getUserReserveData(address(COLLATERAL_ASSET), address(this));
    (,, uint256 _debtBal,,,,,,) = AAVE_DATA_PROVIDER.getUserReserveData(address(DEBT_ASSET), address(this));

    if (collDecimals != 18) {
      uint256 _tokenUnit = 10 ** collDecimals;
      _collBal = wdiv(_collBal, _tokenUnit);
    }
    if (debtDecimals != 18) {
      uint256 _tokenUnit = 10 ** debtDecimals;
      _debtBal = wdiv(_debtBal, _tokenUnit);
    }


    uint256 _realExposure = _collBal.sub(wmul(_debtBal, _debtPrice));
    uint256 _idealCollBal = wmul(targetLeverageRatio, _realExposure);

    if (_idealCollBal > _collBal) {
      uint256 _deltaDebt = wdiv(wmul(targetLeverageRatio, _realExposure).sub(_collBal), _debtPrice);
      uint256 _idealDeltaColl = wmul(_deltaDebt, _debtPrice);

      _newIndex = indexPrice.add(wdiv(_idealDeltaColl, totalSupply()));
    } else {
      uint256 _deltaDebt = wdiv(_collBal.sub(wmul(targetLeverageRatio, _realExposure)), _debtPrice);
      uint256 _idealDeltaColl = wmul(_deltaDebt, _debtPrice);

      _newIndex = indexPrice.sub(wdiv(_idealDeltaColl, totalSupply()));
    }
  }

  function _calculateMintFee(uint256 _amt) internal view returns (uint256 _feeAmt, uint256 _amtSubFee) {
    _feeAmt = wmul(_amt, mintFee);
    _amtSubFee = _amt.sub(_feeAmt);
  }

  function _calculateBurnFee(uint256 _amt) internal view returns (uint256 _feeAmt, uint256 _amtSubFee) {
    _feeAmt = wmul(_amt, burnFee);
    _amtSubFee = _amt.sub(_feeAmt);
  }

  function _flashloan(address _asset, uint256 _amt, bytes memory _data) internal {
    address[] memory assets = new address[](1);
    assets[0] = address(_asset);

    uint256[] memory amounts = new uint256[](1);
    amounts[0] = _amt;

    uint256[] memory modes = new uint256[](1);
    modes[0] = _asset == address(DEBT_ASSET) ? 2 : 0;

    bytes memory params = _data;
    uint16 referralCode = 0;

    AAVE_LENDING_POOL.flashLoan(
        flashloanAdapter,
        assets,
        amounts,
        modes,
        address(this),
        params,
        referralCode
    );
  }

  function _withdrawCollateral(uint256 _amt, address _to) internal {
    AAVE_LENDING_POOL.withdraw(address(COLLATERAL_ASSET), _amt, _to);
  }

  function _rebalance() internal {
    (uint256 _collBal,,,,,,,,) = AAVE_DATA_PROVIDER.getUserReserveData(address(COLLATERAL_ASSET), address(this));
    (,, uint256 _debtBal,,,,,,) = AAVE_DATA_PROVIDER.getUserReserveData(address(DEBT_ASSET), address(this));

    uint256 _debtPrice = getDebtPrice();

    if (collDecimals != 18) {
      uint256 _tokenUnit = 10 ** collDecimals;
      _collBal = wdiv(_collBal, _tokenUnit);
    }
    if (debtDecimals != 18) {
      uint256 _tokenUnit = 10 ** debtDecimals;
      _debtBal = wdiv(_debtBal, _tokenUnit);
    }

    uint256 _realExposure = _collBal.sub(wmul(_debtBal, _debtPrice));
    uint256 _idealCollBal = wmul(targetLeverageRatio, _realExposure);

    if (_idealCollBal > _collBal) {
      uint256 _deltaDebt = wdiv(wmul(targetLeverageRatio, _realExposure).sub(_collBal), _debtPrice);

      if (debtDecimals != 18) {
        _deltaDebt = wmul(_deltaDebt, 10 ** debtDecimals);
      }

      DataTypes.FlashloanData memory _data;

      _data.flashAsset = address(DEBT_ASSET);
      _data.targetAsset = address(COLLATERAL_ASSET);
      _data.flashAmt = _deltaDebt;

      (,, address _variableDebtToken) = AAVE_DATA_PROVIDER.getReserveTokensAddresses(address(DEBT_ASSET));
    IDebtToken(_variableDebtToken).approveDelegation(flashloanAdapter, _deltaDebt);

      _flashloan(address(DEBT_ASSET), _deltaDebt, abi.encode(_data));
    } else {
      uint256 _deltaDebt = wdiv(_collBal.sub(wmul(targetLeverageRatio, _realExposure)), _debtPrice);
      uint256 _idealDeltaColl = wmul(_deltaDebt, _debtPrice);

      if (collDecimals != 18) {
        _idealDeltaColl = wmul(_idealDeltaColl, 10 ** collDecimals);
      }

      DataTypes.FlashloanData memory _data;

      _data.opType = 1;
      _data.flashAsset = address(COLLATERAL_ASSET);
      _data.targetAsset = address(DEBT_ASSET);
      _data.flashAmt = _idealDeltaColl;

      _flashloan(address(COLLATERAL_ASSET), _idealDeltaColl, abi.encode(_data));
    }

    (uint256 _newCollBal,,,,,,,,) = AAVE_DATA_PROVIDER.getUserReserveData(address(COLLATERAL_ASSET), address(this));

    if (collDecimals != 18) {
      uint256 _tokenUnit = 10 ** collDecimals;
      _newCollBal = wdiv(_newCollBal, _tokenUnit);
    }

    if (_newCollBal > _collBal) {
      indexPrice = indexPrice.add(wdiv(_newCollBal.sub(_collBal), totalSupply()));
    } else {
      indexPrice = indexPrice.sub(wdiv(_collBal.sub(_newCollBal), totalSupply()));
    }
  }

  function __updateAaveLendingPool() external onlyOwner {
    AAVE_LENDING_POOL = ILendingPool(AAVE_ADDRESSES_PROVIDER.getLendingPool());
  }

  function __updateAaveOracle() external onlyOwner {
    AAVE_ORACLE = IPriceOracleGetter(AAVE_ADDRESSES_PROVIDER.getPriceOracle());
  }

  function __changeFlashloanAdapter(address _newAdapter) external onlyOwner {
    require(_newAdapter != address(0x0), "invalid-address");
    flashloanAdapter = _newAdapter;
  }

  function __changeFeeCollector(address _newCollector) external onlyOwner {
    require(_newCollector != address(0x0), "invalid-address");
    feeCollector = _newCollector;
  }

  function __changeFees(uint256 _mintFee, uint256 _burnFee) external onlyOwner {
    require(_mintFee <= 1e16, "mint-fee-too-large");
    require(_burnFee <= 3e16, "burn-fee-too-large");

    mintFee = _mintFee;
    burnFee = _burnFee;
  }

  function __withdrawCollateral(uint256 _amt) external onlyFlashloanAdapter {
    _withdrawCollateral(_amt, flashloanAdapter);
  }

}
