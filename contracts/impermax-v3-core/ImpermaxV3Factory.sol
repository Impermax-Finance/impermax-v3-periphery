pragma solidity =0.5.16;

import "./interfaces/IFactory.sol";
import "./interfaces/IBDeployer.sol";
import "./interfaces/IBorrowable.sol";
import "./interfaces/ICDeployer.sol";
import "./interfaces/ICollateral.sol";
import "./interfaces/INFTLP.sol";

contract ImpermaxV3Factory is IFactory {
	address public admin;
	address public pendingAdmin;
	address public reservesAdmin;
	address public reservesPendingAdmin;
	address public reservesManager;
		
	struct LendingPool {
		bool initialized;
		uint24 lendingPoolId;
		address collateral;
		address borrowable0;
		address borrowable1;
	}
	mapping(address => LendingPool) public getLendingPool; // get by NFTLP
	address[] public allLendingPools; // address of the NFTLP
	function allLendingPoolsLength() external view returns (uint) {
		return allLendingPools.length;
	}
	
	IBDeployer public bDeployer;
	ICDeployer public cDeployer;
	
	constructor(address _admin, address _reservesAdmin, address _reservesManager, IBDeployer _bDeployer, ICDeployer _cDeployer) public {
		_checkReservesManager(_reservesManager);
		admin = _admin;
		reservesAdmin = _reservesAdmin;
		reservesManager = _reservesManager;
		bDeployer = _bDeployer;
		cDeployer = _cDeployer;
		emit NewAdmin(address(0), _admin);
		emit NewReservesAdmin(address(0), _reservesAdmin);
		emit NewReservesManager(address(0), _reservesManager);
	}
	
	function _getTokens(address nftlp) private view returns (address token0, address token1) {
		token0 = INFTLP(nftlp).token0();
		token1 = INFTLP(nftlp).token1();
	}
	
	function _createLendingPool(address nftlp) private {
		if (getLendingPool[nftlp].lendingPoolId != 0) return;
		allLendingPools.push(nftlp);		
		getLendingPool[nftlp] = LendingPool(false, uint24(allLendingPools.length), address(0), address(0), address(0));
	}
	
	function createCollateral(address nftlp) external returns (address collateral) {
		_getTokens(nftlp);
		require(getLendingPool[nftlp].collateral == address(0), "Impermax: ALREADY_EXISTS");		
		collateral = cDeployer.deployCollateral(nftlp);
		ICollateral(collateral)._setFactory();
		_createLendingPool(nftlp);
		getLendingPool[nftlp].collateral = collateral;
	}
	
	function createBorrowable0(address nftlp) external returns (address borrowable0) {
		_getTokens(nftlp);
		require(getLendingPool[nftlp].borrowable0 == address(0), "Impermax: ALREADY_EXISTS");		
		borrowable0 = bDeployer.deployBorrowable(nftlp, 0);
		IBorrowable(borrowable0)._setFactory();
		_createLendingPool(nftlp);
		getLendingPool[nftlp].borrowable0 = borrowable0;
	}
	
	function createBorrowable1(address nftlp) external returns (address borrowable1) {
		_getTokens(nftlp);
		require(getLendingPool[nftlp].borrowable1 == address(0), "Impermax: ALREADY_EXISTS");		
		borrowable1 = bDeployer.deployBorrowable(nftlp, 1);
		IBorrowable(borrowable1)._setFactory();
		_createLendingPool(nftlp);
		getLendingPool[nftlp].borrowable1 = borrowable1;
	}
	
	function initializeLendingPool(address nftlp) external {
		(address token0, address token1) = _getTokens(nftlp);
		LendingPool memory lPool = getLendingPool[nftlp];
		require(!lPool.initialized, "Impermax: ALREADY_INITIALIZED");
		
		require(lPool.collateral != address(0), "Impermax: COLLATERALIZABLE_NOT_CREATED");
		require(lPool.borrowable0 != address(0), "Impermax: BORROWABLE0_NOT_CREATED");
		require(lPool.borrowable1 != address(0), "Impermax: BORROWABLE1_NOT_CREATED");
				
		ICollateral(lPool.collateral)._initialize("Impermax Collateral", "imxC", nftlp, lPool.borrowable0, lPool.borrowable1);
		IBorrowable(lPool.borrowable0)._initialize("Impermax Borrowable", "imxB", token0, lPool.collateral);
		IBorrowable(lPool.borrowable1)._initialize("Impermax Borrowable", "imxB", token1, lPool.collateral);
		
		getLendingPool[nftlp].initialized = true;
		emit LendingPoolInitialized(nftlp, token0, token1, lPool.collateral, lPool.borrowable0, lPool.borrowable1, lPool.lendingPoolId);
	}
	
	function _setPendingAdmin(address newPendingAdmin) external {
		require(msg.sender == admin, "Impermax: UNAUTHORIZED");
		address oldPendingAdmin = pendingAdmin;
		pendingAdmin = newPendingAdmin;
		emit NewPendingAdmin(oldPendingAdmin, newPendingAdmin);
	}

	function _acceptAdmin() external {
		require(msg.sender == pendingAdmin, "Impermax: UNAUTHORIZED");
		address oldAdmin = admin;
		address oldPendingAdmin = pendingAdmin;
		admin = pendingAdmin;
		pendingAdmin = address(0);
		emit NewAdmin(oldAdmin, admin);
		emit NewPendingAdmin(oldPendingAdmin, address(0));
	}
	
	function _setReservesPendingAdmin(address newReservesPendingAdmin) external {
		require(msg.sender == reservesAdmin, "Impermax: UNAUTHORIZED");
		address oldReservesPendingAdmin = reservesPendingAdmin;
		reservesPendingAdmin = newReservesPendingAdmin;
		emit NewReservesPendingAdmin(oldReservesPendingAdmin, newReservesPendingAdmin);
	}

	function _acceptReservesAdmin() external {
		require(msg.sender == reservesPendingAdmin, "Impermax: UNAUTHORIZED");
		address oldReservesAdmin = reservesAdmin;
		address oldReservesPendingAdmin = reservesPendingAdmin;
		reservesAdmin = reservesPendingAdmin;
		reservesPendingAdmin = address(0);
		emit NewReservesAdmin(oldReservesAdmin, reservesAdmin);
		emit NewReservesPendingAdmin(oldReservesPendingAdmin, address(0));
	}

	function _checkReservesManager(address newReservesManager) internal {
		require(newReservesManager != address(0), "Impermax: INVALID_RESERVES_MANAGER");
	}
	function _setReservesManager(address newReservesManager) external {
		require(msg.sender == reservesAdmin, "Impermax: UNAUTHORIZED");
		_checkReservesManager(newReservesManager);
		address oldReservesManager = reservesManager;
		reservesManager = newReservesManager;
		emit NewReservesManager(oldReservesManager, newReservesManager);
	}
}
