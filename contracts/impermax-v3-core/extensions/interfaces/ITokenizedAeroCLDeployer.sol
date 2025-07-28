pragma solidity >=0.5.0;

interface ITokenizedAeroCLDeployer {
	function deployNFTLP(address token0, address token1) external returns (address NFTLP);
}