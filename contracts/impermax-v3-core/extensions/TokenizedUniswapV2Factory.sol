pragma solidity =0.5.16;

import "./TokenizedUniswapV2Position.sol";
import "./interfaces/IUniswapV2Pair.sol";

contract TokenizedUniswapV2Factory {
	address public simpleUniswapOracle;

	mapping(address => address) public getNFTLP;
	address[] public allNFTLP;

	event NFTLPCreated(address indexed token0, address indexed token1, address pair, address NFTLP, uint);

	constructor(address _simpleUniswapOracle) public {
		simpleUniswapOracle = _simpleUniswapOracle;
	}

	function allNFTLPLength() external view returns (uint) {
		return allNFTLP.length;
	}

	function createNFTLP(address pair) external returns (address NFTLP) {
		require(getNFTLP[pair] == address(0), "TokenizedUniswapV2Factory: PAIR_EXISTS");
		address token0 = IUniswapV2Pair(pair).token0();
		address token1 = IUniswapV2Pair(pair).token1();
		bytes memory bytecode = type(TokenizedUniswapV2Position).creationCode;
		assembly {
			NFTLP := create2(0, add(bytecode, 32), mload(bytecode), pair)
		}
		TokenizedUniswapV2Position(NFTLP)._initialize(pair, token0, token1, simpleUniswapOracle);
		getNFTLP[pair] = NFTLP;
		allNFTLP.push(NFTLP);
		emit NFTLPCreated(token0, token1, pair, NFTLP, allNFTLP.length);
	}
}
