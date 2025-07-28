pragma solidity =0.5.16;

import "./interfaces/ITokenizedUniswapV3Factory.sol";
import "./interfaces/ITokenizedUniswapV3Deployer.sol";
import "./interfaces/ITokenizedUniswapV3Position.sol";

contract TokenizedUniswapV3Factory is ITokenizedUniswapV3Factory {
	
	address public uniswapV3Factory;
	address public oracle;
	
	ITokenizedUniswapV3Deployer public deployer;

	mapping(address => mapping(address => address)) public getNFTLP;
	address[] public allNFTLP;

	constructor(address _uniswapV3Factory, ITokenizedUniswapV3Deployer _deployer, address _oracle) public {
		uniswapV3Factory = _uniswapV3Factory;
		deployer = _deployer;
		oracle = _oracle;
	}

	function allNFTLPLength() external view returns (uint) {
		return allNFTLP.length;
	}

	function createNFTLP(address tokenA, address tokenB) external returns (address NFTLP) {
		require(tokenA != tokenB);
		(address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
		require(token0 != address(0));
		require(getNFTLP[token0][token1] == address(0), "TokenizedUniswapV3Factory: PAIR_EXISTS");
		NFTLP = deployer.deployNFTLP(token0, token1);
		ITokenizedUniswapV3Position(NFTLP)._initialize(uniswapV3Factory, oracle, token0, token1);
		getNFTLP[token0][token1] = NFTLP;
		getNFTLP[token1][token0] = NFTLP;
		allNFTLP.push(NFTLP);
		emit NFTLPCreated(token0, token1, NFTLP, allNFTLP.length);
	}
}
