pragma solidity >=0.5.0;
pragma experimental ABIEncoderV2;

import "../../interfaces/INFTLP.sol";

interface ITokenizedUniswapV3Position {
	
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
	
	// ITokenizedUniswapV3Position
	
	function factory() external view returns (address);
	function uniswapV3Factory() external view returns (address);
	
	function totalBalance(uint24 fee, int24 tickLower, int24 tickUpper) external view returns (uint256);
	
	function positions(uint256 tokenId) external view returns (
		uint24 fee,
		int24 tickLower,
		int24 tickUpper,
		uint128 liquidity,
		uint256 feeGrowthInside0LastX128,
		uint256 feeGrowthInside1LastX128
	);
	function positionLength() external view returns (uint256);
	
	function getPool(uint24 fee) external returns (address pool);
	function poolsList(uint256 index) external view returns (address);
	
	function oraclePriceSqrtX96() external returns (uint256);
	
	event MintPosition(uint256 indexed tokenId, uint24 fee, int24 tickLower, int24 tickUpper);
	event UpdatePositionLiquidity(uint256 indexed tokenId, uint256 liquidity);
	event UpdatePositionFeeGrowthInside(uint256 indexed tokenId, uint256 feeGrowthInside0LastX128, uint256 feeGrowthInside1LastX128);

	function _initialize (
		address _uniswapV3Factory, 
		address _token0, 
		address _token1
	) external;
	
	function mint(address to, uint24 fee, int24 tickLower, int24 tickUpper) external  returns (uint256 newTokenId);
	function redeem(address to, uint256 tokenId) external  returns (uint256 amount0, uint256 amount1);

}
