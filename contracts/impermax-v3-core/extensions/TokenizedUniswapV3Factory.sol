pragma solidity =0.5.16;

import "./TokenizedUniswapV3Position.sol";

contract TokenizedUniswapV3Factory {
	address public uniswapV3Factory;

	mapping(address => mapping(address => address)) public getNFTLP;
	address[] public allNFTLP;

	event NFTLPCreated(address indexed token0, address indexed token1, address NFTLP, uint);

	constructor(address _uniswapV3Factory) public {
		uniswapV3Factory = _uniswapV3Factory;
	}

	function allNFTLPLength() external view returns (uint) {
		return allNFTLP.length;
	}

	function createNFTLP(address tokenA, address tokenB) external returns (address NFTLP) {
		require(tokenA != tokenB);
		(address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
		require(token0 != address(0));
		require(getNFTLP[token0][token1] == address(0), "TokenizedUniswapV3Factory: PAIR_EXISTS");
		bytes memory bytecode = type(TokenizedUniswapV3Position).creationCode;
		bytes32 salt = keccak256(abi.encodePacked(token0, token1));
		assembly {
			NFTLP := create2(0, add(bytecode, 32), mload(bytecode), salt)
		}
		TokenizedUniswapV3Position(NFTLP)._initialize(uniswapV3Factory, token0, token1);
		getNFTLP[token0][token1] = NFTLP;
		getNFTLP[token1][token0] = NFTLP;
		allNFTLP.push(NFTLP);
		emit NFTLPCreated(token0, token1, NFTLP, allNFTLP.length);
	}
}
