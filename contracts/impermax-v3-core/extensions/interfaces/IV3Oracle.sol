pragma solidity >=0.5.0;
pragma experimental ABIEncoderV2;

interface IV3Oracle {
	function oraclePriceSqrtX96(address token0, address token1) external returns (uint256);
}
