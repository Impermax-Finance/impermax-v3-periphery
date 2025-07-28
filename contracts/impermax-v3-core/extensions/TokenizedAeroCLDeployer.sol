pragma solidity =0.5.16;

import "./TokenizedAeroCLPosition.sol";
import "./interfaces/ITokenizedAeroCLDeployer.sol";

contract TokenizedAeroCLDeployer is ITokenizedAeroCLDeployer {
	constructor () public {}
	
	function deployNFTLP(address token0, address token1) external returns (address NFTLP) {
		bytes memory bytecode = type(TokenizedAeroCLPosition).creationCode;
		bytes32 salt = keccak256(abi.encodePacked(msg.sender, token0, token1));
		assembly {
			NFTLP := create2(0, add(bytecode, 32), mload(bytecode), salt)
		}
	}
}
