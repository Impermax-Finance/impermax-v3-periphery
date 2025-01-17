pragma solidity =0.5.16;

import "./TickMath.sol";
import "./LiquidityAmounts.sol";
import "../impermax-v3-core/extensions/interfaces/IUniswapV3Pool.sol";

library UniswapV3Math {
	
	function optimalLiquidity(
		address uniswapV3Pool,
		int24 tickLower,
		int24 tickUpper,
		uint amount0Desired,
		uint amount1Desired,
		uint amount0Min,
		uint amount1Min
	) external view returns (uint128 liquidity, uint amount0, uint amount1) {		
		(uint160 sqrtPriceX96, , , , , , ) = IUniswapV3Pool(uniswapV3Pool).slot0();
		uint160 sqrtRatioAX96 = TickMath.getSqrtRatioAtTick(tickLower);
		uint160 sqrtRatioBX96 = TickMath.getSqrtRatioAtTick(tickUpper);

		liquidity = LiquidityAmounts.getLiquidityForAmounts(
			sqrtPriceX96,
			sqrtRatioAX96,
			sqrtRatioBX96,
			amount0Desired,
			amount1Desired
		);
		// get amountsOut
		(amount0, amount1) = LiquidityAmounts.getAmountsForLiquidity(
			sqrtPriceX96,
			sqrtRatioAX96,
			sqrtRatioBX96,
			liquidity
		);
		// round up to get amountsIn
		if (amount0 < amount0Desired) amount0++; 
		if (amount1 < amount1Desired) amount1++; 
		
		require(amount0 >= amount0Min, "ImpermaxRouter: INSUFFICIENT_0_AMOUNT");
		require(amount1 >= amount1Min, "ImpermaxRouter: INSUFFICIENT_1_AMOUNT");
	}
	
}