pragma solidity =0.5.16;
pragma experimental ABIEncoderV2;

import "./interfaces/IERC20.sol";
import "./interfaces/IERC721.sol";
import "./interfaces/IWETH.sol";
import "./interfaces/IV3BaseRouter02.sol";
import "./interfaces/ILendingVaultV2Factory.sol";
import "./interfaces/ILendingVaultCallee.sol";
import "./libraries/SafeMath.sol";
import "./libraries/ImpermaxPermit.sol";
import "./libraries/Actions.sol";
import "./libraries/ImpermaxV3BaseRouter02Library.sol";
import "./impermax-v3-core/interfaces/IBorrowable.sol";
import "./impermax-v3-core/interfaces/IFactory.sol";
import "./impermax-v3-core/interfaces/IImpermaxCallee.sol";

contract ImpermaxV3BaseRouter02 is IV3BaseRouter02, IImpermaxCallee, ILendingVaultCallee {
	using SafeMath for uint;

	address public factory;
	address public WETH;
	
	address public vaultFactory;
	uint internal lastVaultsLength;
	mapping(address => bool) internal whitelistedVaults;

	modifier permit(bytes memory permitsData) {
		ImpermaxPermit.executePermits(permitsData);
		_;
	}

	constructor(address _factory, address _WETH, address _vaultFactory) public {
		factory = _factory;
		WETH = _WETH;
		vaultFactory = _vaultFactory;
	}

	function () external payable {
		assert(msg.sender == WETH); // only accept ETH via fallback from the WETH contract
	}
	
	function _execute(
		LendingPool memory pool,
		uint tokenId,
		address msgSender,
		Actions.Action memory action
	) internal returns (uint) {
		if (action.actionType == Actions.Type.NO_ACTION) return tokenId;
		
		(bool breakCycle, Actions.Action memory nextAction) = ImpermaxV3BaseRouter02Library.execute(pool, tokenId, msgSender, action, WETH);
		if (breakCycle) return tokenId;
		
		return _execute(
			pool,
			tokenId,
			msgSender,
			nextAction
		);
	}
	
	/*** External ***/
	
	function _checkFirstAction(Actions.Type actionType) internal; 
	function _reset() internal {}
	
	function execute(
		address nftlp,
		uint tokenId,
		bytes calldata actionsData,
		bytes calldata permitsData,
		bool withCollateralTransfer
	) external payable permit(permitsData) {
		if (msg.value > 0) {
			IWETH(WETH).deposit.value(msg.value)();
		}
		
		Actions.Action[] memory actions = abi.decode(actionsData, (Actions.Action[]));
		
		LendingPool memory pool = getLendingPool(nftlp);
		if (tokenId != uint(-1)) {
			if (withCollateralTransfer) {
				IERC721(pool.collateral).transferFrom(msg.sender, address(this), tokenId);
			} else {
				require(IERC721(pool.collateral).ownerOf(tokenId) == msg.sender, "ImpermaxRouter: UNAUTHORIZED");
			}
		} else {
			_checkFirstAction(actions[0].actionType);
			withCollateralTransfer = true;
		}
			
		tokenId = _execute(
			pool,
			tokenId,
			msg.sender,
			Actions.actionsSorter(actions)
		);
		
		if (withCollateralTransfer) {
			IERC721(pool.collateral).transferFrom(address(this), msg.sender, tokenId);
		}
		
		_reset();
	}
	
	/*** Callbacks ***/
	
	function impermaxV3Borrow(address sender, uint256 tokenId, uint borrowAmount, bytes calldata data) external {
		borrowAmount;
		ImpermaxV3BaseRouter02Library.BorrowCallbackData memory decoded = abi.decode(data, (ImpermaxV3BaseRouter02Library.BorrowCallbackData));
		
		// only succeeds if called by a borrowable and if that borrowable has been called by the router
		address declaredCaller = getBorrowable(decoded.pool.nftlp, decoded.borrowableIndex);
		require(sender == address(this), "ImpermaxRouter: SENDER_NOT_ROUTER");
		require(msg.sender == declaredCaller, "ImpermaxRouter: UNAUTHORIZED_CALLER");
		
		_execute(
			decoded.pool,
			tokenId,
			decoded.msgSender,
			decoded.nextAction
		);
	}
	
	function _redeemStep2(LendingPool memory pool, uint redeemTokenId, uint amount0Min, uint amount1Min, address to) internal;
	function impermaxV3Redeem(address sender, uint256 tokenId, uint256 redeemTokenId, bytes calldata data) external {
		ImpermaxV3BaseRouter02Library.RedeemCallbackData memory decoded = abi.decode(data, (ImpermaxV3BaseRouter02Library.RedeemCallbackData));
		
		// only succeeds if called by a collateral and if that collateral has been called by the router
		address declaredCaller = getCollateral(decoded.pool.nftlp);
		require(sender == address(this), "ImpermaxRouter: SENDER_NOT_ROUTER");
		require(msg.sender == declaredCaller, "ImpermaxRouter: UNAUTHORIZED_CALLER");
		
		_redeemStep2(
			decoded.pool,
			redeemTokenId,
			decoded.amount0Min,
			decoded.amount1Min,
			decoded.redeemTo
		);
		
		_execute(
			decoded.pool,
			tokenId,
			decoded.msgSender,
			decoded.nextAction
		);
	}
	
    function lendingVaultAllocate(address borrowable, uint allocateAmount, bytes calldata data) external {
		ImpermaxV3BaseRouter02Library.AllocateCallbackData memory decoded = abi.decode(data, (ImpermaxV3BaseRouter02Library.AllocateCallbackData));
		
		checkWhitelistedVault(msg.sender);
		
		_execute(
			decoded.pool,
			decoded.tokenId,
			decoded.msgSender,
			decoded.nextAction
		);
	}
	
	function onERC721Received(address operator, address from, uint256 tokenId, bytes calldata data) external pure returns (bytes4 returnValue) {
		operator; from; tokenId; data;
		return bytes4(keccak256("onERC721Received(address,address,uint256,bytes)"));
	}
	
	/*** Utilities ***/
	
	function getBorrowable(address nftlp, uint8 index) public view returns (address borrowable) {
		require(index < 2, "ImpermaxRouter: INDEX_TOO_HIGH");
		(,,,address borrowable0, address borrowable1) = IFactory(factory).getLendingPool(nftlp);
		return index == 0 ? borrowable0 : borrowable1;
	}
	function getCollateral(address nftlp) public view returns (address collateral) {
		(,,collateral,,) = IFactory(factory).getLendingPool(nftlp);
	}
	
	function getLendingPool(address nftlp) public view returns (LendingPool memory pool) {
		pool.nftlp = nftlp;
		(,,pool.collateral,pool.borrowables[0],pool.borrowables[1]) = 
			IFactory(factory).getLendingPool(nftlp);
		pool.tokens[0] = IBorrowable(pool.borrowables[0]).underlying();
		pool.tokens[1] = IBorrowable(pool.borrowables[1]).underlying();
	}
	
	function checkWhitelistedVault(address vault) internal {
		if (whitelistedVaults[vault]) return;
		uint newVaultsLength = ILendingVaultV2Factory(vaultFactory).allVaultsLength();
		for (uint i = lastVaultsLength; i < newVaultsLength; i++) {
			whitelistedVaults[
				ILendingVaultV2Factory(vaultFactory).allVaults(i)
			] = true;
		}
		lastVaultsLength = newVaultsLength;
		require(whitelistedVaults[vault], "ImpermaxRouter: VAULT_UNAUTHORIZED");
	}
}
