pragma solidity >=0.5.0;
pragma experimental ABIEncoderV2;

interface ITokenizedUniswapV3Factory {
	event NFTLPCreated(address indexed token0, address indexed token1, address NFTLP, uint);
	event NewPendingAdmin(address oldPendingAdmin, address newPendingAdmin);
	event NewAdmin(address oldAdmin, address newAdmin);
	event NewAcModule(address oldAcModule, address newAcModule);
	
	function admin() external view returns (address);
	function pendingAdmin() external view returns (address);
	
	function uniswapV3Factory() external view returns (address);
	function deployer() external view returns (address);
	function oracle() external view returns (address);
	function acModule() external view returns (address);
	
	function getNFTLP(address tokenA, address tokenB) external view returns (address);
	function allNFTLP(uint) external view returns (address);
	function allNFTLPLength() external view returns (uint);
	
	function createNFTLP(address tokenA, address tokenB) external returns (address NFTLP);
	
	function _setPendingAdmin(address newPendingAdmin) external;
	function _acceptAdmin() external;
	function _setAcModule(address newAcModule) external;
}
