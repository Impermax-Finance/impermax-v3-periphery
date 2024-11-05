pragma solidity =0.5.16;
pragma experimental ABIEncoderV2;

import "./interfaces/IERC20.sol";
import "./interfaces/IERC721.sol";
import "./interfaces/IWETH.sol";
import "./interfaces/IUniswapV2Pair.sol";
import "./interfaces/IRouter01V3.sol";
import "./libraries/Math.sol";
import "./libraries/SafeMath.sol";
import "./libraries/TransferHelper.sol";
import "./libraries/UniswapV2Library.sol";
import "./impermax-v3-core/interfaces/IPoolToken.sol";
import "./impermax-v3-core/interfaces/IBorrowable.sol";
import "./impermax-v3-core/interfaces/IFactory.sol";
import "./impermax-v3-core/interfaces/ICollateral.sol";
import "./impermax-v3-core/interfaces/IImpermaxCallee.sol";
import "./impermax-v3-core/interfaces/INFTLP.sol";
import "./impermax-v3-core/extensions/interfaces/ITokenizedUniswapV2Position.sol";

contract Router01V3 is IRouter01V3, IImpermaxCallee {
	using SafeMath for uint;

	address public factory;
	address public WETH;

	modifier ensure(uint deadline) {
		require(deadline >= block.timestamp, "ImpermaxRouter: EXPIRED");
		_;
	}

	modifier checkETH(address poolToken) {
		require(WETH == IPoolToken(poolToken).underlying(), "ImpermaxRouter: NOT_WETH");
		_;
	}
	
	function _checkOwnerNftlp(address nftlp, uint256 tokenId) internal {
		address collateral = getCollateral(nftlp);
		require(IERC721(collateral).ownerOf(tokenId) == msg.sender, "ImpermaxRouter: UNAUTHORIZED");
	}
	modifier checkOwnerNftlp(address nftlp, uint256 tokenId) {
		_checkOwnerNftlp(nftlp, tokenId);
		_;
	}

	modifier checkOwner(uint256 tokenId, address collateral, address borrowable) {
		if (collateral == address(0)) {
			collateral = IBorrowable(borrowable).collateral();
		}
		require(IERC721(collateral).ownerOf(tokenId) == msg.sender, "ImpermaxRouter: UNAUTHORIZED");
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
	struct MintUniV2InternalData {
		uint lpAmountUser;
		uint amount0User;
		uint amount1User;
		uint amount0Router;
		uint amount1Router;
	}
	struct MintUniV2Data {
		uint lpAmountUser;
		uint amount0Desired;
		uint amount1Desired;
		uint amount0Min;
		uint amount1Min;
	}
	struct RedeemUniV2Data {
		uint percentage;
		uint amount0Min;
		uint amount1Min;
		address to;
	}
	struct BorrowAndMintUniV2Data {
		uint lpAmountUser;
		uint amount0User;
		uint amount1User;
		uint amount0Desired;
		uint amount1Desired;
		uint amount0Min;
		uint amount1Min;
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
		ActionType currentAction;
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
		bytes memory callbackData = nextAction.actionType == ActionType.NO_ACTION 
			? bytes("")
			: abi.encode(BorrowCallbackData({
				pool: pool,
				borrowableIndex: index,
				msgSender: msgSender,
				nextAction: nextAction
			}));
		IBorrowable(pool.borrowables[index]).borrow(tokenId, to, amount, callbackData);	
	}

	function _repayAmount(
		address borrowable,
		uint tokenId, 
		uint amountMax
	) internal returns (uint amount) { 
		IBorrowable(borrowable).accrueInterest();
		uint borrowedAmount = IBorrowable(borrowable).borrowBalance(tokenId);
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
		TransferHelper.safeTransferFrom(pool.tokens[index], msgSender, borrowable, repayAmount);
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
	
	function _mintUniV2Empty(
		LendingPool memory pool,
		address to
	) internal returns (uint tokenId) {
		tokenId = ITokenizedUniswapV2Position(pool.nftlp).mint(pool.collateral);
		ICollateral(pool.collateral).mint(to, tokenId);
	}
	function _mintUniV2Internal(
		LendingPool memory pool,
		uint tokenId,
		address msgSender,
		uint lpAmountUser,
		uint amount0User,
		uint amount1User,
		uint amount0Router,
		uint amount1Router
	) internal {
		address uniswapV2Pair = ITokenizedUniswapV2Position(pool.nftlp).underlying();
		// adjust amount for ETH
		// if the user has deposited native ETH, we need to subtract that amount from amountUser and add it to amountRouter
		int isEth = pool.tokens[0] == WETH ? 0 : pool.tokens[1] == WETH ? int(1) : -1;
		if (isEth != -1) {
			uint routerBalance = IERC20(WETH).balanceOf(address(this));
			if (isEth == 0 && routerBalance > amount0Router) {
				uint totalEthAmount = amount0User.add(amount0Router);
				amount0Router = Math.min(totalEthAmount, routerBalance);
				amount0User = totalEthAmount.sub(amount0Router);
			}
			if (isEth == 1 && routerBalance > amount1Router) {
				uint totalEthAmount = amount1User.add(amount1Router);
				amount1Router = Math.min(totalEthAmount, routerBalance);
				amount1User = totalEthAmount.sub(amount1Router);
			}
		}
		
		// add liquidity to uniswap pair
		if (amount0User > 0) TransferHelper.safeTransferFrom(pool.tokens[0], msgSender, uniswapV2Pair, amount0User);
		if (amount1User > 0) TransferHelper.safeTransferFrom(pool.tokens[1], msgSender, uniswapV2Pair, amount1User);
		if (amount0Router > 0) TransferHelper.safeTransfer(pool.tokens[0], uniswapV2Pair, amount0Router);
		if (amount1Router > 0) TransferHelper.safeTransfer(pool.tokens[1], uniswapV2Pair, amount1Router);
		// mint LP token
		if (amount0User + amount0Router > 0) IUniswapV2Pair(uniswapV2Pair).mint(pool.nftlp);
		// mint collateral
		if (lpAmountUser > 0) TransferHelper.safeTransferFrom(uniswapV2Pair, msgSender, pool.nftlp, lpAmountUser);
		uint tokenToJoin = ITokenizedUniswapV2Position(pool.nftlp).mint(address(this));
		ITokenizedUniswapV2Position(pool.nftlp).join(tokenId, tokenToJoin);
	}
	function _mintUniV2(
		LendingPool memory pool,
		uint tokenId,
		address msgSender,
		uint lpAmountUser,
		uint amount0Desired,	// intended as user amount
		uint amount1Desired,	// intended as user amount
		uint amount0Min,
		uint amount1Min
	) internal {
		address uniswapV2Pair = ITokenizedUniswapV2Position(pool.nftlp).underlying();
		(uint amount0, uint amount1) = _optimalLiquidity(uniswapV2Pair, amount0Desired, amount1Desired, amount0Min, amount1Min);
		_mintUniV2Internal(pool, tokenId, msgSender, lpAmountUser, amount0, amount1, 0, 0);
	}
	
	function _redeemUniV2Step1(
		LendingPool memory pool,
		uint tokenId,
		address msgSender,
		uint percentage,
		uint amount0Min,
		uint amount1Min,
		address to,
		Action memory nextAction
	) internal {
		require(percentage > 0, "ImpermaxRouter: REDEEM_ZERO");
		bytes memory callbackData = abi.encode(RedeemCallbackData({
			pool: pool,
			msgSender: msgSender,
			redeemTo: to,
			amount0Min: amount0Min,
			amount1Min: amount1Min,
			currentAction: ActionType.REDEEM_UNIV2,
			nextAction: nextAction
		}));
		ICollateral(pool.collateral).redeem(address(this), tokenId, percentage, callbackData);
	}
	function _redeemUniV2Step2(
		LendingPool memory pool,
		uint redeemTokenId,
		uint amount0Min,
		uint amount1Min,
		address to
	) internal {
		address uniswapV2Pair = ITokenizedUniswapV2Position(pool.nftlp).underlying();
		ITokenizedUniswapV2Position(pool.nftlp).redeem(uniswapV2Pair, redeemTokenId);
		(uint amount0, uint amount1) = IUniswapV2Pair(uniswapV2Pair).burn(to);
		require(amount0 >= amount0Min, "ImpermaxRouter: INSUFFICIENT_0_AMOUNT");
		require(amount1 >= amount1Min, "ImpermaxRouter: INSUFFICIENT_1_AMOUNT");
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
	
	function getMintUniV2InternalAction(uint lpAmountUser, uint amount0User, uint amount1User, uint amount0Router, uint amount1Router) internal pure returns (Action memory) {
		return _getAction(ActionType.MINT_UNIV2_INTERNAL, abi.encode(MintUniV2InternalData({
			lpAmountUser: lpAmountUser,
			amount0User: amount0User,
			amount1User: amount1User,
			amount0Router: amount0Router,
			amount1Router: amount1Router
		})));
	}
	function getMintUniV2Action(uint lpAmountUser, uint amount0Desired, uint amount1Desired, uint amount0Min, uint amount1Min) public pure returns (Action memory) {
		return _getAction(ActionType.MINT_UNIV2, abi.encode(MintUniV2Data({
			lpAmountUser: lpAmountUser,
			amount0Desired: amount0Desired,
			amount1Desired: amount1Desired,
			amount0Min: amount0Min,
			amount1Min: amount1Min
		})));
	}
	
	function getRedeemUniV2Action(uint percentage, uint amount0Min, uint amount1Min, address to) public pure returns (Action memory) {
		return _getAction(ActionType.REDEEM_UNIV2, abi.encode(RedeemUniV2Data({
			percentage: percentage,
			amount0Min: amount0Min,
			amount1Min: amount1Min,
			to: to
		})));
	}
	
	/*** Composite Actions ***/
	
	function _borrowAndMintUniV2(
		LendingPool memory pool,
		uint lpAmountUser,
		uint amount0User,
		uint amount1User,
		uint amount0Desired,	// intended as user amount + router amount
		uint amount1Desired,	// intended as user amount + router amount
		uint amount0Min,		// intended as user amount + router amount
		uint amount1Min			// intended as user amount + router amount
	) internal view returns (Action[] memory a) {
		address uniswapV2Pair = ITokenizedUniswapV2Position(pool.nftlp).underlying();
		(uint amount0, uint amount1) = _optimalLiquidity(uniswapV2Pair, amount0Desired, amount1Desired, amount0Min, amount1Min);
		(uint amount0Router, uint amount1Router) = (
			amount0 > amount0User ? amount0 - amount0User : 0,
			amount1 > amount1User ? amount1 - amount1User : 0
		);

		a = new Action[](3);		
		a[0] = getBorrowAction(0, amount0Router, address(this));
		a[1] = getBorrowAction(1, amount1Router, address(this));
		a[2] = getMintUniV2InternalAction(lpAmountUser, amount0 - amount0Router, amount1 - amount1Router, amount0Router, amount1Router);
	}
	function getBorrowAndMintUniV2Action(
		uint lpAmountUser,
		uint amount0User,
		uint amount1User,
		uint amount0Desired,	// intended as user amount + router amount
		uint amount1Desired,	// intended as user amount + router amount
		uint amount0Min,		// intended as user amount + router amount
		uint amount1Min			// intended as user amount + router amount
	) external pure returns (Action memory) {
		return _getAction(ActionType.BORROW_AND_MINT_UNIV2, abi.encode(BorrowAndMintUniV2Data({
			lpAmountUser: lpAmountUser,
			amount0User: amount0User,
			amount1User: amount1User,
			amount0Desired: amount0Desired,
			amount1Desired: amount1Desired,
			amount0Min: amount0Min,
			amount1Min: amount1Min
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
	) internal {
		if (action.actionType == ActionType.NO_ACTION) return;
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
			return;
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
		else if (action.actionType == ActionType.MINT_UNIV2_INTERNAL) {
			MintUniV2InternalData memory decoded = abi.decode(action.actionData, (MintUniV2InternalData));
			_mintUniV2Internal(
				pool,
				tokenId,
				msgSender,
				decoded.lpAmountUser,
				decoded.amount0User,
				decoded.amount1User,
				decoded.amount0Router,
				decoded.amount1Router
			);
		}
		else if (action.actionType == ActionType.MINT_UNIV2) {
			MintUniV2Data memory decoded = abi.decode(action.actionData, (MintUniV2Data));
			_mintUniV2(
				pool,
				tokenId,
				msgSender,
				decoded.lpAmountUser,
				decoded.amount0Desired,
				decoded.amount1Desired,
				decoded.amount0Min,
				decoded.amount1Min
			);
		}
		else if (action.actionType == ActionType.REDEEM_UNIV2) {
			RedeemUniV2Data memory decoded = abi.decode(action.actionData, (RedeemUniV2Data));
			_redeemUniV2Step1(
				pool,
				tokenId,
				msgSender,
				decoded.percentage,
				decoded.amount0Min,
				decoded.amount1Min,
				decoded.to,
				nextAction
			);
			return;
		}
		else if (action.actionType == ActionType.BORROW_AND_MINT_UNIV2) {
			BorrowAndMintUniV2Data memory decoded = abi.decode(action.actionData, (BorrowAndMintUniV2Data));
			Action[] memory actions = _borrowAndMintUniV2(
				pool,
				decoded.lpAmountUser,
				decoded.amount0User,
				decoded.amount1User,
				decoded.amount0Desired,
				decoded.amount1Desired,
				decoded.amount0Min,
				decoded.amount1Min
			);
			nextAction = _actionsSorter(actions, nextAction);
		}
		else revert("ImpermaxRouter: INVALID_ACTION");
		
		_execute(
			pool,
			tokenId,
			msgSender,
			nextAction
		);
	}
	
	/*** External ***/
	
	function execute(
		address nftlp,
		uint _tokenId,
		uint deadline,
		bytes calldata actionsData,
		bytes calldata permitsData
	) external payable ensure(deadline) returns (uint tokenId) {
		if (msg.value > 0) {
			IWETH(WETH).deposit.value(msg.value)();
		}
		// TODO execute all permits HERE
			
		Action[] memory actions = abi.decode(actionsData, (Action[]));
		
		LendingPool memory pool = getLendingPool(nftlp);
		uint tokenId;
		if (_tokenId != uint(-1)) {
			tokenId = _tokenId;
			_checkOwnerNftlp(nftlp, tokenId);
		} else {
			if (actions[0].actionType == ActionType.MINT_UNIV2 || actions[0].actionType == ActionType.BORROW_AND_MINT_UNIV2)
				tokenId = _mintUniV2Empty(pool, msg.sender);
			else revert("ImpermaxRouter: INVALID_FIRST_ACTION");
		}
			
		_execute(
			pool,
			tokenId,
			msg.sender,
			_actionsSorter(actions)
		);
	}
	/*
	function _mint(
		address poolToken, 
		address token, 
		uint amount,
		address from,
		address to
	) internal returns (uint tokens) {
		if (from == address(this)) TransferHelper.safeTransfer(token, poolToken, amount);
		else TransferHelper.safeTransferFrom(token, from, poolToken, amount);
		tokens = IPoolToken(poolToken).mint(to);
	}
	function mint(
		address poolToken, 
		uint amount,
		address to,
		uint deadline
	) external ensure(deadline) returns (uint tokens) {
		return _mint(poolToken, IPoolToken(poolToken).underlying(), amount, msg.sender, to);
	}
	function mintETH(
		address poolToken, 
		address to,
		uint deadline
	) external payable ensure(deadline) checkETH(poolToken) returns (uint tokens) {
		IWETH(WETH).deposit.value(msg.value)();
		return _mint(poolToken, WETH, msg.value, address(this), to);
	}
		
	function redeem(
		address poolToken,
		uint tokens,
		address to,
		uint deadline,
		bytes memory permitData
	) public ensure(deadline) returns (uint amount) {
		_permit(poolToken, tokens, deadline, permitData);
		uint tokensBalance = IERC20(poolToken).balanceOf(msg.sender);
		tokens = tokens < tokensBalance ? tokens : tokensBalance;
		IPoolToken(poolToken).transferFrom(msg.sender, poolToken, tokens);
		return IPoolToken(poolToken).redeem(to);
	}
	function redeemETH(
		address poolToken, 
		uint tokens,
		address to,
		uint deadline,
		bytes memory permitData
	) public ensure(deadline) checkETH(poolToken) returns (uint amountETH) {
		_permit(poolToken, tokens, deadline, permitData);
		uint tokensBalance = IERC20(poolToken).balanceOf(msg.sender);
		tokens = tokens < tokensBalance ? tokens : tokensBalance;
		IPoolToken(poolToken).transferFrom(msg.sender, poolToken, tokens);
		amountETH = IPoolToken(poolToken).redeem(address(this));
		IWETH(WETH).withdraw(amountETH);
		TransferHelper.safeTransferETH(to, amountETH);
	}	
	
	function liquidate(
		address borrowable, 
		uint tokenId,
		uint amountMax,
		address to,
		uint deadline
	) external ensure(deadline) returns (uint amount, uint seizeTokenId) {
		// TODO liquidate position underwater
		amount = _repayAmount(borrowable, tokenId, amountMax);
		TransferHelper.safeTransferFrom(IBorrowable(borrowable).underlying(), msg.sender, borrowable, amount);
		seizeTokenId = IBorrowable(borrowable).liquidate(tokenId, amount, to, "0x");
	}
	function liquidateETH(
		address borrowable, 
		uint tokenId,
		address to,
		uint deadline
	) external payable ensure(deadline) checkETH(borrowable) returns (uint amountETH, uint seizeTokenId) {
		amountETH = _repayAmount(borrowable, tokenId, msg.value);
		IWETH(WETH).deposit.value(amountETH)();
		assert(IWETH(WETH).transfer(borrowable, amountETH));
		seizeTokenId = IBorrowable(borrowable).liquidate(tokenId, amountETH, to, "0x");
		// refund surpluss eth, if any
		if (msg.value > amountETH) TransferHelper.safeTransferETH(msg.sender, msg.value - amountETH);
	}*/
	
	/*** Callbacks ***/
	
	// WARNING FOR TESTING
	// IF SOMEONE IS ABLE TO REENTER IN ONE OF THIS FUNCTION THROUGH AN EXTERNAL CONTRACT HE WILL BE ABLE TO STEAL APPROVED FUNDS
	
	function impermaxBorrow(address sender, uint256 tokenId, uint borrowAmount, bytes calldata data) external {
		borrowAmount;
		BorrowCallbackData memory callbackData = abi.decode(data, (BorrowCallbackData));
		
		// only succeeds if called by a borrowable and if that borrowable has been called by the router
		address declaredCaller = getBorrowable(callbackData.pool.nftlp, callbackData.borrowableIndex);
		require(sender == address(this), "ImpermaxRouter: SENDER_NOT_ROUTER");
		require(msg.sender == declaredCaller, "ImpermaxRouter: UNAUTHORIZED_CALLER");
		
		_execute(
			callbackData.pool,
			tokenId,
			callbackData.msgSender,
			callbackData.nextAction
		);
	}
	
	function impermaxRedeem(address sender, uint256 tokenId, uint256 redeemTokenId, bytes calldata data) external {
		RedeemCallbackData memory callbackData = abi.decode(data, (RedeemCallbackData));
		
		// only succeeds if called by a collateral and if that collateral has been called by the router
		address declaredCaller = getCollateral(callbackData.pool.nftlp);
		require(sender == address(this), "ImpermaxRouter: SENDER_NOT_ROUTER");
		require(msg.sender == declaredCaller, "ImpermaxRouter: UNAUTHORIZED_CALLER");
		
		// only nftlp accepted -> first thing, redeem for lp tokens
		if (callbackData.currentAction == ActionType.REDEEM_UNIV2) _redeemUniV2Step2(
			callbackData.pool,
			redeemTokenId,
			callbackData.amount0Min,
			callbackData.amount1Min,
			callbackData.redeemTo
		);
		
		_execute(
			callbackData.pool,
			tokenId,
			callbackData.msgSender,
			callbackData.nextAction
		);
	}
	
	function onERC721Received(address operator, address from, uint256 tokenId, bytes calldata data) external returns (bytes4 returnValue) {
		return bytes4(keccak256("onERC721Received(address,address,uint256,bytes)"));
	}
		
	/*** Utilities ***/
	
	function _permit(
		address poolToken, 
		uint amount, 
		uint deadline,
		bytes memory permitData
	) internal {
		if (permitData.length == 0) return;
		(bool approveMax, uint8 v, bytes32 r, bytes32 s) = abi.decode(permitData, (bool, uint8, bytes32, bytes32));
		uint value = approveMax ? uint(-1) : amount;
		IPoolToken(poolToken).permit(msg.sender, address(this), value, deadline, v, r, s);
	}
	function _borrowPermit(
		address borrowable, 
		uint amount, 
		uint deadline,
		bytes memory permitData
	) internal {
		if (permitData.length == 0) return;
		(bool approveMax, uint8 v, bytes32 r, bytes32 s) = abi.decode(permitData, (bool, uint8, bytes32, bytes32));
		uint value = approveMax ? uint(-1) : amount;
		IBorrowable(borrowable).borrowPermit(msg.sender, address(this), value, deadline, v, r, s);
	}
	function _nftPermit(
		address erc721, 
		uint tokenId, 
		uint deadline,
		bytes memory permitData
	) internal {
		if (permitData.length == 0) return;
		// TOOD should I keep the bool to maintain the standard or should I remove it?
		(, uint8 v, bytes32 r, bytes32 s) = abi.decode(permitData, (bool, uint8, bytes32, bytes32));
		IERC721(erc721).permit(address(this), tokenId, deadline, v, r, s);
	}
	
	function _optimalLiquidity(
		address uniswapV2Pair,
		uint amount0Desired,
		uint amount1Desired,
		uint amount0Min,
		uint amount1Min
	) public view returns (uint amount0, uint amount1) {
		if (amount0Desired == 0) return (0, 0);
		(uint reserveA, uint reserveB,) = IUniswapV2Pair(uniswapV2Pair).getReserves();
		uint amount1Optimal = UniswapV2Library.quote(amount0Desired, reserveA, reserveB);
		if (amount1Optimal <= amount1Desired) {
			require(amount1Optimal >= amount1Min, "ImpermaxRouter: INSUFFICIENT_1_AMOUNT");
			(amount0, amount1) = (amount0Desired, amount1Optimal);
		} else {
			uint amount0Optimal = UniswapV2Library.quote(amount1Desired, reserveB, reserveA);
			assert(amount0Optimal <= amount0Desired);
			require(amount0Optimal >= amount0Min, "ImpermaxRouter: INSUFFICIENT_0_AMOUNT");
			(amount0, amount1) = (amount0Optimal, amount1Desired);
		}
	}
	
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
