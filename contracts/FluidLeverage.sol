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

/**
 * @title DangoFluidLeverageToken
 * @author Dango.Cafe
 */
contract DangoFluidLeverageToken is Initializable, ERC20Upgradeable, OwnableUpgradeable, ReentrancyGuardUpgradeable, DangoMath {
  using SafeMathUpgradeable for uint256;
  using SafeERC20 for IERC20;

  /* ============ Constants ============ */

  uint256 public constant REBALANCE_DELAY = 86400;                                // Length of 1 epoch in seconds. 1 Day
  uint256 public constant REBALANCE_GRACE_PERIOD = 7200;                          // Grace period for rebalancing in seconds. 2 hours

  /* ============ Immutables ============ */

  uint8 private immutable debtDecimals;                                           // Collateral token decimals
  uint8 private immutable collDecimals;                                           // Debt token decimals

  ILendingPoolAddressesProvider public immutable AAVE_ADDRESSES_PROVIDER;         // Address of Aave Lending Pool Address Provider
  IProtocolDataProvider public immutable AAVE_DATA_PROVIDER;                      // Address of Aave Protocol Data Provider
  IERC20 public immutable COLLATERAL_ASSET;                                       // Collateral Token Instance
  IERC20 public immutable DEBT_ASSET;                                             // Debt Token Instance

  uint256 public immutable targetLeverageRatio;                                   // Target Leverage ratio
  uint256 public immutable lowerLeverageLimit;                                    // Lowest possible leverage ratio that doesn't trigger emergency rebalancing
  uint256 public immutable upperLeverageLimit;                                    // Maxium possible leverage ratio that doesn't trigger emergency rebalancing

  /* ============ State Variables ============ */

  ILendingPool public AAVE_LENDING_POOL;                                          // Aave Lending Pool instance
  IPriceOracleGetter public AAVE_ORACLE;                                          // Aave Oracle instance
  address public flashloanAdapter;                                                // Address of Flashloan Adapter
  address public feeCollector;                                                    // Address of the fee collector
  uint256 public mintFee;                                                         // Mint fee in wei (1e18 = 100%, 1e16 = 1%)
  uint256 public burnFee;                                                         // Burn fee in wei (1e18 = 100%, 1e16 = 1%)
  uint256 public indexPrice;                                                      // Last tracked index price of the Fluid Leverage Token in collateral token
  uint256 public lastRebalancingTime;                                             // Timestamp of the last rebalancing time
  uint256 public totalCapacity;                                                   // Current total deposit capacity
  mapping(address => bool) rebalancers;                                           // Whitelist of rebalancers

  /* ============ Modifiers ============ */

  /**
   * Throws error if sender is not Flashloan Adapter contract
   */
  modifier onlyFlashloanAdapter() {
    require(msg.sender == flashloanAdapter, "access-denied-not-flashloan-adapter");
    _;
  }

  /* ============ Events ============ */

  event Rebalanced(
    bool indexed _isEmergency,                  // Whether the rebalancing is emergency
    uint256 _currentLeverageRatio,              // Leverage ratio before the rebalancing
    uint256 _newLeverageRatio                   // Leverage ratio after the rebalancing
  );

  event Deposit(
    address indexed _user,                      // User address
    uint256 _amtCollateral,                     // Amount of collateral deposited
    uint256 _amtMinted,                         // Amount of fluid leverage tokens minted
    uint256 _currentLeverageRatio               // Leverage ratio upon deposit
  );

  event Withdraw(
    address indexed _user,                      // User address
    bool _isFlashloan,                          // Whether the withdraw was done by flashloan
    uint256 _amtWithdrawn,                      // Amount of collateral withdrawn
    uint256 _amtBurned,                         // Amount fluid leverage tokens burned
    uint256 _currentLeverageRatio               // Leverage ratio upon withdraw
  );

  event UpdateFlashloanAdapter(
    address _currentFlashloanAdapter,           // Address of the flashloan adpater before updating
    address _newFlashloanAdapter                // Address of the new flashloan adapter
  );

  event UpdateFeeCollector(
    address _currentFeeCollector,               // Address of the fee collector before updating
    address _newFeeCollector                    // Address of the new fee collector
  );

  event UpdateFees(
    uint256 _currentMintFee,                    // Mint fees before updating
    uint256 _currentBurnFee,                    // Burn fees before updating
    uint256 _newMintFee,                        // New mint fees
    uint256 _newBurnFee                         // New burn fees
  );

  event IncreaseCapacity(
    uint256 _currentCapacity,                   // Current deposit limit
    uint256 _newCapacity                        // New deposit limit
  );

  event WhitelistRebalancers(
    address[] _whitelisted                      // Array of new whitelisted addresses
  );

  event RevokeRebalancers(
    address[] _revoked                          // Array of revoked addresses
  );

  /* ============ Constructor ============ */

  /**
   * Sets the values for immutables
   *
   * @param _provider           Address of Aave Lending Pool Address Provider
   * @param _dataProvider       Address of Aave Protocol Data Provider
   * @param _collateral         Address of the collateral token
   * @param _debt               Address of the debt token
   * @param _target             Target leverage ratio in wei (2e18 = 2x leverage)
   * @param _lower              Lowest possible leverage ratio that doesn't trigger emergency rebalancing
   * @param _upper              Maxium possible leverage ratio that doesn't trigger emergency rebalancing
   */
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

  /* ============ Initializer ============ */

  /**
   * Initializes state variables & inheritted contracts
   *
   * @param _name               Name of the Fluid Leverage Token
   * @param _symbol             Symbol of the Fluid Leverage Token
   * @param _flashloanAdapter   Address of flashloan adapter / receiver base
   * @param _feeCollector       Address of the fee collector
   * @param _mintFee            Initial minting fee (in wei; 1e18 = 100%)
   * @param _burnFee            Initital burn fee (in wei; 1e18 = 100%)
   * @param _capacity           Initial deposit limit (in wei)
   * @param _rebalancers        Addresses of whitelisted rebalancers
   */
  function initialize(
    string calldata _name,
    string calldata _symbol,
    address _flashloanAdapter,
    address _feeCollector,
    uint256 _mintFee,
    uint256 _burnFee,
    uint256 _capacity,
    address[] memory _rebalancers
  ) initializer public {
    require(_mintFee <= 1e16, "mint-fee-too-large");
    require(_burnFee <= 3e16, "burn-fee-too-large");

    __Ownable_init();
    __ERC20_init(_name, _symbol);
    __ReentrancyGuard_init();

    AAVE_LENDING_POOL = ILendingPool(AAVE_ADDRESSES_PROVIDER.getLendingPool());
    AAVE_ORACLE = IPriceOracleGetter(AAVE_ADDRESSES_PROVIDER.getPriceOracle());

    indexPrice = 1e18;
    flashloanAdapter = _flashloanAdapter;
    feeCollector = _feeCollector;
    mintFee = _mintFee;
    burnFee = _burnFee;
    totalCapacity = _capacity;
    lastRebalancingTime = block.timestamp;

    for (uint256 index = 0; index < _rebalancers.length; index++) {
      rebalancers[_rebalancers[index]] = true;
    }
  }

  /* ============ User Facing State Changing Methods ============ */

  /**
   * @notice Mint Fluid Leverage Token by depositting the collateral token
   *
   * Charges minting fee based on the current value of `mintFee`
   * Flashloans propotional amount of debt and swaps into collateral to achieve current leverage ratio (No Flashloan fees)
   *
   * @param _amt               Amount of collateral to deposit
   */
  function deposit(uint256 _amt) external nonReentrant {
    (uint256 _fee, uint256 _finalAmt) = _calculateMintFee(_amt);
    COLLATERAL_ASSET.safeTransferFrom(msg.sender, flashloanAdapter, _finalAmt);
    COLLATERAL_ASSET.safeTransferFrom(msg.sender, feeCollector, _fee);

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

    require(totalSupply() <= totalCapacity, "deposit-limit-hit");

    emit Deposit(msg.sender, _amt, _amtToMint, getCurrentLeverRatio());
  }

  /**
   * @notice Burn Fluid Leverage Tokens and redeem it for collateral
   *
   * Charges burning fee based on the current value of `burnFee`
   * This method doesn't use flashloan, and hence only useful for small withdrawals
   * Withdraws collateral, and convert some of them to debt token and repay the debt
   *
   * @param _amt               Amount of fluid leverage tokens to burn
   */
  function withdraw(uint256 _amt) external nonReentrant {
    require(balanceOf(msg.sender) >= _amt, "not-enough-bal");

    uint256 _amtToReturn = wmul(_amt, getIndex());
    uint256 _multiplier = getCurrentLeverRatio().sub(1e18);
    uint256 _amtToFlash = wmul(_amtToReturn, _multiplier);

    if (collDecimals != 18) {
      _amtToFlash = wmul(_amtToFlash, 10 ** collDecimals);
      _amtToReturn = wmul(_amtToReturn, 10 ** collDecimals);
    }

    uint256 _totalWithdraw = _amtToReturn.add(_amtToFlash);

    _withdrawCollateral(_totalWithdraw, address(this));
    COLLATERAL_ASSET.safeTransfer(flashloanAdapter, _amtToFlash);
    IFlashloanAdapter(flashloanAdapter).executeWithdraw(_amtToFlash);

    (uint256 _fee, uint256 _finalAmt) = _calculateBurnFee(_amtToReturn);
    COLLATERAL_ASSET.safeTransfer(feeCollector, _fee);
    COLLATERAL_ASSET.safeTransfer(msg.sender, _finalAmt);

    _burn(msg.sender, _amt);

    emit Withdraw(msg.sender, false, _amtToReturn, _amt, getCurrentLeverRatio());
  }

  /**
   * @notice Burn Fluid Leverage Tokens and redeem it for collateral (using Flashloan)
   *
   * Charges burning fee based on the current value of `burnFee`
   * Similar to `withdraw`, but using flashloan. Has additional flashloan fees (0.09% charged by Aave)
   * Useful for large withdrawals
   *
   * @param _amt               Amount of fluid leverage tokens to burn
   */
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

    emit Withdraw(msg.sender, true, _amtToReturn, _amt, getCurrentLeverRatio());
  }

  /* ============ Non-User Facing State Changing Methods ============ */

  /**
   * @notice Rebalance collateral and debt into target leverage ratio
   *
   * Called by once a day. Can only be called by whitelisted `rebalancers`
   */
  function rebalance() external nonReentrant {
    require(rebalancers[msg.sender], "not-a-rebalancer");
    require(block.timestamp > lastRebalancingTime.add(REBALANCE_DELAY).sub(REBALANCE_GRACE_PERIOD), "too-soon-to-rebalance");
    require(block.timestamp < lastRebalancingTime.add(REBALANCE_DELAY).add(REBALANCE_GRACE_PERIOD), "rebalancing-time-over");

    uint256 _oldLeverageRatio = getCurrentLeverRatio();

    _rebalance();

    lastRebalancingTime = block.timestamp;

    emit Rebalanced(false, _oldLeverageRatio, getCurrentLeverRatio());
  }

  /**
   * @notice Rebalance collateral and debt into target leverage ratio in emergency cases
   *
   * Called only when one of the emergency conditions are satisfied
   * Condition 1 - There are no rebalances in the last 1.5 epoch
   * Condition 2 - Leverage ratio goes out of the < `lowerLeverageLimit` - `upperLeverageLimit` > range
   */
  function emergencyRebalance() external nonReentrant {
    bool _leverCondition = getCurrentLeverRatio() < lowerLeverageLimit || getCurrentLeverRatio() > upperLeverageLimit;
    bool _timeCondition = block.timestamp > lastRebalancingTime.add(REBALANCE_DELAY).add(REBALANCE_DELAY.div(2));

    require(_leverCondition || _timeCondition, "cannot-invoke-emergency-rebalance");

    uint256 _oldLeverageRatio = getCurrentLeverRatio();

    _rebalance();

    lastRebalancingTime = block.timestamp;

    emit Rebalanced(true, _oldLeverageRatio, getCurrentLeverRatio());
  }

  /* ============ View Methods ============ */

  /**
   * @notice Returns current Leverage Ratio
   */
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

  /**
   * @notice Returns current Debt price in Collateral. Price taken from Aave Oracle
   */
  function getDebtPrice() public view returns (uint256 _debtPrice) {
    uint256 _collateralPriceEth = AAVE_ORACLE.getAssetPrice(address(COLLATERAL_ASSET));
    uint256 _debtPriceEth = AAVE_ORACLE.getAssetPrice(address(DEBT_ASSET));

    _debtPrice = wdiv(_debtPriceEth, _collateralPriceEth);
  }

  /**
   * @notice Returns current index price of Fluid Leverage Token (priced in collateral)
   */
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

  /* ============ Internal View Methods ============ */

  /**
   * @notice Calculates Mint Fee
   *
   * @param _amt               Input amount
   *
   * @return _feeAmt           Fee charged on input amount
   * @return _amtSubFee        Amount after deducting the fee amount
   */
  function _calculateMintFee(uint256 _amt) internal view returns (uint256 _feeAmt, uint256 _amtSubFee) {
    _feeAmt = wmul(_amt, mintFee);
    _amtSubFee = _amt.sub(_feeAmt);
  }

  /**
   * @notice Calculates Burn Fee
   *
   * @param _amt               Input amount
   *
   * @return _feeAmt           Fee charged on input amount
   * @return _amtSubFee        Amount after deducting the fee amount
   */
  function _calculateBurnFee(uint256 _amt) internal view returns (uint256 _feeAmt, uint256 _amtSubFee) {
    _feeAmt = wmul(_amt, burnFee);
    _amtSubFee = _amt.sub(_feeAmt);
  }

  /* ============ Internal State Changing Methods ============ */

  /**
   * @notice Invokes Aave Flashloan
   *
   * @param _asset             Address of the asset needed for flashloan
   * @param _amt               Amount to flashloan
   * @param _data              Data to transfer to Flashloan Adapter
   */
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

  /**
   * @notice Withdraw collateral
   *
   * @param _amt               Amount to withdraw
   * @param _to                Address to receive the collateral
   */
  function _withdrawCollateral(uint256 _amt, address _to) internal {
    AAVE_LENDING_POOL.withdraw(address(COLLATERAL_ASSET), _amt, _to);
  }

  /**
   * @notice Internal rebalancing logic
   *
   * Increases the leverage if the strategy has made improvement in the last epoch, deleverage otherwise (Uses flashloan)
   */
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

  /* ============ Admin Methods ============ */

  /**
   * @notice Update Aave lending pool address, only needs to call if that has been upgraded
   */
  function __updateAaveLendingPool() external onlyOwner {
    AAVE_LENDING_POOL = ILendingPool(AAVE_ADDRESSES_PROVIDER.getLendingPool());
  }

  /**
   * @notice Update Aave oracle address, only needs to call if that has been upgraded
   */
  function __updateAaveOracle() external onlyOwner {
    AAVE_ORACLE = IPriceOracleGetter(AAVE_ADDRESSES_PROVIDER.getPriceOracle());
  }

  /**
   * @notice Update flashloan adapter address
   *
   * @param _newAdapter        Address of the new flashloan adapter
   */
  function __changeFlashloanAdapter(address _newAdapter) external onlyOwner {
    require(_newAdapter != address(0x0), "invalid-address");

    address _currentFlashloanAdapter = flashloanAdapter;

    flashloanAdapter = _newAdapter;

    emit UpdateFlashloanAdapter(_currentFlashloanAdapter, _newAdapter);
  }

  /**
   * @notice Update fee collector address
   *
   * @param _newCollector      Address of the new fee collector
   */
  function __changeFeeCollector(address _newCollector) external onlyOwner {
    require(_newCollector != address(0x0), "invalid-address");

    address _currentFeeCollector = feeCollector;

    feeCollector = _newCollector;

    emit UpdateFeeCollector(_currentFeeCollector, _newCollector);
  }

  /**
   * @notice Update minting and burning fees
   *
   * @param _mintFee           New mint fee
   * @param _burnFee           New burn fee
   */
  function __changeFees(uint256 _mintFee, uint256 _burnFee) external onlyOwner {
    require(_mintFee <= 1e16, "mint-fee-too-large");
    require(_burnFee <= 3e16, "burn-fee-too-large");

    uint256 _currentMintFee = mintFee;
    uint256 _currentBurnFee = burnFee;

    mintFee = _mintFee;
    burnFee = _burnFee;

    emit UpdateFees(_currentMintFee, _currentBurnFee, _mintFee, _burnFee);
  }

  /**
   * @notice Increase deposit capacity
   *
   * @param _newCapacity       New mint fee
   */
  function __increaseTotalCapacity(uint256 _newCapacity) external onlyOwner {
    require(_newCapacity > totalCapacity, "cannot-decrease-capacity");

    uint256 _currentCapacity = totalCapacity;

    totalCapacity = _newCapacity;

    emit IncreaseCapacity(_currentCapacity, _newCapacity);
  }

  /**
   * @notice Whitelist rebalancers
   *
   * @param _rebalancers       Array of rebalancers addresses to whitelist
   */
  function __whitelistRebalancers(address[] memory _rebalancers) external onlyOwner {
    for (uint256 index = 0; index < _rebalancers.length; index++) {
      rebalancers[_rebalancers[index]] = true;
    }

    emit WhitelistRebalancers(_rebalancers);
  }

  /**
   * @notice Revoke rebalancers
   *
   * @param _rebalancers       Array of rebalancers addresses to revoke access
   */
  function __revokeRebalancers(address[] memory _rebalancers) external onlyOwner {
    for (uint256 index = 0; index < _rebalancers.length; index++) {
      rebalancers[_rebalancers[index]] = false;
    }

    emit RevokeRebalancers(_rebalancers);
  }

  /**
   * @notice Withdraw collateral. Only called by flashloan adapter
   *
   * @param _amt               Amount of collateral to withdraw
   */
  function __withdrawCollateral(uint256 _amt) external onlyFlashloanAdapter {
    _withdrawCollateral(_amt, flashloanAdapter);
  }

}
