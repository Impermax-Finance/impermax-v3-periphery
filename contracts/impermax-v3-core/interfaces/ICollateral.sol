pragma solidity >=0.5.0;

interface ICollateral {
	
	/* ImpermaxERC721 */

	event Transfer(address indexed from, address indexed to, uint256 indexed tokenId);
	event Approval(address indexed owner, address indexed approved, uint256 indexed tokenId);
	event ApprovalForAll(address indexed owner, address indexed operator, bool approved);
	
	function name() external view returns (string memory);
	function symbol() external view returns (string memory);
	function balanceOf(address owner) external view returns (uint256 balance);
	function ownerOf(uint256 tokenId) external view returns (address owner);
	function getApproved(uint256 tokenId) external view returns (address operator);
	function isApprovedForAll(address owner, address operator) external view returns (bool);
	
	function safeTransferFrom(address from, address to, uint256 tokenId, bytes calldata data) external;
	function safeTransferFrom(address from, address to, uint256 tokenId) external;
	function transferFrom(address from, address to, uint256 tokenId) external;
	function approve(address to, uint256 tokenId) external;
	function setApprovalForAll(address operator, bool approved) external;
	function permit(address spender, uint tokenId, uint deadline, uint8 v, bytes32 r, bytes32 s) external;
	
	/* Collateral */
	
	event Mint(address indexed to, uint tokenId);
	event Redeem(address indexed to, uint tokenId, uint percentage, uint redeemTokenId);
	event Seize(address indexed to, uint tokenId, uint percentage, uint redeemTokenId);
	event RestructureBadDebt(uint tokenId, uint postLiquidationCollateralRatio);
	
	function underlying() external view returns (address);
	function factory() external view returns (address);
	function borrowable0() external view returns (address);
	function borrowable1() external view returns (address);
	function safetyMarginSqrt() external view returns (uint);
	function liquidationIncentive() external view returns (uint);
	function liquidationFee() external view returns (uint);
	function liquidationPenalty() external view returns (uint);

	function mint(address to, uint256 tokenId) external;
	function redeem(address to, uint256 tokenId, uint256 percentage, bytes calldata data) external returns (uint redeemTokenId);
	function redeem(address to, uint256 tokenId, uint256 percentage) external returns (uint redeemTokenId);
	function isLiquidatable(uint tokenId) external returns (bool);
	function isUnderwater(uint tokenId) external returns (bool);
	function canBorrow(uint tokenId, address borrowable, uint accountBorrows) external returns (bool);
	function restructureBadDebt(uint tokenId) external;
	function seize(uint tokenId, uint repayAmount, address liquidator, bytes calldata data) external returns (uint seizeTokenId);
	
	/* CSetter */
	
	event NewSafetyMargin(uint newSafetyMarginSqrt);
	event NewLiquidationIncentive(uint newLiquidationIncentive);
	event NewLiquidationFee(uint newLiquidationFee);

	function SAFETY_MARGIN_SQRT_MIN() external pure returns (uint);
	function SAFETY_MARGIN_SQRT_MAX() external pure returns (uint);
	function LIQUIDATION_INCENTIVE_MIN() external pure returns (uint);
	function LIQUIDATION_INCENTIVE_MAX() external pure returns (uint);
	function LIQUIDATION_FEE_MAX() external pure returns (uint);
	
	function _setFactory() external;
	function _initialize (
		string calldata _name,
		string calldata _symbol,
		address _underlying, 
		address _borrowable0, 
		address _borrowable1
	) external;
	function _setSafetyMarginSqrt(uint newSafetyMarginSqrt) external;
	function _setLiquidationIncentive(uint newLiquidationIncentive) external;
	function _setLiquidationFee(uint newLiquidationFee) external;
}