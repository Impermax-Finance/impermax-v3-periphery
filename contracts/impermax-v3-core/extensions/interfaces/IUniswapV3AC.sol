pragma solidity >=0.5.0;
pragma experimental ABIEncoderV2;

import "./ITokenizedUniswapV3Position.sol";

interface IUniswapV3AC {
	function getToCollect(
		ITokenizedUniswapV3Position.Position calldata position, 
		uint256 tokenId, 
		uint256 feeCollected0, 
		uint256 feeCollected1
	) external returns (uint256 collect0, uint256 collect1, bytes memory data);
	
	function mintLiquidity(
		address bountyTo, 
		bytes calldata data
	) external returns (uint256 bounty0, uint256 bounty1);
}
