pragma solidity =0.5.16;

import "./interfaces/ITokenizedUniswapV3Factory.sol";
import "./interfaces/ITokenizedUniswapV3Deployer.sol";
import "./interfaces/ITokenizedUniswapV3Position.sol";

contract TokenizedUniswapV3Factory is ITokenizedUniswapV3Factory {
	address public admin;
	address public pendingAdmin;
	
	address public uniswapV3Factory;
	address public oracle;
	address public acModule;
	
	ITokenizedUniswapV3Deployer public deployer;

	mapping(address => mapping(address => address)) public getNFTLP;
	address[] public allNFTLP;

	constructor(address _admin, address _uniswapV3Factory, ITokenizedUniswapV3Deployer _deployer, address _oracle) public {
		admin = _admin;
		uniswapV3Factory = _uniswapV3Factory;
		deployer = _deployer;
		oracle = _oracle;
		emit NewAdmin(address(0), _admin);
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
	
	/***  acModule ***/
	
	function _setPendingAdmin(address newPendingAdmin) external {
		require(msg.sender == admin, "TokenizedUniswapV3Factory: UNAUTHORIZED");
		address oldPendingAdmin = pendingAdmin;
		pendingAdmin = newPendingAdmin;
		emit NewPendingAdmin(oldPendingAdmin, newPendingAdmin);
	}

	function _acceptAdmin() external {
		require(msg.sender == pendingAdmin, "TokenizedUniswapV3Factory: UNAUTHORIZED");
		address oldAdmin = admin;
		address oldPendingAdmin = pendingAdmin;
		admin = pendingAdmin;
		pendingAdmin = address(0);
		emit NewAdmin(oldAdmin, admin);
		emit NewPendingAdmin(oldPendingAdmin, address(0));
	}
	
	function _setAcModule(address newAcModule) external {
		require(msg.sender == admin, "TokenizedUniswapV3Factory: UNAUTHORIZED");
		address oldAcModule = acModule;
		acModule = newAcModule;
		emit NewAcModule(oldAcModule, newAcModule);
	}
}
