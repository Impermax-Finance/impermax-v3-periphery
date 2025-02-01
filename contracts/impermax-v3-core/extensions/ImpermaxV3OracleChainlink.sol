pragma solidity =0.5.16;
pragma experimental ABIEncoderV2;

import "./interfaces/IV3Oracle.sol";
import "./interfaces/AggregatorInterface.sol";
import "../interfaces/IERC20.sol";
import "../libraries/SafeMath.sol";
import "../libraries/Math.sol";
import "./libraries/StringHelpers.sol";

contract ImpermaxV3OracleChainlink is IV3Oracle {
	using SafeMath for uint256;
	using StringHelpers for string;

	uint constant Q128 = 2**128;
	uint constant Q96 = 2**96;
	uint constant Q48 = 2**48;
	uint constant Q32 = 2**32;

	address public admin;
	address public pendingAdmin;
	
	address public fallbackOracle;

	// Once created, token sources are immutable
	// All sources should be USD denominated
	mapping(address => address) public tokenSources;
	
	// If this is true, it prevents the admin to add the wrong source for a token by mistake
	// The admin could still add malicious sources for new tokens -> always double check a source before adding it
	bool public verifyTokenSource;
	
	event NewPendingAdmin(address oldPendingAdmin, address newPendingAdmin);
	event NewAdmin(address oldAdmin, address newAdmin);
	event NewFallbackOracle(address oldFallbackOracle, address newFallbackOracle);
	event SetVerifyTokenSource(bool enable);
	event TokenSourceCreated(address token, address source);
	
	constructor(address _admin) public {
		admin = _admin;
		verifyTokenSource = true;
		emit NewAdmin(address(0), _admin);
		emit SetVerifyTokenSource(true);
	}
	
	function oraclePriceSqrtX96(address token0, address token1) external returns (uint256 priceSqrtX96) {
		// 1. get latest prices
		address source0 = tokenSources[token0];
		address source1 = tokenSources[token1];
		if (source0 == address(0) || source1 == address(0)) {
			// fallback would be unsafe
			revert("ImpermaxV3OracleChainlink: UNSUPPORTED_PAIR");
		}
		int256 price0 = AggregatorInterface(source0).latestAnswer();
		int256 price1 = AggregatorInterface(source1).latestAnswer();
		if (price0 <= 0 || price1 <= 0) {
			require(fallbackOracle != address(0), "ImpermaxV3OracleChainlink: PRICE_CALCULATION_ERROR");
			return IV3Oracle(fallbackOracle).oraclePriceSqrtX96(token0, token1);
		}
		
		// 2. calculate delta decimals
		int256 totalDecimals0 = int256(IERC20(token0).decimals()) + AggregatorInterface(source0).decimals();
		int256 totalDecimals1 = int256(IERC20(token1).decimals()) + AggregatorInterface(source1).decimals();
		int256 deltaDecimals = totalDecimals0 - totalDecimals1;
		
		// 3. calculate the price and scale it based on delta decimals
		priceSqrtX96 = Math.sqrt(uint256(price0).mul(Q128).div(uint256(price1))).mul(Q32);
		uint scaleX96 = Q96;
		uint deltaDecimalsAbs = uint(deltaDecimals > 0 ? deltaDecimals : -deltaDecimals);
		for (uint i = 0; i < deltaDecimalsAbs; i++) {
			scaleX96 = scaleX96.mul(10);
		}
		scaleX96 = Math.sqrt(scaleX96).mul(Q48);
		if (deltaDecimals > 0) {
			priceSqrtX96 = priceSqrtX96.mul(Q96).div(scaleX96);
		} else {
			priceSqrtX96 = priceSqrtX96.mul(scaleX96).div(Q96);
		}
	}
	
	/*** Admin ***/
	
	function _addTokenSources(address[] calldata tokens, address[] calldata sources) external {
		require(msg.sender == admin, "ImpermaxV3OracleChainlink: UNAUTHORIZED");
		require(tokens.length == sources.length, "ImpermaxV3OracleChainlink: INCONSISTENT_PARAMS_LENGTH");
		for (uint i = 0; i < tokens.length; i++) {
			require(tokenSources[tokens[i]] == address(0), "ImpermaxV3OracleChainlink: TOKEN_INITIALIZED");
			if (verifyTokenSource) {
				int256 price = AggregatorInterface(sources[i]).latestAnswer();
				require(price > 100 && price < 2**112, "ImpermaxV3OracleChainlink: PRICE_OUT_OF_RANGE");
				int256 totalDecimals = int256(IERC20(tokens[i]).decimals()) + AggregatorInterface(sources[i]).decimals();
				require(totalDecimals >= 8 && totalDecimals <= 48, "ImpermaxV3OracleChainlink: DECIMALS_OUT_OF_RANGE");
				string memory symbol = IERC20(tokens[i]).symbol();
				string memory description = AggregatorInterface(sources[i]).description();
				require(description.equals(symbol.append(" / USD")), "ImpermaxV3OracleChainlink: INCONSISTENT_DESCRIPTION");
			}
			tokenSources[tokens[i]] = sources[i];
			emit TokenSourceCreated(tokens[i], sources[i]);
		}
	}

	function _setFallbackOracle(address newFallbackOracle) external {
		require(msg.sender == admin, "ImpermaxV3OracleChainlink: UNAUTHORIZED");
		address oldFallbackOracle = fallbackOracle;
		fallbackOracle = newFallbackOracle;
		emit NewFallbackOracle(oldFallbackOracle, newFallbackOracle);
	}
	
	function _setVerifyTokenSource(bool enable) external {
		require(msg.sender == admin, "ImpermaxV3OracleChainlink: UNAUTHORIZED");
		verifyTokenSource = enable;
		emit SetVerifyTokenSource(enable);
	}
	
	function _setPendingAdmin(address newPendingAdmin) external {
		require(msg.sender == admin, "ImpermaxV3OracleChainlink: UNAUTHORIZED");
		address oldPendingAdmin = pendingAdmin;
		pendingAdmin = newPendingAdmin;
		emit NewPendingAdmin(oldPendingAdmin, newPendingAdmin);
	}

	function _acceptAdmin() external {
		require(msg.sender == pendingAdmin, "ImpermaxV3OracleChainlink: UNAUTHORIZED");
		address oldAdmin = admin;
		address oldPendingAdmin = pendingAdmin;
		admin = pendingAdmin;
		pendingAdmin = address(0);
		emit NewAdmin(oldAdmin, admin);
		emit NewPendingAdmin(oldPendingAdmin, address(0));
	}
}