pragma solidity =0.5.16;
pragma experimental ABIEncoderV2;

import "./SafeMath.sol";
import "../interfaces/INFTLP.sol";

library CollateralMath {
	using SafeMath for uint;

    uint constant Q64 = 2**64;
    uint constant Q96 = 2**96;
    uint constant Q192 = 2**192;
	
	enum Price {LOWEST, CURRENT, HIGHEST}

	struct PositionObject {
		INFTLP.RealXYs realXYs;
		uint priceSqrtX96;
		uint debtX;
		uint debtY;
		uint liquidationPenalty;
		uint safetyMarginSqrt;
	}
	
	function newPosition(
		INFTLP.RealXYs memory realXYs,
		uint priceSqrtX96,
		uint debtX,
		uint debtY,
		uint liquidationPenalty,
		uint safetyMarginSqrt
	) internal pure returns (PositionObject memory) {
		return PositionObject({
			realXYs: realXYs,
			priceSqrtX96: priceSqrtX96,
			debtX: debtX,
			debtY: debtY,
			liquidationPenalty: liquidationPenalty,
			safetyMarginSqrt: safetyMarginSqrt
		});
	}
	
    function safeInt256(uint256 n) internal pure returns (int256) {
        require(n < 2**255, "Impermax: SAFE_INT");
        return int256(n);
    }
	
	// price
	function getRelativePriceX(uint priceSqrtX96) internal pure returns (uint) {
		return priceSqrtX96;
	}
	// 1 / price
	function getRelativePriceY(uint priceSqrtX96) internal pure returns (uint) {
		return Q192.div(priceSqrtX96);
	}
	
	// amountX * priceX + amountY * priceY
	function getValue(PositionObject memory positionObject, Price price, uint amountX, uint amountY) internal pure returns (uint) {
		uint priceSqrtX96 = positionObject.priceSqrtX96;
		if (price == Price.LOWEST) priceSqrtX96 = priceSqrtX96.mul(1e18).div(positionObject.safetyMarginSqrt);
		if (price == Price.HIGHEST) priceSqrtX96 = priceSqrtX96.mul(positionObject.safetyMarginSqrt).div(1e18);
		uint relativePriceX = getRelativePriceX(priceSqrtX96);
		uint relativePriceY = getRelativePriceY(priceSqrtX96);
		return amountX.mul(relativePriceX).div(Q64).add(amountY.mul(relativePriceY).div(Q64));
	}
	
	// realX * priceX + realY * priceY
	function getCollateralValue(PositionObject memory positionObject, Price price) internal pure returns (uint) {
		INFTLP.RealXY memory realXY = positionObject.realXYs.currentPrice;
		if (price == Price.LOWEST) realXY = positionObject.realXYs.lowestPrice;
		if (price == Price.HIGHEST) realXY = positionObject.realXYs.highestPrice;
		return getValue(positionObject, price, realXY.realX, realXY.realY);
	}

	// debtX * priceX + realY * debtY	
	function getDebtValue(PositionObject memory positionObject, Price price) internal pure returns (uint) {
		return getValue(positionObject, price, positionObject.debtX, positionObject.debtY);
	}
	
	// collateralValue - debtValue * liquidationPenalty
	function getLiquidityPostLiquidation(PositionObject memory positionObject, Price price) internal pure returns (int) {
		uint collateralNeeded = getDebtValue(positionObject, price).mul(positionObject.liquidationPenalty).div(1e18);
		uint collateralValue = getCollateralValue(positionObject, price);
		return safeInt256(collateralValue) - safeInt256(collateralNeeded);
	}
	
	// collateralValue / (debtValue * liquidationPenalty)
	function getPostLiquidationCollateralRatio(PositionObject memory positionObject) internal pure returns (uint) {
		uint collateralNeeded = getDebtValue(positionObject, Price.CURRENT).mul(positionObject.liquidationPenalty).div(1e18);
		uint collateralValue = getCollateralValue(positionObject, Price.CURRENT);
		return collateralValue.mul(1e18).div(collateralNeeded, "ImpermaxV3Collateral: NO_DEBT");
	}
	
	function isLiquidatable(PositionObject memory positionObject) internal pure returns (bool) {
		int a = getLiquidityPostLiquidation(positionObject, Price.LOWEST);
		int b = getLiquidityPostLiquidation(positionObject, Price.HIGHEST);
		return a < 0 || b < 0;
	}
	
	function isUnderwater(PositionObject memory positionObject) internal pure returns (bool) {
		int liquidity = getLiquidityPostLiquidation(positionObject, Price.CURRENT);
		return liquidity < 0;
	}
}