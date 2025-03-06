pragma solidity =0.5.16;
pragma experimental ABIEncoderV2;

import "./interfaces/IERC20.sol";
import "./interfaces/IERC721.sol";
import "./interfaces/IWETH.sol";
import "./interfaces/IV2BaseRouter01.sol";
import "./libraries/Math.sol";
import "./libraries/SafeMath.sol";
import "./libraries/TransferHelper.sol";
import "./libraries/ImpermaxPermit.sol";
import "./libraries/Actions.sol";
import "./impermax-v2-core/interfaces/IBorrowableV2.sol";
import "./impermax-v2-core/interfaces/IFactoryV2.sol";
import "./impermax-v2-core/interfaces/IImpermaxCalleeV2.sol";

contract ImpermaxV2BaseRouter01 is IV2BaseRouter01, IImpermaxCalleeV2 {
	using SafeMath for uint;

	address public factory;
	address public WETH;

	modifier permit(bytes memory permitsData) {
		ImpermaxPermit.executePermits(permitsData);
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
	
	// callbacks
	struct BorrowCallbackData {
		LendingPool pool;
		uint8 borrowableIndex;
		address msgSender;
		Actions.Action nextAction;
	}
	struct RedeemCallbackData {
		LendingPool pool;
		address msgSender;
		address redeemTo;
		uint redeemTokens;
		uint amount0Min;
		uint amount1Min;
		Actions.Action nextAction;
	}
	
	/*** Primitive Actions ***/

	function _borrow(
		LendingPool memory pool,
		uint8 index,
		address msgSender,
		uint amount,
		address to,
		Actions.Action memory nextAction
	) internal {
		bytes memory encoded = nextAction.actionType == Actions.Type.NO_ACTION || to != address(this)
			? bytes("")
			: abi.encode(BorrowCallbackData({
				pool: pool,
				borrowableIndex: index,
				msgSender: msgSender,
				nextAction: nextAction
			}));
		IBorrowableV2(pool.borrowables[index]).borrow(msgSender, to, amount, encoded);	
	}

	function _repayAmount(
		address borrowable,
		address msgSender,
		uint amountMax
	) internal returns (uint amount) { 
		IBorrowableV2(borrowable).accrueInterest();
		uint borrowedAmount = IBorrowableV2(borrowable).borrowBalance(msgSender);
		amount = Math.min(amountMax, borrowedAmount);
	}
	function _repayUser(
		LendingPool memory pool,
		uint8 index,
		address msgSender,
		uint amountMax
	) internal {
		address borrowable = pool.borrowables[index];
		uint repayAmount = _repayAmount(borrowable, msgSender, amountMax);
		if (repayAmount == 0) return;
		ImpermaxPermit.safeTransferFrom(pool.tokens[index], msgSender, borrowable, repayAmount);
		IBorrowableV2(borrowable).borrow(msgSender, address(0), 0, new bytes(0));
	}
	function _repayRouter(
		LendingPool memory pool,
		uint8 index,
		address msgSender,
		uint amountMax,
		address refundTo
	) internal {
		address borrowable = pool.borrowables[index];
		uint routerBalance = IERC20(pool.tokens[index]).balanceOf(address(this));
		amountMax = Math.min(amountMax, routerBalance);
		uint repayAmount = _repayAmount(borrowable, msgSender, amountMax);
		if (routerBalance > repayAmount && refundTo != address(this)) TransferHelper.safeTransfer(pool.tokens[index], refundTo, routerBalance - repayAmount);
		if (repayAmount == 0) return;
		TransferHelper.safeTransfer(pool.tokens[index], borrowable, repayAmount);
		IBorrowableV2(borrowable).borrow(msgSender, address(0), 0, new bytes(0));
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

	/*** EXECUTE ***/
	
	function _execute(
		LendingPool memory pool,
		address msgSender,
		Actions.Action memory action
	) internal {
		if (action.actionType == Actions.Type.NO_ACTION) return;
		Actions.Action memory nextAction = abi.decode(action.nextAction, (Actions.Action));
		if (action.actionType == Actions.Type.BORROW) {
			Actions.BorrowData memory decoded = abi.decode(action.actionData, (Actions.BorrowData));
			_borrow(
				pool,
				decoded.index,
				msgSender,
				decoded.amount,
				decoded.to,
				nextAction
			);
			if (decoded.to == address(this)) return;
		}
		else if (action.actionType == Actions.Type.REPAY_USER) {
			Actions.RepayUserData memory decoded = abi.decode(action.actionData, (Actions.RepayUserData));
			_repayUser(
				pool,
				decoded.index,
				msgSender,
				decoded.amountMax
			);
		}
		else if (action.actionType == Actions.Type.REPAY_ROUTER) {
			Actions.RepayRouterData memory decoded = abi.decode(action.actionData, (Actions.RepayRouterData));
			_repayRouter(
				pool,
				decoded.index,
				msgSender,
				decoded.amountMax,
				decoded.refundTo
			);
		}
		else if (action.actionType == Actions.Type.WITHDRAW_TOKEN) {
			Actions.WithdrawTokenData memory decoded = abi.decode(action.actionData, (Actions.WithdrawTokenData));
			_withdrawToken(
				decoded.token,
				decoded.to
			);
		}
		else if (action.actionType == Actions.Type.WITHDRAW_ETH) {
			Actions.WithdrawEthData memory decoded = abi.decode(action.actionData, (Actions.WithdrawEthData));
			_withdrawEth(
				decoded.to
			);
		}
		else revert("ImpermaxRouter: INVALID_ACTION");
		
		return _execute(
			pool,
			msgSender,
			nextAction
		);
	}
	
	/*** External ***/
		
	function execute(
		address lp,
		bytes calldata actionsData,
		bytes calldata permitsData
	) external payable permit(permitsData) {
		if (msg.value > 0) {
			IWETH(WETH).deposit.value(msg.value)();
		}
		
		Actions.Action[] memory actions = abi.decode(actionsData, (Actions.Action[]));
		LendingPool memory pool = getLendingPool(lp);
			
		_execute(
			pool,
			msg.sender,
			Actions.actionsSorter(actions)
		);
	}
	
	/*** Callbacks ***/
	
	function impermaxBorrow(address sender, address borrower, uint borrowAmount, bytes calldata data) external {
		borrower; borrowAmount;
		BorrowCallbackData memory decoded = abi.decode(data, (BorrowCallbackData));
		
		// only succeeds if called by a borrowable and if that borrowable has been called by the router
		address declaredCaller = getBorrowable(decoded.pool.lp, decoded.borrowableIndex);
		require(sender == address(this), "ImpermaxRouter: SENDER_NOT_ROUTER");
		require(msg.sender == declaredCaller, "ImpermaxRouter: UNAUTHORIZED_CALLER");
		
		_execute(
			decoded.pool,
			decoded.msgSender,
			decoded.nextAction
		);
	}
	
	function _redeemStep2(LendingPool memory pool, uint amount0Min, uint amount1Min, address to) internal;
	function impermaxRedeem(address sender, uint redeemAmount, bytes calldata data) external {
		RedeemCallbackData memory decoded = abi.decode(data, (RedeemCallbackData));
		
		// only succeeds if called by a collateral and if that collateral has been called by the router
		address declaredCaller = getCollateral(decoded.pool.lp);
		require(sender == address(this), "ImpermaxRouter: SENDER_NOT_ROUTER");
		require(msg.sender == declaredCaller, "ImpermaxRouter: UNAUTHORIZED_CALLER");
		
		_redeemStep2(
			decoded.pool,
			decoded.amount0Min,
			decoded.amount1Min,
			decoded.redeemTo
		);
		
		_execute(
			decoded.pool,
			decoded.msgSender,
			decoded.nextAction
		);
		
		// repay flash redeem
		ImpermaxPermit.safeTransferFrom(declaredCaller, decoded.msgSender, declaredCaller, decoded.redeemTokens);
	}
	
	/*** Utilities ***/
	
	function getBorrowable(address lp, uint8 index) public view returns (address borrowable) {
		require(index < 2, "ImpermaxRouter: INDEX_TOO_HIGH");
		(,,,address borrowable0, address borrowable1) = IFactoryV2(factory).getLendingPool(lp);
		return index == 0 ? borrowable0 : borrowable1;
	}
	function getCollateral(address lp) public view returns (address collateral) {
		(,,collateral,,) = IFactoryV2(factory).getLendingPool(lp);
	}
	
	function getLendingPool(address lp) public view returns (LendingPool memory pool) {
		pool.lp = lp;
		(,,pool.collateral,pool.borrowables[0],pool.borrowables[1]) = 
			IFactoryV2(factory).getLendingPool(lp);
		pool.tokens[0] = IBorrowableV2(pool.borrowables[0]).underlying();
		pool.tokens[1] = IBorrowableV2(pool.borrowables[1]).underlying();
	}
}
