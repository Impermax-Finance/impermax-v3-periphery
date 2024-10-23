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
	struct MintCollateralData {
		uint lpAmount;
	}
	struct RedeemCollateralData {
		uint percentage;
		address to;
	}
	struct BorrowData {
		uint8 index;
		uint amount;
		address to;
	}
	struct RepayData {
		uint8 index;
		uint amountMax;
	}
	struct AddLiquidityInternalData {
		uint amount0User;
		uint amount1User;
		uint amount0Router;
		uint amount1Router;
		address to;
	}
	struct AddLiquidityData {
		uint amount0Desired;
		uint amount1Desired;
		uint amount0Min;
		uint amount1Min;
		address to;
	}
	struct RemoveLiquidityData {
		uint lpAmount;
		uint amount0Min;
		uint amount1Min;
		address to;
	}
	struct WithdrawTokenData {
		address token;
		address to;
	}
	struct BorrowAndAddLiquidityData {
		uint amount0User;
		uint amount1User;
		uint amount0Desired;
		uint amount1Desired;
		uint amount0Min;
		uint amount1Min;
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
		Action nextAction;
	}
	
	/*** Primitive Actions ***/
	
	// TODO WHAT ABOUT ETH CONVERSIONS? Maybe create separate primitives?
	
	function _mintEmptyPosition(
		LendingPool memory pool,
		address to
	) internal returns (uint tokenId) {
		tokenId = ITokenizedUniswapV2Position(pool.nftlp).mint(pool.collateral);
		ICollateral(pool.collateral).mint(to, tokenId);
	}
	
	function _mintCollateral(
		LendingPool memory pool,
		uint tokenId,
		address msgSender,
		uint lpAmount			// intended as user amount
	) internal {
		if (lpAmount > 0) TransferHelper.safeTransferFrom(pool.uniswapV2Pair, msgSender, pool.nftlp, lpAmount);
		uint tokenToJoin = ITokenizedUniswapV2Position(pool.nftlp).mint(address(this));
		ITokenizedUniswapV2Position(pool.nftlp).join(tokenId, tokenToJoin);
	}
	
	function _redeemCollateral(
		LendingPool memory pool,
		uint tokenId,
		address msgSender,
		uint percentage,
		address to,
		Action memory nextAction
	) internal {
		require(percentage > 0, "ImpermaxRouter: REDEEM_ZERO");
		bytes memory callbackData = abi.encode(RedeemCallbackData({
			pool: pool,
			msgSender: msgSender,
			redeemTo: to,
			nextAction: nextAction
		}));
		ICollateral(pool.collateral).redeem(address(this), tokenId, percentage, callbackData);
	}

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
		address msgSender,
		uint amountMax
	) internal {
		address borrowable = pool.borrowables[index];
		uint routerBalance = IERC20(pool.tokens[index]).balanceOf(address(this));
		amountMax = Math.min(amountMax, routerBalance);
		uint repayAmount = _repayAmount(borrowable, tokenId, amountMax);
		if (routerBalance > repayAmount) TransferHelper.safeTransfer(pool.tokens[index], msgSender, routerBalance - repayAmount);
		if (repayAmount == 0) return;
		TransferHelper.safeTransfer(pool.tokens[index], borrowable, repayAmount);
		IBorrowable(borrowable).borrow(tokenId, address(0), 0, new bytes(0));
	}
	
	function _addLiquidityInternal(
		LendingPool memory pool,
		uint tokenId,
		address msgSender,
		uint amount0User,
		uint amount1User,
		uint amount0Router,
		uint amount1Router,
		address to
	) internal {
		// add liquidity to uniswap pair
		if (amount0User > 0) TransferHelper.safeTransferFrom(pool.tokens[0], msgSender, pool.uniswapV2Pair, amount0User);
		if (amount1User > 0) TransferHelper.safeTransferFrom(pool.tokens[1], msgSender, pool.uniswapV2Pair, amount1User);
		if (amount0Router > 0) TransferHelper.safeTransfer(pool.tokens[0], pool.uniswapV2Pair, amount0Router);
		if (amount1Router > 0) TransferHelper.safeTransfer(pool.tokens[1], pool.uniswapV2Pair, amount1Router);
		// mint LP token
		IUniswapV2Pair(pool.uniswapV2Pair).mint(to);
	}
	function _addLiquidity(
		LendingPool memory pool,
		uint tokenId,
		address msgSender,
		uint amount0Desired,	// intended as user amount
		uint amount1Desired,	// intended as user amount
		uint amount0Min,
		uint amount1Min,
		address to
	) internal {
		(uint amount0, uint amount1) = _optimalLiquidity(pool.uniswapV2Pair, amount0Desired, amount1Desired, amount0Min, amount1Min);
		_addLiquidityInternal(pool, tokenId, msgSender, amount0, amount1, 0, 0, to);
	}
	
	function _removeLiquidity(
		LendingPool memory pool,
		address msgSender,
		uint lpAmount,			// intended as user amount
		uint amount0Min,
		uint amount1Min,
		address to
	) internal {
		if (lpAmount > 0) TransferHelper.safeTransferFrom(pool.uniswapV2Pair, msgSender, pool.uniswapV2Pair, lpAmount);
		(uint amount0, uint amount1) = IUniswapV2Pair(pool.uniswapV2Pair).burn(to);
		require(amount0 >= amount0Min, "ImpermaxRouter: INSUFFICIENT_0_AMOUNT");
		require(amount1 >= amount1Min, "ImpermaxRouter: INSUFFICIENT_1_AMOUNT");
	}
	
	function _withdrawToken(
		address token,
		address to
	) internal {
		uint routerBalance = IERC20(token).balanceOf(address(this));
		if (routerBalance > 0) TransferHelper.safeTransfer(token, to, routerBalance);
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
	
	function getMintCollateralAction(uint lpAmount) public pure returns (Action memory) {
		return _getAction(ActionType.MINT_COLLATERAL, abi.encode(MintCollateralData({
			lpAmount: lpAmount
		})));
	}
	
	function getRedeemCollateralAction(uint percentage, address to) public pure returns (Action memory) {
		return _getAction(ActionType.REDEEM_COLLATERAL, abi.encode(RedeemCollateralData({
			percentage: percentage,
			to: to
		})));
	}
	
	function getBorrowAction(uint8 index, uint amount, address to) public pure returns (Action memory) {
		return _getAction(ActionType.BORROW, abi.encode(BorrowData({
			index: index,
			amount: amount,
			to: to
		})));
	}
	
	function getRepayUserAction(uint8 index, uint amountMax) public pure returns (Action memory) {
		return _getAction(ActionType.REPAY_USER, abi.encode(RepayData({
			index: index,
			amountMax: amountMax
		})));
	}
	function getRepayRouterAction(uint8 index, uint amountMax) public pure returns (Action memory) {
		return _getAction(ActionType.REPAY_ROUTER, abi.encode(RepayData({
			index: index,
			amountMax: amountMax
		})));
	}
	
	function getAddLiquidityFixedAction(uint amount0User, uint amount1User, uint amount0Router, uint amount1Router, address to) internal pure returns (Action memory) {
		return _getAction(ActionType.ADD_LIQUIDITY_INTERNAL, abi.encode(AddLiquidityInternalData({
			amount0User: amount0User,
			amount1User: amount1User,
			amount0Router: amount0Router,
			amount1Router: amount1Router,
			to: to
		})));
	}
	function getAddLiquidityAction(uint amount0Desired, uint amount1Desired, uint amount0Min, uint amount1Min, address to) public pure returns (Action memory) {
		return _getAction(ActionType.ADD_LIQUIDITY, abi.encode(AddLiquidityData({
			amount0Desired: amount0Desired,
			amount1Desired: amount1Desired,
			amount0Min: amount0Min,
			amount1Min: amount1Min,
			to: to
		})));
	}
	
	function getRemoveLiquidityAction(uint lpAmount, uint amount0Min, uint amount1Min, address to) public pure returns (Action memory) {
		return _getAction(ActionType.REMOVE_LIQUIDITY, abi.encode(RemoveLiquidityData({
			lpAmount: lpAmount,
			amount0Min: amount0Min,
			amount1Min: amount1Min,
			to: to
		})));
	}
	
	function getWithdrawTokenAction(address token, address to) public pure returns (Action memory) {
		return _getAction(ActionType.WITHDRAW_TOKEN, abi.encode(WithdrawTokenData({
			token: token,
			to: to
		})));
	}
	
	/*** Composite Actions ***/
	
	function _borrowAndAddLiquidity(
		LendingPool memory pool,
		uint amount0User,
		uint amount1User,
		uint amount0Desired,	// intended as user amount + router amount
		uint amount1Desired,	// intended as user amount + router amount
		uint amount0Min,		// intended as user amount + router amount
		uint amount1Min,		// intended as user amount + router amount
		address to
	) internal view returns (Action[] memory a) {
		(uint amount0, uint amount1) = _optimalLiquidity(pool.uniswapV2Pair, amount0Desired, amount1Desired, amount0Min, amount1Min);
		(uint amount0Router, uint amount1Router) = (
			amount0 > amount0User ? amount0 - amount0User : 0,
			amount1 > amount1User ? amount1 - amount1User : 0
		);
		a = new Action[](3);		
		a[0] = getBorrowAction(0, amount0Router, address(this));
		a[1] = getBorrowAction(1, amount1Router, address(this));
		a[2] = getAddLiquidityFixedAction(amount0 - amount0Router, amount1 - amount1Router, amount0Router, amount1Router, to);
	}
	function getBorrowAndAddLiquidityAction(
		uint amount0User,
		uint amount1User,
		uint amount0Desired,	// intended as user amount + router amount
		uint amount1Desired,	// intended as user amount + router amount
		uint amount0Min,		// intended as user amount + router amount
		uint amount1Min,		// intended as user amount + router amount
		address to
	) external pure returns (Action memory) {
		return _getAction(ActionType.BORROW_AND_ADD_LIQUIDITY, abi.encode(BorrowAndAddLiquidityData({
			amount0User: amount0User,
			amount1User: amount1User,
			amount0Desired: amount0Desired,
			amount1Desired: amount1Desired,
			amount0Min: amount0Min,
			amount1Min: amount1Min,
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
	) internal {
		if (action.actionType == ActionType.NO_ACTION) return;
		Action memory nextAction = abi.decode(action.nextAction, (Action));
		if (action.actionType == ActionType.MINT_COLLATERAL) {
			MintCollateralData memory decoded = abi.decode(action.actionData, (MintCollateralData));
			_mintCollateral(
				pool,
				tokenId,
				msgSender,
				decoded.lpAmount
			);
		}
		else if (action.actionType == ActionType.REDEEM_COLLATERAL) {
			RedeemCollateralData memory decoded = abi.decode(action.actionData, (RedeemCollateralData));
			_redeemCollateral(
				pool,
				tokenId,
				msgSender,
				decoded.percentage,
				decoded.to,
				nextAction
			);
			return;
		}
		else if (action.actionType == ActionType.BORROW) {
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
			RepayData memory decoded = abi.decode(action.actionData, (RepayData));
			_repayUser(
				pool,
				decoded.index,
				tokenId,
				msgSender,
				decoded.amountMax
			);
		}
		else if (action.actionType == ActionType.REPAY_ROUTER) {
			RepayData memory decoded = abi.decode(action.actionData, (RepayData));
			_repayRouter(
				pool,
				decoded.index,
				tokenId,
				msgSender,
				decoded.amountMax
			);
		}
		else if (action.actionType == ActionType.ADD_LIQUIDITY_INTERNAL) {
			AddLiquidityInternalData memory decoded = abi.decode(action.actionData, (AddLiquidityInternalData));
			_addLiquidityInternal(
				pool,
				tokenId,
				msgSender,
				decoded.amount0User,
				decoded.amount1User,
				decoded.amount0Router,
				decoded.amount1Router,
				decoded.to
			);
		}
		else if (action.actionType == ActionType.ADD_LIQUIDITY) {
			AddLiquidityData memory decoded = abi.decode(action.actionData, (AddLiquidityData));
			_addLiquidity(
				pool,
				tokenId,
				msgSender,
				decoded.amount0Desired,
				decoded.amount1Desired,
				decoded.amount0Min,
				decoded.amount1Min,
				decoded.to
			);
		}
		else if (action.actionType == ActionType.REMOVE_LIQUIDITY) {
			RemoveLiquidityData memory decoded = abi.decode(action.actionData, (RemoveLiquidityData));
			_removeLiquidity(
				pool,
				msgSender,
				decoded.lpAmount,
				decoded.amount0Min,
				decoded.amount1Min,
				decoded.to
			);
		}
		else if (action.actionType == ActionType.WITHDRAW_TOKEN) {
			WithdrawTokenData memory decoded = abi.decode(action.actionData, (WithdrawTokenData));
			_withdrawToken(
				decoded.token,
				decoded.to
			);
		}
		else if (action.actionType == ActionType.BORROW_AND_ADD_LIQUIDITY) {
			BorrowAndAddLiquidityData memory decoded = abi.decode(action.actionData, (BorrowAndAddLiquidityData));
			Action[] memory actions = _borrowAndAddLiquidity(
				pool,
				decoded.amount0User,
				decoded.amount1User,
				decoded.amount0Desired,
				decoded.amount1Desired,
				decoded.amount0Min,
				decoded.amount1Min,
				decoded.to
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
	) external ensure(deadline) returns (uint tokenId) {
		LendingPool memory pool = getLendingPool(nftlp);
		if (_tokenId != uint(-1)) {
			tokenId = _tokenId;
			_checkOwnerNftlp(nftlp, tokenId);
		} else {
			tokenId = _mintEmptyPosition(pool, msg.sender);
		}
		// TODO execute all permits HERE
			
		Action[] memory actions = abi.decode(actionsData, (Action[]));
			
		_execute(
			pool,
			tokenId,
			msg.sender,
			_actionsSorter(actions)
		);
	}
		
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
	}
	
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
		ITokenizedUniswapV2Position(callbackData.pool.nftlp).redeem(callbackData.redeemTo, redeemTokenId);
		
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
		pool.uniswapV2Pair = ITokenizedUniswapV2Position(nftlp).underlying();
		pool.tokens[0] = IBorrowable(pool.borrowables[0]).underlying();
		pool.tokens[1] = IBorrowable(pool.borrowables[1]).underlying();
	}
}
