pragma solidity =0.5.16;
pragma experimental ABIEncoderV2;

import "./interfaces/IERC20.sol";
import "./interfaces/IERC721.sol";
import "./interfaces/IWETH.sol";
import "./interfaces/IV3BaseRouter01.sol";
import "./interfaces/IAllowanceTransfer.sol";
import "./libraries/Math.sol";
import "./libraries/SafeMath.sol";
import "./libraries/TransferHelper.sol";
import "./libraries/ImpermaxPermit.sol";
import "./impermax-v3-core/interfaces/IPoolToken.sol";
import "./impermax-v3-core/interfaces/IBorrowable.sol";
import "./impermax-v3-core/interfaces/IFactory.sol";
import "./impermax-v3-core/interfaces/IImpermaxCallee.sol";

contract ImpermaxV3BaseRouter01 is IV3BaseRouter01, IImpermaxCallee {
	using SafeMath for uint;

	address public factory;
	address public WETH;

	modifier permit(bytes memory permitsData) {
		ImpermaxPermit.Permit[] memory permits = abi.decode(permitsData, (ImpermaxPermit.Permit[]));
		ImpermaxPermit.executePermits(permits);
		_;
	}

	constructor(address _factory, address _WETH) public {
		factory = _factory;
		WETH = _WETH;
	}

	function () external payable {
		assert(msg.sender == WETH); // only accept ETH via fallback from the WETH contract
	}
	
	
	/*** Data Structures ***/
	
	// actions
	struct BorrowData {
		uint8 index;
		uint amount;
		address to;
	}
	struct RepayUserData {
		uint8 index;
		uint amountMax;
	}
	struct RepayRouterData {
		uint8 index;
		uint amountMax;
		address refundTo;
	}
	struct WithdrawTokenData {
		address token;
		address to;
	}
	struct WithdrawEthData {
		address to;
	}
	
	// callbacks
	struct BorrowCallbackData {
		LendingPool pool;
		uint8 borrowableIndex;
		address msgSender;
		Action nextAction;
	}
	struct RedeemCallbackData {
		LendingPool pool;
		address msgSender;
		address redeemTo;
		uint amount0Min;
		uint amount1Min;
		Action nextAction;
	}
	
	/*** Primitive Actions ***/

	function _borrow(
		LendingPool memory pool,
		uint8 index,
		uint tokenId,
		address msgSender,
		uint amount,
		address to,
		Action memory nextAction
	) internal {
		bytes memory encoded = nextAction.actionType == ActionType.NO_ACTION 
			? bytes("")
			: abi.encode(BorrowCallbackData({
				pool: pool,
				borrowableIndex: index,
				msgSender: msgSender,
				nextAction: nextAction
			}));
		IBorrowable(pool.borrowables[index]).borrow(tokenId, to, amount, encoded);	
	}

	function _repayAmount(
		address borrowable,
		uint tokenId, 
		uint amountMax
	) internal returns (uint amount) { 
		uint borrowedAmount = IBorrowable(borrowable).currentBorrowBalance(tokenId);
		amount = Math.min(amountMax, borrowedAmount);
	}
	function _repayUser(
		LendingPool memory pool,
		uint8 index,
		uint tokenId,
		address msgSender,
		uint amountMax
	) internal {
		address borrowable = pool.borrowables[index];
		uint repayAmount = _repayAmount(borrowable, tokenId, amountMax);
		if (repayAmount == 0) return;
		ImpermaxPermit.safeTransferFrom(pool.tokens[index], msgSender, borrowable, repayAmount);
		IBorrowable(borrowable).borrow(tokenId, address(0), 0, new bytes(0));
	}
	function _repayRouter(
		LendingPool memory pool,
		uint8 index,
		uint tokenId,
		uint amountMax,
		address refundTo
	) internal {
		address borrowable = pool.borrowables[index];
		uint routerBalance = IERC20(pool.tokens[index]).balanceOf(address(this));
		amountMax = Math.min(amountMax, routerBalance);
		uint repayAmount = _repayAmount(borrowable, tokenId, amountMax);
		if (routerBalance > repayAmount && refundTo != address(this)) TransferHelper.safeTransfer(pool.tokens[index], refundTo, routerBalance - repayAmount);
		if (repayAmount == 0) return;
		TransferHelper.safeTransfer(pool.tokens[index], borrowable, repayAmount);
		IBorrowable(borrowable).borrow(tokenId, address(0), 0, new bytes(0));
	}
	
	function _withdrawToken(
		address token,
		address to
	) internal {
		uint routerBalance = IERC20(token).balanceOf(address(this));
		if (routerBalance > 0) TransferHelper.safeTransfer(token, to, routerBalance);
	}
	
	function _withdrawEth(
		address to
	) internal {
		uint routerBalance = IERC20(WETH).balanceOf(address(this));
		if (routerBalance == 0) return;
		IWETH(WETH).withdraw(routerBalance);
		TransferHelper.safeTransferETH(to, routerBalance);
	}
	
	/*** Action Getters ***/
	
	function _getAction(ActionType actionType, bytes memory actionData) internal pure returns (Action memory) {
		return Action({
			actionType: actionType,
			actionData: actionData,
			nextAction: bytes("")
		});
	}
	
	function getNoAction() internal pure returns (Action memory) {
		return _getAction(ActionType.NO_ACTION, bytes(""));
	}
	
	function getBorrowAction(uint8 index, uint amount, address to) public pure returns (Action memory) {
		return _getAction(ActionType.BORROW, abi.encode(BorrowData({
			index: index,
			amount: amount,
			to: to
		})));
	}
	
	function getRepayUserAction(uint8 index, uint amountMax) public pure returns (Action memory) {
		return _getAction(ActionType.REPAY_USER, abi.encode(RepayUserData({
			index: index,
			amountMax: amountMax
		})));
	}
	function getRepayRouterAction(uint8 index, uint amountMax, address refundTo) public pure returns (Action memory) {
		return _getAction(ActionType.REPAY_ROUTER, abi.encode(RepayRouterData({
			index: index,
			amountMax: amountMax,
			refundTo: refundTo
		})));
	}
	
	function getWithdrawTokenAction(address token, address to) public pure returns (Action memory) {
		return _getAction(ActionType.WITHDRAW_TOKEN, abi.encode(WithdrawTokenData({
			token: token,
			to: to
		})));
	}
	
	function getWithdrawEthAction(address to) public pure returns (Action memory) {
		return _getAction(ActionType.WITHDRAW_ETH, abi.encode(WithdrawEthData({
			to: to
		})));
	}
	
	
	/*** Actions sorter: sorts actions and composite actions ***/
	
	function _actionsSorter(Action[] memory actions, Action memory nextAction) internal pure returns (Action memory) {
		require(actions.length > 0, "Router01V3xUniswapV2: UNEXPECTED_ACTIONS_LENGTH");
		actions[actions.length-1].nextAction = abi.encode(nextAction);
		for(uint i = actions.length-1; i > 0; i--) {
			actions[i-1].nextAction = abi.encode(actions[i]);
		}
		return actions[0];
	}
	function _actionsSorter(Action[] memory actions) internal pure returns (Action memory) {
		return _actionsSorter(actions, getNoAction());
	}

	/*** EXECUTE ***/
	
	function _execute(
		LendingPool memory pool,
		uint tokenId,
		address msgSender,
		Action memory action
	) internal returns (uint) {
		if (action.actionType == ActionType.NO_ACTION) return tokenId;
		Action memory nextAction = abi.decode(action.nextAction, (Action));
		if (action.actionType == ActionType.BORROW) {
			BorrowData memory decoded = abi.decode(action.actionData, (BorrowData));
			_borrow(
				pool,
				decoded.index,
				tokenId,
				msgSender,
				decoded.amount,
				decoded.to,
				nextAction
			);
			return tokenId;
		}
		else if (action.actionType == ActionType.REPAY_USER) {
			RepayUserData memory decoded = abi.decode(action.actionData, (RepayUserData));
			_repayUser(
				pool,
				decoded.index,
				tokenId,
				msgSender,
				decoded.amountMax
			);
		}
		else if (action.actionType == ActionType.REPAY_ROUTER) {
			RepayRouterData memory decoded = abi.decode(action.actionData, (RepayRouterData));
			_repayRouter(
				pool,
				decoded.index,
				tokenId,
				decoded.amountMax,
				decoded.refundTo
			);
		}
		else if (action.actionType == ActionType.WITHDRAW_TOKEN) {
			WithdrawTokenData memory decoded = abi.decode(action.actionData, (WithdrawTokenData));
			_withdrawToken(
				decoded.token,
				decoded.to
			);
		}
		else if (action.actionType == ActionType.WITHDRAW_ETH) {
			WithdrawEthData memory decoded = abi.decode(action.actionData, (WithdrawEthData));
			_withdrawEth(
				decoded.to
			);
		}
		else revert("ImpermaxRouter: INVALID_ACTION");
		
		return _execute(
			pool,
			tokenId,
			msgSender,
			nextAction
		);
	}
	
	/*** External ***/
	
	function _checkFirstAction(ActionType actionType) internal; 
	
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
		
		Action[] memory actions = abi.decode(actionsData, (Action[]));
		
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
			_actionsSorter(actions)
		);
		
		if (withCollateralTransfer) {
			IERC721(pool.collateral).transferFrom(address(this), msg.sender, tokenId);
		}
	}
	
	/*** Callbacks ***/
	
	// WARNING FOR TESTING
	// IF SOMEONE IS ABLE TO REENTER IN ONE OF THIS FUNCTION THROUGH AN EXTERNAL CONTRACT HE WILL BE ABLE TO STEAL APPROVED FUNDS
	
	function impermaxV3Borrow(address sender, uint256 tokenId, uint borrowAmount, bytes calldata data) external {
		borrowAmount;
		BorrowCallbackData memory decoded = abi.decode(data, (BorrowCallbackData));
		
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
		RedeemCallbackData memory decoded = abi.decode(data, (RedeemCallbackData));
		
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
}
