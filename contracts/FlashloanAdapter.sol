//SPDX-License-Identifier: MIT
pragma solidity ^0.7.6;
pragma experimental ABIEncoderV2;

import { OwnableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import { SafeMathUpgradeable } from "@openzeppelin/contracts-upgradeable/math/SafeMathUpgradeable.sol";

import { 
  ILendingPoolAddressesProvider,
  IFluidLeverage,
  IERC20,
  ISushiRouter,
  IProtocolDataProvider
} from "./utils/Interfaces.sol";
import { FlashLoanReceiverBase } from "./utils/FlashLoanReceiverBase.sol";
import { SafeERC20, DataTypes } from "./utils/Libraries.sol";
import { DangoMath } from "./utils/DangoMath.sol";

contract FlashloanAdapter is FlashLoanReceiverBase, OwnableUpgradeable, DangoMath {
  using SafeMathUpgradeable for uint256;
  using SafeERC20 for IERC20;

  mapping(address => mapping(address => address[])) paths;

  IProtocolDataProvider public immutable dataProvider;
  ISushiRouter public immutable sushi;

  uint256 public maxSlippage;

  mapping(address => bool) public fluidLeverage;

  constructor(
    ILendingPoolAddressesProvider _addressProvider,
    IProtocolDataProvider _dataProvider,
    ISushiRouter _sushi,
    uint256 _maxSlippage,
    address[] memory _fluidLeverages
  ) FlashLoanReceiverBase(_addressProvider) {
    require(_maxSlippage <= 500, "max-slippage-too-high");
    dataProvider = _dataProvider;
    sushi = _sushi;
    maxSlippage = _maxSlippage;

    for (uint256 index = 0; index < _fluidLeverages.length; index++) {
      fluidLeverage[_fluidLeverages[index]] = true;
    }
  }

  function executeOperation(
    address[] calldata assets,
    uint256[] calldata amounts,
    uint256[] calldata premiums,
    address initiator,
    bytes calldata params
  ) external override returns (bool) {
    require(fluidLeverage[initiator], "not-authorized");

    DataTypes.FlashloanData memory _data;

    (_data) = abi.decode(params, (DataTypes.FlashloanData));

    require(_data.flashAmt == amounts[0], "amt-mistmatch");
    require(_data.flashAsset == assets[0], "asset-mistmatch");

    if (_data.opType == 0) {
      _rebalanceUp(_data, initiator);
    } else if (_data.opType == 1) {
      _rebalanceDown(_data, initiator, premiums[0]);
    } else if (_data.opType == 2) {
      _deposit(_data, initiator);
    } else {
      _withdraw(_data, initiator, premiums[0]);
    }

    return true;
  }

  function executeWithdraw(uint256 _amt) external {
    require(fluidLeverage[msg.sender], "not-authorized");

    IERC20 _collateral = IFluidLeverage(msg.sender).COLLATERAL_ASSET();
    IERC20 _debt = IFluidLeverage(msg.sender).DEBT_ASSET();

    require(_collateral.balanceOf(address(this)) > _amt, "did-not-receive-trade-amt");

    DataTypes.FlashloanData memory _data;

    _data.flashAmt = _amt;
    _data.flashAsset = address(_collateral);
    _data.targetAsset = address(_debt);

    (uint256 _maxDebt, uint256 _received) = _swapCollateralToDebt(_data, msg.sender);

    if (_received > _maxDebt) {
      _debt.safeApprove(address(LENDING_POOL), 0);
      _debt.safeApprove(address(LENDING_POOL), _maxDebt);

      LENDING_POOL.repay(address(_debt), type(uint256).max, 2, msg.sender);

      address[] memory _path = paths[_data.targetAsset][_data.flashAsset];

      _debt.safeApprove(address(sushi), 0);
      _debt.safeApprove(address(sushi), _received.sub(_maxDebt));

      uint256[] memory _amts = sushi.swapExactTokensForTokens(_received.sub(_maxDebt), 0, _path, address(this), block.timestamp.add(1800));

      _collateral.safeApprove(address(sushi), 0);
      _collateral.safeApprove(address(sushi), _amts[_amts.length - 1]);

      LENDING_POOL.deposit(address(_collateral), _amts[_amts.length - 1], msg.sender, 0);
    } else {
      _debt.safeApprove(address(LENDING_POOL), 0);
      _debt.safeApprove(address(LENDING_POOL), _received);

      LENDING_POOL.repay(address(_debt), _received, 2, msg.sender);
    }
  }

  function _rebalanceUp(DataTypes.FlashloanData memory _data, address _fluidLeverage) internal {
    require(_data.userDepositAmt == 0, "invalid-op");
    _swapDebtToCollateral(_data, _fluidLeverage);
  }

  function _rebalanceDown(DataTypes.FlashloanData memory _data, address _fluidLeverage, uint256 _premium) internal {
    IERC20 _collateral = IERC20(_data.flashAsset);
    IERC20 _debt = IERC20(_data.targetAsset);

    (uint256 _maxDebt, uint256 _received) = _swapCollateralToDebt(_data, _fluidLeverage);

    require(_received <= _maxDebt, "error-system-failure");

    _debt.safeApprove(address(LENDING_POOL), 0);
    _debt.safeApprove(address(LENDING_POOL), _received);

    LENDING_POOL.repay(address(_debt), _received, 2, _fluidLeverage);

    uint256 _toRepayFlashloan = _data.flashAmt.add(_premium);
    IFluidLeverage(_fluidLeverage).__withdrawCollateral(_toRepayFlashloan);

    _collateral.safeApprove(address(LENDING_POOL), 0);
    _collateral.safeApprove(address(LENDING_POOL), _toRepayFlashloan);
  }

  function _deposit(DataTypes.FlashloanData memory _data, address _fluidLeverage) internal {
    require(_data.userDepositAmt > 0, "no-deposits-found");
    IERC20 _collateral = IERC20(_data.targetAsset);
    require(_collateral.balanceOf(address(this)) >= _data.userDepositAmt, "deposit-not-received");

    _swapDebtToCollateral(_data, _fluidLeverage);
  }

  function _withdraw(DataTypes.FlashloanData memory _data, address _fluidLeverage, uint256 _premium) internal {
    IERC20 _collateral = IERC20(_data.flashAsset);
    IERC20 _debt = IERC20(_data.targetAsset);

    (uint256 _maxDebt, uint256 _received) = _swapCollateralToDebt(_data, _fluidLeverage);

    if (_received > _maxDebt) {
      _debt.safeApprove(address(LENDING_POOL), 0);
      _debt.safeApprove(address(LENDING_POOL), _maxDebt);

      LENDING_POOL.repay(address(_debt), type(uint256).max, 2, _fluidLeverage);

      address[] memory _path = paths[_data.targetAsset][_data.flashAsset];

      _debt.safeApprove(address(sushi), 0);
      _debt.safeApprove(address(sushi), _received.sub(_maxDebt));

      uint256[] memory _amts = sushi.swapExactTokensForTokens(_received.sub(_maxDebt), 0, _path, address(this), block.timestamp.add(1800));

      _collateral.safeApprove(address(sushi), 0);
      _collateral.safeApprove(address(sushi), _amts[_amts.length - 1]);

      LENDING_POOL.deposit(address(_collateral), _amts[_amts.length - 1], _fluidLeverage, 0);
    } else {
      _debt.safeApprove(address(LENDING_POOL), 0);
      _debt.safeApprove(address(LENDING_POOL), _received);

      LENDING_POOL.repay(address(_debt), _received, 2, _fluidLeverage);
    }

    uint256 _toRepayFlashloan = _data.flashAmt.add(_premium);
    IFluidLeverage(_fluidLeverage).__withdrawCollateral(_toRepayFlashloan);

    _collateral.safeApprove(address(LENDING_POOL), 0);
    _collateral.safeApprove(address(LENDING_POOL), _toRepayFlashloan);
  }

  function _swapDebtToCollateral(DataTypes.FlashloanData memory _data, address _fluidLeverage) internal {
    IERC20 _collateral = IERC20(_data.targetAsset);
    IERC20 _debt = IERC20(_data.flashAsset);

    _debt.safeApprove(address(sushi), 0);
    _debt.safeApprove(address(sushi), _data.flashAmt);

    address[] memory _path = paths[_data.flashAsset][_data.targetAsset];

    uint256 _debtPrice = IFluidLeverage(_fluidLeverage).getDebtPrice();
    uint256 _minAmt;

    {
      uint256 _amt18 = wdiv(_data.flashAmt, 10 ** (_debt.decimals()));
      uint256 _idealAmt = wmul(_amt18, _debtPrice);
      uint256 _slippageAmt = _idealAmt.mul(maxSlippage).div(10000);
      uint256 _minOut = _idealAmt.sub(_slippageAmt);
      _minAmt = wmul(_minOut, 10 ** (_collateral.decimals()));
    }

    uint256[] memory _amts = sushi.swapExactTokensForTokens(_data.flashAmt, _minAmt, _path, address(this), block.timestamp.add(1800));

    uint256 _totalAmt = _amts[_amts.length - 1].add(_data.userDepositAmt);

    _collateral.safeApprove(address(LENDING_POOL), 0);
    _collateral.safeApprove(address(LENDING_POOL), _totalAmt);

    LENDING_POOL.deposit(address(_collateral), _totalAmt, _fluidLeverage, 0);
  }

  function _swapCollateralToDebt(DataTypes.FlashloanData memory _data, address _fluidLeverage) internal returns (uint256, uint256) {
    IERC20 _collateral = IERC20(_data.flashAsset);
    IERC20 _debt = IERC20(_data.targetAsset);

    _collateral.safeApprove(address(sushi), 0);
    _collateral.safeApprove(address(sushi), _data.flashAmt);

    address[] memory _path = paths[_data.flashAsset][_data.targetAsset];

    uint256 _debtPrice = IFluidLeverage(_fluidLeverage).getDebtPrice();
    uint256 _minAmt;

    {
      uint256 _amt18 = wdiv(_data.flashAmt, 10 ** (_collateral.decimals()));
      uint256 _idealAmt = wdiv(_amt18, _debtPrice);
      uint256 _slippageAmt = _idealAmt.mul(maxSlippage).div(10000);
      uint256 _minOut = _idealAmt.sub(_slippageAmt);
      _minAmt = wmul(_minOut, 10 ** (_debt.decimals()));
    }

    uint256[] memory _amts = sushi.swapExactTokensForTokens(_data.flashAmt, _minAmt, _path, address(this), block.timestamp.add(1800));

    (,, uint256 _maxDebt,,,,,,) = dataProvider.getUserReserveData(address(_debt), _fluidLeverage);

    uint256 _received = _amts[_amts.length - 1];

    return (_maxDebt, _received);
  }

  function __addTradePath(address _start, address _end, address[] calldata _path) external onlyOwner {
    require(_start == _path[0], "invalid-path");
    require(_end == _path[_path.length - 1], "invalid-path");

    paths[_start][_end] = _path;
  }

  function __setMaxSlippage(uint256 _maxSlippage) external onlyOwner {
    require(_maxSlippage <= 500, "max-slippage-too-high");
    maxSlippage = _maxSlippage;
  }

  function __addFluidLeverage(address _lev) external onlyOwner {
    require(_lev != address(0x0), "invalid-address");
    fluidLeverage[_lev] = true;
  }
}