pragma solidity =0.5.16;

import "./ImpermaxV3Collateral.sol";
import "./interfaces/ICDeployer.sol";

/*
 * This contract is used by the Factory to deploy Collateral(s)
 * The bytecode would be too long to fit in the Factory
 */
 
contract CDeployer is ICDeployer {
	constructor () public {}
	
	function deployCollateral(address nftlp) external returns (address collateral) {
		bytes memory bytecode = type(ImpermaxV3Collateral).creationCode;
		bytes32 salt = keccak256(abi.encodePacked(msg.sender, nftlp));
		assembly {
			collateral := create2(0, add(bytecode, 32), mload(bytecode), salt)
		}
	}
}