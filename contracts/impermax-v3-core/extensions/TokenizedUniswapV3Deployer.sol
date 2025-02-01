pragma solidity =0.5.16;

import "./TokenizedUniswapV3Position.sol";
import "./interfaces/ITokenizedUniswapV3Deployer.sol";

contract TokenizedUniswapV3Deployer is ITokenizedUniswapV3Deployer {
	constructor () public {}
	
	function deployNFTLP(address token0, address token1) external returns (address NFTLP) {
		bytes memory bytecode = type(TokenizedUniswapV3Position).creationCode;
		bytes32 salt = keccak256(abi.encodePacked(msg.sender, token0, token1));
		assembly {
			NFTLP := create2(0, add(bytecode, 32), mload(bytecode), salt)
		}
	}
}
