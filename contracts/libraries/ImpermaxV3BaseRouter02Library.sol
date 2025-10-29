pragma solidity >=0.5.0;
pragma experimental ABIEncoderV2;

import "../interfaces/IERC20.sol";
import "../interfaces/IWETH.sol";
import "../interfaces/IV3BaseRouter02.sol";
import "../interfaces/ILendingVaultV2.sol";
import "../libraries/Math.sol";
import "../libraries/TransferHelper.sol";
import "../libraries/ImpermaxPermit.sol";
import "../libraries/Actions.sol";
import "../impermax-v3-core/interfaces/IBorrowable.sol";

library ImpermaxV3BaseRouter02Library {

	/*** Data Structures ***/
	
	// callbacks
	struct BorrowCallbackData {
		IV3BaseRouter02.LendingPool pool;
		uint8 borrowableIndex;
		address msgSender;
		Actions.Action nextAction;
	}
	struct RedeemCallbackData {
		IV3BaseRouter02.LendingPool pool;
		address msgSender;
		address redeemTo;
		uint amount0Min;
		uint amount1Min;
		Actions.Action nextAction;
	}
	struct AllocateCallbackData {
		IV3BaseRouter02.LendingPool pool;
		address msgSender;
		uint tokenId;
		Actions.Action nextAction;
	}
	
	/*** Primitive Actions ***/

	function _borrow(
		IV3BaseRouter02.LendingPool memory pool,
		uint8 index,
		uint tokenId,
		address msgSender,
		uint amount,
		address to,
		Actions.Action memory nextAction
	) private {
		bytes memory encoded = nextAction.actionType == Actions.Type.NO_ACTION || to != address(this)
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
	) public returns (uint amount) { 
		uint borrowedAmount = IBorrowable(borrowable).currentBorrowBalance(tokenId);
		amount = Math.min(amountMax, borrowedAmount);
	}
	function _repayUser(
		IV3BaseRouter02.LendingPool memory pool,
		uint8 index,
		uint tokenId,
		address msgSender,
		uint amountMax
	) private {
		address borrowable = pool.borrowables[index];
		uint repayAmount = _repayAmount(borrowable, tokenId, amountMax);
		if (repayAmount == 0) return;
		ImpermaxPermit.safeTransferFrom(pool.tokens[index], msgSender, borrowable, repayAmount);
		IBorrowable(borrowable).borrow(tokenId, address(0), 0, new bytes(0));
	}
	function _repayRouter(
		IV3BaseRouter02.LendingPool memory pool,
		uint8 index,
		uint tokenId,
		uint amountMax,
		address refundTo
	) private {
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
	) public {
		uint routerBalance = IERC20(token).balanceOf(address(this));
		if (routerBalance > 0) TransferHelper.safeTransfer(token, to, routerBalance);
	}
	
	function _withdrawEth(
		address to,
		address WETH
	) private {
		uint routerBalance = IERC20(WETH).balanceOf(address(this));
		if (routerBalance == 0) return;
		IWETH(WETH).withdraw(routerBalance);
		TransferHelper.safeTransferETH(to, routerBalance);
	}

	function _flashAllocate(
		IV3BaseRouter02.LendingPool memory pool,
		uint8 index,
		uint tokenId,
		address msgSender,
		address vault,
		uint amount,
		Actions.Action memory nextAction
	) private {
		bytes memory encoded = abi.encode(AllocateCallbackData({
			pool: pool,
			msgSender: msgSender,
			tokenId: tokenId,
			nextAction: nextAction
		}));
		ILendingVaultV2(vault).flashAllocate(pool.borrowables[index], amount, encoded);
	}
	
	/*** Composite Actions ***/
	
	function _swapAndRepay(
		IV3BaseRouter02.LendingPool memory pool,
		uint8 index,
		uint tokenId,
		uint amountMax,
		uint160 sqrtPriceLimitX96,
		address refundTo
	) internal returns (Actions.Action[] memory a) {
		address borrowable = pool.borrowables[index];
		uint repayAmount = _repayAmount(borrowable, tokenId, amountMax);
		uint routerBalance = IERC20(pool.tokens[index]).balanceOf(address(this));
		
		if (routerBalance >= repayAmount) {
			a = new Actions.Action[](1);		
			a[0] = Actions.getRepayRouterAction(index, repayAmount, refundTo);
		} else {
			a = new Actions.Action[](2);
			a[0] = Actions.getSwapAction(index, repayAmount - routerBalance, sqrtPriceLimitX96);
			a[1] = Actions.getRepayRouterAction(index, repayAmount, refundTo);
		}
	}

	/*** EXECUTE ***/
	
	function execute(
		IV3BaseRouter02.LendingPool memory pool,
		uint tokenId,
		address msgSender,
		Actions.Action memory action,
		address WETH
	) public returns (bool breakCycle, Actions.Action memory nextAction) {
		nextAction = abi.decode(action.nextAction, (Actions.Action));
		
		if (action.actionType == Actions.Type.BORROW) {
			Actions.BorrowData memory decoded = abi.decode(action.actionData, (Actions.BorrowData));
			_borrow(
				pool,
				decoded.index,
				tokenId,
				msgSender,
				decoded.amount,
				decoded.to,
				nextAction
			);
			if (decoded.to == address(this)) return (true, nextAction);
		}
		else if (action.actionType == Actions.Type.REPAY_USER) {
			Actions.RepayUserData memory decoded = abi.decode(action.actionData, (Actions.RepayUserData));
			_repayUser(
				pool,
				decoded.index,
				tokenId,
				msgSender,
				decoded.amountMax
			);
		}
		else if (action.actionType == Actions.Type.REPAY_ROUTER) {
			Actions.RepayRouterData memory decoded = abi.decode(action.actionData, (Actions.RepayRouterData));
			_repayRouter(
				pool,
				decoded.index,
				tokenId,
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
				decoded.to,
				WETH
			);
		}
		else if (action.actionType == Actions.Type.FLASH_ALLOCATE) {
			Actions.FlashAllocateData memory decoded = abi.decode(action.actionData, (Actions.FlashAllocateData));
			_flashAllocate(
				pool,
				decoded.index,
				tokenId,
				msgSender,
				decoded.vault,
				decoded.amount,
				nextAction
			);
			return (true, nextAction);
		}
		else if (action.actionType == Actions.Type.SWAP_AND_REPAY) {
			Actions.SwapAndRepayData memory decoded = abi.decode(action.actionData, (Actions.SwapAndRepayData));
			Actions.Action[] memory actions = _swapAndRepay(
				pool,
				decoded.index,
				tokenId,
				decoded.amountMax,
				decoded.sqrtPriceLimitX96,
				decoded.refundTo
			);
			nextAction = Actions.actionsSorter(actions, nextAction);
		}
		else revert("ImpermaxRouter: INVALID_ACTION");
		
		return (false, nextAction);
	}
}