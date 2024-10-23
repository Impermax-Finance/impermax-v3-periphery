pragma solidity >=0.5.0;

interface IBDeployer {
	function deployBorrowable(address nftlp, uint8 index) external returns (address borrowable);
}