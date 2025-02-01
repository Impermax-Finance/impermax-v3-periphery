pragma solidity >=0.5.0;

interface ITokenizedUniswapV3Deployer {
	function deployNFTLP(address token0, address token1) external returns (address NFTLP);
}