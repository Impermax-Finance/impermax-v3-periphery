pragma solidity >=0.5.0;
pragma experimental ABIEncoderV2;

import "./ITokenizedUniswapV3Position.sol";

interface IUniswapV3AC01 {
	
	function uniswapV3Factory() external view returns (address);
	function tokenizedUniswapV3Factory() external view returns (address);
	
	function MAX_REINVEST_BOUNTY() external view returns (uint256);
	function MAX_BOUNTY_T() external view returns (uint256);
	function PROTOCOL_SHARE() external view returns (uint256);
	
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
	
	/* Reserve Manager */
	
	event NewReservesPendingAdmin(address oldReservesPendingAdmin, address newReservesPendingAdmin);
	event NewReservesAdmin(address oldReservesAdmin, address newReservesAdmin);
	event NewReservesManager(address oldReservesManager, address newReservesManager);
	
	function reservesAdmin() external view returns (address);
	function reservesPendingAdmin() external view returns (address);
	function reservesManager() external view returns (address);
	
	function _setReservesPendingAdmin(address newPendingAdmin) external;
	function _acceptReservesAdmin() external;
	function _setReservesManager(address newReservesManager) external;
	
	function claimToken(address token) external;
	function claimTokens(address[] calldata tokens) external;
}
