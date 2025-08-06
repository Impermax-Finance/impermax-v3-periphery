pragma solidity >=0.5.0;
pragma experimental ABIEncoderV2;

import "../../interfaces/INFTLP.sol";

interface ITokenizedAeroCLPosition {
	
	// ERC-721
	
	function name() external view returns (string memory);
	function symbol() external view returns (string memory);
	function balanceOf(address owner) external view returns (uint256 balance);
	function ownerOf(uint256 tokenId) external view returns (address owner);
	function getApproved(uint256 tokenId) external view returns (address operator);
	function isApprovedForAll(address owner, address operator) external view returns (bool);
	
	function DOMAIN_SEPARATOR() external view returns (bytes32);
	function nonces(uint256 tokenId) external view returns (uint256);
	
	function safeTransferFrom(address from, address to, uint256 tokenId, bytes calldata data) external;
	function safeTransferFrom(address from, address to, uint256 tokenId) external;
	function transferFrom(address from, address to, uint256 tokenId) external;
	function approve(address to, uint256 tokenId) external;
	function setApprovalForAll(address operator, bool approved) external;
	function permit(address spender, uint tokenId, uint deadline, uint8 v, bytes32 r, bytes32 s) external;
	
	// INFTLP
	
	function token0() external view returns (address);
	function token1() external view returns (address);
	function getPositionData(uint256 _tokenId, uint256 _safetyMarginSqrt) external returns (
		uint256 priceSqrtX96,
		INFTLP.RealXYs memory realXYs
	);
	
	function split(uint256 tokenId, uint256 percentage) external returns (uint256 newTokenId);
	
	// ITokenizedAeroCLPosition
	
	function factory() external view returns (address);
	function clFactory() external view returns (address);
	function nfpManager() external view returns (address);
	function oracle() external view returns (address);
	function rewardsToken() external view returns (address);
	
	function getPool(int24 tickSpacing) external view returns (address pool);
	function getGauge(uint256 tokenId) external view returns (address gauge);
	
	function oraclePriceSqrtX96() external returns (uint256);
	
	event MintPosition(uint256 indexed tokenId, int24 tickSpacing, int24 tickLower, int24 tickUpper);
	event UpdatePositionLiquidity(uint256 indexed tokenId, uint256 liquidity);
	event SplitPosition(uint256 indexed tokenId, uint256 newTokenId);
	event SyncReward(uint256 totalRewardBalance);
	event UpdatePositionReward(uint256 indexed tokenId, uint256 rewardOwed, uint256 claimAmount);
	event GaugeAdded(int24 tickSpacing, address gauge);

	function _initialize (
		address _clFactory, 
		address _nfpManager, 
		address _oracle, 
		address _token0, 
		address _token1,
		address _rewardsToken
	) external;
	
	function mint(address to, uint256 tokenId, bytes calldata data) external;
	function redeem(address to, uint256 tokenId) external;	
	function increaseLiquidity(uint256 tokenId) external returns (uint128 liquidity, uint256 amount0, uint256 amount1);
	function claim(address to, uint256 tokenId) external returns (uint256 claimAmount);
	function skim(address to) external returns (uint256 balance0, uint256 balance1);
}
