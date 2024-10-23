pragma solidity >=0.5.0;
pragma experimental ABIEncoderV2;

import "../../interfaces/INFTLP.sol";

interface ITokenizedUniswapV2Position {
	
	// ERC-721
	
	function ownerOf(uint256 _tokenId) external view returns (address);
	function safeTransferFrom(address from, address to, uint256 tokenId, bytes calldata data) external;
	function safeTransferFrom(address from, address to, uint256 tokenId) external;
	function transferFrom(address from, address to, uint256 tokenId) external;
	
	// INFTLP
	
	function token0() external view returns (address);
	function token1() external view returns (address);
	function getPositionData(uint256 _tokenId, uint256 _safetyMarginSqrt) external returns (
		uint256 priceSqrtX96,
		INFTLP.RealXYs memory realXYs
	);
	
	function join(uint256 tokenIdFrom, uint256 tokenIdTo) external;
	function split(uint256 tokenId, uint256 percentage) external returns (uint256 newTokenId);
	
	// ITokenizedUniswapV2Position
	
	function factory() external view returns (address);
	function simpleUniswapOracle() external view returns (address);
	function underlying() external view returns (address);
	function totalBalance() external view returns (uint256);
	
	function liquidity(uint256) external view returns (uint256);
	function positionLength() external view returns (uint256);
	
	function oraclePriceSqrtX96() external returns (uint256);
	
	event UpdatePositionLiquidity(uint256 indexed tokenId, uint256 liquidity);

	function _initialize (
		address _underlying, 
		address _token0, 
		address _token1,
		address _simpleUniswapOracle
	) external;
	
	function mint(address to) external  returns (uint256 newTokenId);
	function redeem(address to, uint256 tokenId) external  returns (uint256 redeemAmount);

}
