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

/**
 * @title DangoFlashloanAdapter
 * @author Dango.Cafe
 *
 * This is the contract that handles all the trading & flashloan logics
 * All the trades goes through SushiSwap
 * One logic contract is used for all the Fluid Leverage Tokens
 */
contract DangoFlashloanAdapter is FlashLoanReceiverBase, OwnableUpgradeable, DangoMath {
  using SafeMathUpgradeable for uint256;
  using SafeERC20 for IERC20;

  /* ============ Immutables ============ */

  IProtocolDataProvider public immutable dataProvider;                    // Aave Protocol Data Provider instance
  ISushiRouter public immutable sushi;                                    // Sushiswap Router instance

  /* ============ State Variables ============ */

  uint256 public maxSlippage;                                             // Maximum slippage tolerated by the system (measured in 10e5. i.e. 1% = 100)

  mapping(address => bool) public fluidLeverage;                          // Mapping of active Fluid Leverage Tokens
  mapping(address => mapping(address => address[])) paths;                // Mapping of SushiSwap paths for pairs

  /* ============ Events ============ */

  event ConvertDebtToCollateral(
    address indexed _flt,
    address indexed _debt,
    address indexed _collateral,
    uint256 _input,
    uint256 _output
  );

  event ConvertCollateralToDebt(
    address indexed _flt,
    address indexed _debt,
    address indexed _collateral,
    uint256 _input,
    uint256 _output
  );

  event AddTradePath(
    address indexed _start,
    address indexed _end,
    address[] _path
  );

  event UpdateMaxSlippage(
    uint256 _currentSlippage,
    uint256 _newSlippage
  );

  event AddFLT(
    address _flt
  );

  event RemoveFLT(
    address _flt
  );

  /* ============ Constructor ============ */

  /**
   * Sets the values for immutables & state variables
   *
   * @param _addressProvider    Address of Aave Lending Pool Address Provider
   * @param _dataProvider       Address of Aave Protocol Data Provider
   * @param _sushi              Address of Sushiswap router
   * @param _maxSlippage        Maximum slippage tolerated by the system (in 10e5 base)
   * @param _fluidLeverages     Array of active fluid leverage tokens
   */
  constructor(
    ILendingPoolAddressesProvider _addressProvider,
    IProtocolDataProvider _dataProvider,
    ISushiRouter _sushi,
    uint256 _maxSlippage,
    address[] memory _fluidLeverages
  ) FlashLoanReceiverBase(_addressProvider) {
    require(_maxSlippage <= 500, "max-slippage-too-high");

    __Ownable_init();

    dataProvider = _dataProvider;
    sushi = _sushi;
    maxSlippage = _maxSlippage;

    for (uint256 index = 0; index < _fluidLeverages.length; index++) {
      fluidLeverage[_fluidLeverages[index]] = true;
    }
  }

  /* ============ External State Changing Methods ============ */

  /**
   * @notice Callback method for all flashloan operations
   *
   * Can only be initiated by approved fluid leverage tokens
   *
   * @param assets              Assets that are flashloaning
   * @param amounts             Corresponding flashloan amounts
   * @param premiums            Corresponding flashloan fees
   * @param initiator           Address of Flashloan initiator
   * @param params              Additional data passed by FLT when the flashloan is initiated
   */
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

  /**
   * @notice Executes withdraw without using flashloans
   *
   * Useful for smaller withdraws and bypassing flashloan premiums
   * Trades withdrawn collateral to debt and repays the debt
   *
   * @param _amt                Amount of collateral withdrawing
   */
  function executeWithdraw(uint256 _amt) external {
    require(fluidLeverage[msg.sender], "not-authorized");

    IERC20 _collateral = IFluidLeverage(msg.sender).COLLATERAL_ASSET();
    IERC20 _debt = IFluidLeverage(msg.sender).DEBT_ASSET();

    require(_collateral.balanceOf(address(this)) >= _amt, "did-not-receive-trade-amt");

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

  /* ============ Internal State Changing Methods ============ */

  /**
   * @notice Called by flashloan to rebalance
   *
   * Increases the leverage by borrowing more debt and convert it to collateral
   *
   * @param _data               Flashloan data. Refer `utils/Libraries.sol`
   * @param _fluidLeverage      Address of the flashloan initiator FLT
   */
  function _rebalanceUp(DataTypes.FlashloanData memory _data, address _fluidLeverage) internal {
    require(_data.userDepositAmt == 0, "invalid-op");
    _swapDebtToCollateral(_data, _fluidLeverage);
  }

  /**
   * @notice Called by flashloan to rebalance
   *
   * Decreases the leverage by flashloaning collateral, convert it into debt and repay the debt
   *
   * @param _data               Flashloan data. Refer `utils/Libraries.sol`
   * @param _fluidLeverage      Address of the flashloan initiator FLT
   * @param _premium            Flashloan premium in collateral token
   */
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

  /**
   * @notice Called by flashloan to leverage up in each deposit
   *
   * Flashloans debt, convert it into collateral and deposit it for FLT
   * Leverage is propotional to current leverage ratio
   *
   * @param _data               Flashloan data. Refer `utils/Libraries.sol`
   * @param _fluidLeverage      Address of the flashloan initiator FLT
   */
  function _deposit(DataTypes.FlashloanData memory _data, address _fluidLeverage) internal {
    require(_data.userDepositAmt > 0, "no-deposits-found");
    IERC20 _collateral = IERC20(_data.targetAsset);
    require(_collateral.balanceOf(address(this)) >= _data.userDepositAmt, "deposit-not-received");

    _swapDebtToCollateral(_data, _fluidLeverage);
  }

  /**
   * @notice Called by flashloan to leverage down for withdrawing
   *
   * Flashloans collateral, convert it into debt, repay debt and withdraw collateral to repay flashloan
   *
   * @param _data               Flashloan data. Refer `utils/Libraries.sol`
   * @param _fluidLeverage      Address of the flashloan initiator FLT
   * @param _premium            Flashloan premium in collateral token
   */
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

  /**
   * @notice Swaps debt into collateral and deposit for FLT
   *
   * Done through Sushiswap. Prices taken from Aave oracle
   *
   * @param _data               Flashloan data. Refer `utils/Libraries.sol`
   * @param _fluidLeverage      Address of the flashloan initiator FLT
   */
  function _swapDebtToCollateral(DataTypes.FlashloanData memory _data, address _fluidLeverage) internal {
    IERC20 _collateral = IERC20(_data.targetAsset);
    IERC20 _debt = IERC20(_data.flashAsset);

    _debt.safeApprove(address(sushi), 0);
    _debt.safeApprove(address(sushi), _data.flashAmt);

    address[] memory _path = paths[_data.flashAsset][_data.targetAsset];

    uint256 _minAmt;

    {
      uint256 _debtPrice = IFluidLeverage(_fluidLeverage).getDebtPrice();
      uint256 _amt18 = wdiv(_data.flashAmt, 10 ** (_debt.decimals()));
      uint256 _idealAmt = wmul(_amt18, _debtPrice);
      uint256 _slippageAmt = _idealAmt.mul(maxSlippage).div(10000);
      uint256 _minOut = _idealAmt.sub(_slippageAmt);
      _minAmt = wmul(_minOut, 10 ** (_collateral.decimals()));
    }
    
    // Useful for testnet scenarios
    // {
    //   uint256[] memory _outAmts = sushi.getAmountsOut(_data.flashAmt, _path);
    //   uint256 _slippageAmt = _outAmts[_outAmts.length - 1].mul(maxSlippage).div(10000);
    //   _minAmt = _outAmts[_outAmts.length - 1].sub(_slippageAmt);
    // }

    uint256[] memory _amts = sushi.swapExactTokensForTokens(_data.flashAmt, _minAmt, _path, address(this), block.timestamp.add(1800));

    uint256 _totalAmt = _amts[_amts.length - 1].add(_data.userDepositAmt);

    _collateral.safeApprove(address(LENDING_POOL), 0);
    _collateral.safeApprove(address(LENDING_POOL), _totalAmt);

    LENDING_POOL.deposit(address(_collateral), _totalAmt, _fluidLeverage, 0);

    emit ConvertDebtToCollateral(
      _fluidLeverage, address(_debt), address(_collateral), _data.flashAmt, _totalAmt
    );
  }

  /**
   * @notice Swaps collateral into debt
   *
   * Done through Sushiswap. Prices taken from Aave oracle
   *
   * @param _data               Flashloan data. Refer `utils/Libraries.sol`
   * @param _fluidLeverage      Address of the flashloan initiator FLT
   */
  function _swapCollateralToDebt(DataTypes.FlashloanData memory _data, address _fluidLeverage) internal returns (uint256, uint256) {
    IERC20 _collateral = IERC20(_data.flashAsset);
    IERC20 _debt = IERC20(_data.targetAsset);

    _collateral.safeApprove(address(sushi), 0);
    _collateral.safeApprove(address(sushi), _data.flashAmt);

    address[] memory _path = paths[_data.flashAsset][_data.targetAsset];

    uint256 _minAmt;

    {
      uint256 _debtPrice = IFluidLeverage(_fluidLeverage).getDebtPrice();
      uint256 _amt18 = wdiv(_data.flashAmt, 10 ** (_collateral.decimals()));
      uint256 _idealAmt = wdiv(_amt18, _debtPrice);
      uint256 _slippageAmt = _idealAmt.mul(maxSlippage).div(10000);
      uint256 _minOut = _idealAmt.sub(_slippageAmt);
      _minAmt = wmul(_minOut, 10 ** (_debt.decimals()));
    }

    // Useful for testnet scenarios
    // {
    //   uint256[] memory _outAmts = sushi.getAmountsOut(_data.flashAmt, _path);
    //   uint256 _slippageAmt = _outAmts[_outAmts.length - 1].mul(maxSlippage).div(10000);
    //   _minAmt = _outAmts[_outAmts.length - 1].sub(_slippageAmt);
    // }

    uint256[] memory _amts = sushi.swapExactTokensForTokens(_data.flashAmt, _minAmt, _path, address(this), block.timestamp.add(1800));

    (,, uint256 _maxDebt,,,,,,) = dataProvider.getUserReserveData(address(_debt), _fluidLeverage);

    uint256 _received = _amts[_amts.length - 1];

    return (_maxDebt, _received);

    emit ConvertCollateralToDebt(
      _fluidLeverage, address(_debt), address(_collateral), _data.flashAmt, _received
    );
  }

  /* ============ Admin Methods ============ */

  /**
   * @notice Add a Sushiswap path for a pair
   *
   * @param _start              Pair token 1
   * @param _end                Pair token 2
   * @param _path               A valid Sushiswap Path
   */
  function __addTradePath(address _start, address _end, address[] calldata _path) external onlyOwner {
    require(_start == _path[0], "invalid-path");
    require(_end == _path[_path.length - 1], "invalid-path");

    paths[_start][_end] = _path;

    emit AddTradePath(_start, _end, _path);
  }

  /**
   * @notice Set maximum slippage
   *
   * @param _maxSlippage        Slippage value in 10e5 base (1% = 100)
   */
  function __setMaxSlippage(uint256 _maxSlippage) external onlyOwner {
    require(_maxSlippage <= 500, "max-slippage-too-high");

    uint256 _currentSlippage = maxSlippage;

    maxSlippage = _maxSlippage;

    emit UpdateMaxSlippage(_currentSlippage, _maxSlippage);
  }

  /**
   * @notice Add a new FLT token
   *
   * @param _lev                Address of the FLT to add
   */
  function __addFluidLeverage(address _lev) external onlyOwner {
    require(_lev != address(0x0), "invalid-address");
    fluidLeverage[_lev] = true;

    emit AddFLT(_lev);
  }

  /**
   * @notice Mark an FLT as inactive
   *
   * @param _lev                Address of the FLT to remove
   */
  function __removeFluidLeverage(address _lev) external onlyOwner {
    require(fluidLeverage[_lev], "not-active");
    fluidLeverage[_lev] = false;

    emit RemoveFLT(_lev);
  }
}