pragma solidity =0.5.16;

import "./BStorage.sol";
import "./PoolToken.sol";
import "./interfaces/IFactory.sol";

contract BSetter is PoolToken, BStorage {

	uint public constant RESERVE_FACTOR_MAX = 0.20e18; //20%
	uint public constant KINK_UR_MIN = 0.50e18; //50%
	uint public constant KINK_UR_MAX = 0.99e18; //99%
	uint public constant ADJUST_SPEED_MIN = 0.05787037e12; //0.5% per day
	uint public constant ADJUST_SPEED_MAX = 57.87037e12; //500% per day

	event NewReserveFactor(uint newReserveFactor);
	event NewKinkUtilizationRate(uint newKinkUtilizationRate);
	event NewAdjustSpeed(uint newAdjustSpeed);
	event NewDebtCeiling(uint newDebtCeiling);
	
	// called once by the factory at time of deployment
	function _initialize (
		string calldata _name, 
		string calldata _symbol,
		address _underlying, 
		address _collateral
	) external {
		require(msg.sender == factory, "ImpermaxV3Borrowable: UNAUTHORIZED"); // sufficient check
		_setName(_name, _symbol);
		underlying = _underlying;
		collateral = _collateral;
		exchangeRateLast = initialExchangeRate;
	}
	
	function _setReserveFactor(uint newReserveFactor) external nonReentrant onlyAdmin {
		_checkSetting(newReserveFactor, 0, RESERVE_FACTOR_MAX);
		reserveFactor = newReserveFactor;
		emit NewReserveFactor(newReserveFactor);
	}

	function _setKinkUtilizationRate(uint newKinkUtilizationRate) external nonReentrant onlyAdmin {
		_checkSetting(newKinkUtilizationRate, KINK_UR_MIN, KINK_UR_MAX);
		kinkUtilizationRate = newKinkUtilizationRate;
		emit NewKinkUtilizationRate(newKinkUtilizationRate);
	}

	function _setAdjustSpeed(uint newAdjustSpeed) external nonReentrant onlyAdmin {
		_checkSetting(newAdjustSpeed, ADJUST_SPEED_MIN, ADJUST_SPEED_MAX);
		adjustSpeed = newAdjustSpeed;
		emit NewAdjustSpeed(newAdjustSpeed);
	}

	function _setDebtCeiling(uint newDebtCeiling) external nonReentrant onlyAdmin {
		debtCeiling = newDebtCeiling;
		emit NewDebtCeiling(newDebtCeiling);
	}
	
	function _checkSetting(uint parameter, uint min, uint max) internal view {
		require(parameter >= min, "ImpermaxV3Borrowable: INVALID_SETTING");
		require(parameter <= max, "ImpermaxV3Borrowable: INVALID_SETTING");
	}

	modifier onlyAdmin() {
		require(msg.sender == IFactory(factory).admin(), "ImpermaxV3Borrowable: UNAUTHORIZED");
		_;
	}
}