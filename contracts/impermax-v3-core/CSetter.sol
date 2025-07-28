pragma solidity =0.5.16;

import "./CStorage.sol";
import "./ImpermaxERC721.sol";
import "./interfaces/IFactory.sol";

contract CSetter is ImpermaxERC721, CStorage {

	uint public constant SAFETY_MARGIN_SQRT_MIN = 1.00e18; //safetyMargin: 100%
	uint public constant SAFETY_MARGIN_SQRT_MAX = 1.58113884e18; //safetyMargin: 250%
	uint public constant LIQUIDATION_INCENTIVE_MIN = 1.00e18; //100%
	uint public constant LIQUIDATION_INCENTIVE_MAX = 1.05e18; //105%
	uint public constant LIQUIDATION_FEE_MAX = 0.08e18; //8%
	
	event NewSafetyMargin(uint newSafetyMarginSqrt);
	event NewLiquidationIncentive(uint newLiquidationIncentive);
	event NewLiquidationFee(uint newLiquidationFee);

	// called once by the factory
	function _setFactory() external {
		require(factory == address(0), "ImpermaxV3Collateral: FACTORY_ALREADY_SET");
		factory = msg.sender;
	}
	
	function _initialize (
		string calldata _name,
		string calldata _symbol,
		address _underlying, 
		address _borrowable0, 
		address _borrowable1
	) external {
		require(msg.sender == factory, "ImpermaxV3Collateral: UNAUTHORIZED"); // sufficient check
		_setName(_name, _symbol);
		underlying = _underlying;
		borrowable0 = _borrowable0;
		borrowable1 = _borrowable1;
	}

	function _setSafetyMarginSqrt(uint newSafetyMarginSqrt) external nonReentrant {
		_checkSetting(newSafetyMarginSqrt, SAFETY_MARGIN_SQRT_MIN, safetyMarginSqrt);
		safetyMarginSqrt = newSafetyMarginSqrt;
		emit NewSafetyMargin(newSafetyMarginSqrt);
	}

	function _setLiquidationIncentive(uint newLiquidationIncentive) external nonReentrant {
		_checkSetting(newLiquidationIncentive, LIQUIDATION_INCENTIVE_MIN, liquidationIncentive);
		liquidationIncentive = newLiquidationIncentive;
		emit NewLiquidationIncentive(newLiquidationIncentive);
	}

	function _setLiquidationFee(uint newLiquidationFee) external nonReentrant {
		_checkSetting(newLiquidationFee, 0, liquidationFee);
		liquidationFee = newLiquidationFee;
		emit NewLiquidationFee(newLiquidationFee);
	}
	
	function _checkSetting(uint parameter, uint min, uint max) internal view {
		_checkAdmin();
		require(parameter >= min, "ImpermaxV3Collateral: INVALID_SETTING");
		require(parameter <= max, "ImpermaxV3Collateral: INVALID_SETTING");
	}
	
	function _checkAdmin() internal view {
		require(msg.sender == IFactory(factory).admin(), "ImpermaxV3Collateral: UNAUTHORIZED");
	}
	
	/*** Utilities ***/
	
	// prevents a contract from calling itself, directly or indirectly.
	bool internal _notEntered = true;
	modifier nonReentrant() {
		require(_notEntered, "ImpermaxV3Collateral: REENTERED");
		_notEntered = false;
		_;
		_notEntered = true;
	}
}