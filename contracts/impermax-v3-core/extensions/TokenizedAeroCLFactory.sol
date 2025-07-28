pragma solidity =0.5.16;

import "./interfaces/ITokenizedAeroCLFactory.sol";
import "./interfaces/ITokenizedAeroCLDeployer.sol";
import "./interfaces/ITokenizedAeroCLPosition.sol";

contract TokenizedAeroCLFactory is ITokenizedAeroCLFactory {

	address public admin;
	address public pendingAdmin;
	
	address public clFactory;
	address public nfpManager;
	address public oracle;
	address public rewardsToken;
	
	ITokenizedAeroCLDeployer public deployer;

	mapping(address => mapping(address => address)) public getNFTLP;
	address[] public allNFTLP;

	constructor(address _admin, address _clFactory, address _nfpManager, ITokenizedAeroCLDeployer _deployer, address _oracle, address _rewardsToken) public {
		admin = _admin;
		clFactory = _clFactory;
		nfpManager = _nfpManager;
		deployer = _deployer;
		oracle = _oracle;
		rewardsToken = _rewardsToken;
		emit NewAdmin(address(0), _admin);
	}

	function allNFTLPLength() external view returns (uint) {
		return allNFTLP.length;
	}

	function createNFTLP(address tokenA, address tokenB) external returns (address NFTLP) {
		require(tokenA != tokenB);
		(address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
		require(token0 != address(0));
		require(getNFTLP[token0][token1] == address(0), "TokenizedAeroCLFactory: PAIR_EXISTS");
		NFTLP = deployer.deployNFTLP(token0, token1);
		ITokenizedAeroCLPosition(NFTLP)._initialize(clFactory, nfpManager, oracle, token0, token1, rewardsToken);
		getNFTLP[token0][token1] = NFTLP;
		getNFTLP[token1][token0] = NFTLP;
		allNFTLP.push(NFTLP);
		emit NFTLPCreated(token0, token1, NFTLP, allNFTLP.length);
	}
	
	function _setPendingAdmin(address newPendingAdmin) external {
		require(msg.sender == admin, "TokenizedAeroCLFactory: UNAUTHORIZED");
		address oldPendingAdmin = pendingAdmin;
		pendingAdmin = newPendingAdmin;
		emit NewPendingAdmin(oldPendingAdmin, newPendingAdmin);
	}

	function _acceptAdmin() external {
		require(msg.sender == pendingAdmin, "TokenizedAeroCLFactory: UNAUTHORIZED");
		address oldAdmin = admin;
		address oldPendingAdmin = pendingAdmin;
		admin = pendingAdmin;
		pendingAdmin = address(0);
		emit NewAdmin(oldAdmin, admin);
		emit NewPendingAdmin(oldPendingAdmin, address(0));
	}
}
