pragma solidity >=0.5.0;
pragma experimental ABIEncoderV2;

import "../interfaces/INonfungiblePositionManagerAero.sol";
import "../../interfaces/IERC20.sol";
import "../../libraries/SafeMath.sol";

library NfpmAeroInteractions {
	using SafeMath for uint256;
	
	function prepareTransfer(address nfpManager, address token0, address token1) private returns (uint amount0, uint amount1) {
		if (IERC20(token0).allowance(address(this), nfpManager) == 0)
			IERC20(token0).approve(nfpManager, uint(-1));
		if (IERC20(token1).allowance(address(this), nfpManager) == 0)
			IERC20(token1).approve(nfpManager, uint(-1));
			
		amount0 = IERC20(token0).balanceOf(address(this));
		amount1 = IERC20(token1).balanceOf(address(this));
	}
	
	function mint(
		address nfpManager,
		address token0,
		address token1,
		int24 tickSpacing,
		int24 tickLower,
		int24 tickUpper,
		address recipient
	) public returns (uint256 tokenId, uint128 liquidity) {
		(uint256 amount0, uint256 amount1) = prepareTransfer(nfpManager, token0, token1);
		(tokenId, liquidity,,) = INonfungiblePositionManagerAero(nfpManager).mint(
			INonfungiblePositionManagerAero.MintParams({
				token0: token0,
				token1: token1,
				tickSpacing: tickSpacing,
				tickLower: tickLower,
				tickUpper: tickUpper,
				amount0Desired: amount0,
				amount1Desired: amount1,
				amount0Min: 0,
				amount1Min: 0,
				recipient: recipient,
				deadline: uint(-1),
				sqrtPriceX96: 0
			})
		);
	}

	function increase(address nfpManager, uint256 tokenId) external returns (uint128 newLiquidity, uint128 totalLiquidity, uint256 amount0, uint256 amount1) {
		(,,address token0, address token1,,,, uint256 initialLiquidity) = INonfungiblePositionManagerAero(nfpManager).positions(tokenId);
		(amount0, amount1) = prepareTransfer(nfpManager, token0, token1);
		(newLiquidity, amount0, amount1) = INonfungiblePositionManagerAero(nfpManager).increaseLiquidity(
			INonfungiblePositionManagerAero.IncreaseLiquidityParams({
				tokenId: tokenId,
				amount0Desired: amount0,
				amount1Desired: amount1,
				amount0Min: 0,
				amount1Min: 0,
				deadline: uint(-1)
			})
		);
		totalLiquidity = safe128(initialLiquidity.add(newLiquidity));
	}
	
	function decrease(address nfpManager, uint256 tokenId, uint256 percentage, address to, uint amount0Min, uint amount1Min) public returns (uint256 amount0, uint256 amount1, uint128 liquidityToRemove, uint128 totalLiquidity) {
		require(percentage <= 1e18, "NfpmAeroInteractions: ABOVE_100_PERCENT");
		(,,,,,,,uint256 initialLiquidity) = INonfungiblePositionManagerAero(nfpManager).positions(tokenId);
		liquidityToRemove = safe128(percentage.mul(initialLiquidity).div(1e18));
		(amount0, amount1) = INonfungiblePositionManagerAero(nfpManager).decreaseLiquidity(
			INonfungiblePositionManagerAero.DecreaseLiquidityParams({
				tokenId: tokenId,
				liquidity: liquidityToRemove,
				amount0Min: amount0Min,
				amount1Min: amount1Min,
				deadline: uint256(-1)
			})
		);
		INonfungiblePositionManagerAero(nfpManager).collect(
			INonfungiblePositionManagerAero.CollectParams({
				tokenId: tokenId,
				recipient: to,
				amount0Max: uint128(-1),
				amount1Max: uint128(-1)
			})
		);
		if (percentage == 1e18) INonfungiblePositionManagerAero(nfpManager).burn(tokenId);
		totalLiquidity = safe128(initialLiquidity.sub(liquidityToRemove));
	}
	
	function decreaseAndMint(address nfpManager, uint256 tokenId, uint256 percentage) external returns (uint256 newTokenId, uint128 oldTokenLiquidity, uint128 newTokenLiquidity) {
		(,,address token0,address token1,int24 tickSpacing,int24 tickLower,int24 tickUpper,) = INonfungiblePositionManagerAero(nfpManager).positions(tokenId);
		(,,, oldTokenLiquidity) = decrease(nfpManager, tokenId, percentage, address(this), 0, 0);
		(newTokenId, newTokenLiquidity) = mint(nfpManager, token0, token1, tickSpacing, tickLower, tickUpper, address(this));
	}

	function safe128(uint n) internal pure returns (uint128) {
		require(n < 2**128, "Impermax: SAFE128");
		return uint128(n);
	}
}