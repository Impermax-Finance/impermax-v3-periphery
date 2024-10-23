pragma solidity >=0.5.0;

interface ICDeployer {
	function deployCollateral(address nftlp) external returns (address collateral);
}