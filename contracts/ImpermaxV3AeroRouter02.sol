pragma solidity =0.5.16;
pragma experimental ABIEncoderV2;

import "./ImpermaxV3BaseRouter02.sol";
import "./NextAeroIdGetter.sol";
import "./libraries/UniswapV3Math.sol";
import "./libraries/NfpmAeroInteractions.sol";
import "./interfaces/ISwapRouter.sol";
import "./impermax-v3-core/interfaces/ICollateral.sol";
import "./impermax-v3-core/extensions/interfaces/ITokenizedAeroCLFactory.sol";
import "./impermax-v3-core/extensions/interfaces/ITokenizedAeroCLPosition.sol";
import "./impermax-v3-core/extensions/interfaces/IUniswapV3Pool.sol";
import "./impermax-v3-core/extensions/interfaces/INonfungiblePositionManagerAero.sol";
import "./impermax-v3-core/extensions/interfaces/INftlpCallee.sol";

contract ImpermaxV3AeroRouter02 is ImpermaxV3BaseRouter02, INftlpCallee {
	address public tokenizedAeroCLFactory;
	address public nfpManager;
	address public nextAeroIdGetter;
	address public rewardsToken;
	address public swapRouter;
	
	// transaction data
	int24 private storedTickSpacing;
	int24 private storedTickLower;
	int24 private storedTickUpper;
	
	constructor(address _factory, address _tokenizedAeroCLFactory, address _WETH, address _vaultFactory, address _nextAeroIdGetter, address _swapRouter) public ImpermaxV3BaseRouter02(_factory, _WETH, _vaultFactory) {
		tokenizedAeroCLFactory = _tokenizedAeroCLFactory;
		nfpManager = ITokenizedAeroCLFactory(_tokenizedAeroCLFactory).nfpManager();
		nextAeroIdGetter = _nextAeroIdGetter;
		rewardsToken = ITokenizedAeroCLFactory(_tokenizedAeroCLFactory).rewardsToken();
		swapRouter = _swapRouter;
	}
	
	/*** Data Structures ***/
	
	// callbacks
	struct MintCallbackData {
		LendingPool pool;
		address msgSender;
		Actions.Action nextAction;
	}
	
	/*** Primitive Actions ***/
	
	function _getTicks(uint tokenId) internal returns (int24 tickSpacing, int24 tickLower, int24 tickUpper) {
		if (storedTickSpacing > 0) {
			tickSpacing = storedTickSpacing;
			tickLower = storedTickLower;
			tickUpper = storedTickUpper;
		} else {
			(,,,,tickSpacing, tickLower, tickUpper,) = INonfungiblePositionManagerAero(nfpManager).positions(tokenId);			
		}
	}
	function _mintAeroEmpty(
		LendingPool memory pool,
		address msgSender,
		int24 tickSpacing,
		int24 tickLower,
		int24 tickUpper,
		Actions.Action memory nextAction
	) internal returns (uint tokenId) {
		(tokenId,) = NextAeroIdGetter(nextAeroIdGetter).mintDummy();
		tokenId++;
		bytes memory encoded = abi.encode(MintCallbackData({
			pool: pool,
			msgSender: msgSender,
			nextAction: nextAction
		}));
		storedTickSpacing = tickSpacing;
		storedTickLower = tickLower;
		storedTickUpper = tickUpper;
		ITokenizedAeroCLPosition(pool.nftlp).mint(address(this), tokenId, encoded); 
	}
	function _mintUniV3Internal(
		LendingPool memory pool,
		uint tokenId,
		address msgSender,
		uint amount0User,
		uint amount1User,
		uint amount0Router,
		uint amount1Router
	) internal {
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
		
		if (storedTickSpacing > 0) {
			if (amount0User > 0) ImpermaxPermit.safeTransferFrom(pool.tokens[0], msgSender, address(this), amount0User);
			if (amount1User > 0) ImpermaxPermit.safeTransferFrom(pool.tokens[1], msgSender, address(this), amount1User);
			
			NfpmAeroInteractions.mint(nfpManager, pool.tokens[0], pool.tokens[1], storedTickSpacing, storedTickLower, storedTickUpper, pool.nftlp);
		} else {
			if (amount0User > 0) ImpermaxPermit.safeTransferFrom(pool.tokens[0], msgSender, pool.nftlp, amount0User);
			if (amount1User > 0) ImpermaxPermit.safeTransferFrom(pool.tokens[1], msgSender, pool.nftlp, amount1User);
			if (amount0Router > 0) TransferHelper.safeTransfer(pool.tokens[0], pool.nftlp, amount0Router);
			if (amount1Router > 0) TransferHelper.safeTransfer(pool.tokens[1], pool.nftlp, amount1Router);
			ITokenizedAeroCLPosition(pool.nftlp).increaseLiquidity(tokenId);
			ITokenizedAeroCLPosition(pool.nftlp).skim(msgSender);
		}
	}
	function _mintUniV3(
		LendingPool memory pool,
		uint tokenId,
		address msgSender,
		uint amount0Desired,	// intended as user amount
		uint amount1Desired,	// intended as user amount
		uint amount0Min,
		uint amount1Min
	) internal {
		(int24 tickSpacing, int24 tickLower, int24 tickUpper) = _getTicks(tokenId);

		address uniswapV3Pool = ITokenizedAeroCLPosition(pool.nftlp).getPool(tickSpacing);
		(, uint amount0, uint amount1) = UniswapV3Math.optimalLiquidity(uniswapV3Pool, tickLower, tickUpper, amount0Desired, amount1Desired, amount0Min, amount1Min);
		_mintUniV3Internal(pool, tokenId, msgSender, amount0, amount1, 0, 0);
	}
	
	function _redeemUniV3Step1(
		LendingPool memory pool,
		uint tokenId,
		address msgSender,
		uint percentage,
		uint amount0Min,
		uint amount1Min,
		address to,
		Actions.Action memory nextAction
	) internal {
		if (percentage == 1e18) {
			(int24 tickSpacing, int24 tickLower, int24 tickUpper) = _getTicks(tokenId);
			storedTickSpacing = tickSpacing;
			storedTickLower = tickLower;
			storedTickUpper = tickUpper;
		}
		
		require(percentage > 0, "ImpermaxRouter: REDEEM_ZERO");
		bytes memory decoded = abi.encode(ImpermaxV3BaseRouter02Library.RedeemCallbackData({
			pool: pool,
			msgSender: msgSender,
			redeemTo: to,
			amount0Min: amount0Min,
			amount1Min: amount1Min,
			nextAction: nextAction
		}));
		ICollateral(pool.collateral).redeem(address(this), tokenId, percentage, decoded);
		ITokenizedAeroCLPosition(pool.nftlp).skim(msgSender);
	}
	function _redeemStep2(
		LendingPool memory pool,
		uint redeemTokenId,
		uint amount0Min,
		uint amount1Min,
		address to
	) internal {
		ITokenizedAeroCLPosition(pool.nftlp).redeem(address(this), redeemTokenId);
		NfpmAeroInteractions.decrease(nfpManager, redeemTokenId, 1e18, to, amount0Min, amount1Min);
	}

	function _updateAllowance(address token) internal {
		uint allowance = IERC20(token).allowance(address(this), swapRouter);
		if (allowance < uint(-1) / 2) IERC20(token).approve(swapRouter, uint(-1)); 
	}
	
	function _swap(
		LendingPool memory pool,
		uint8 indexOut,
		uint tokenId,
		uint amountOut,
		uint160 sqrtPriceLimitX96
	) internal {
		(int24 tickSpacing,,) = _getTicks(tokenId);
		
		address tokenIn = pool.tokens[indexOut == 0 ? 1 : 0];
		_updateAllowance(tokenIn);
		
		ISwapRouter(swapRouter).exactOutputSingle(ISwapRouter.ExactOutputSingleParams({
			tokenIn: tokenIn,
			tokenOut: pool.tokens[indexOut],
			tickSpacing: tickSpacing,
			recipient: address(this),
			deadline: uint(-1),
			amountOut: amountOut,
			amountInMaximum: uint(-1),
			sqrtPriceLimitX96: sqrtPriceLimitX96
		}));
	}
	
	/*** Composite Actions ***/
	
	function _borrowAndMintUniV3(
		LendingPool memory pool,
		uint tokenId,
		uint amount0User,
		uint amount1User,
		uint amount0,			// intended as user amount + router amount
		uint amount1,			// intended as user amount + router amount
		uint amount0Min,		// intended as user amount + router amount
		uint amount1Min			// intended as user amount + router amount
	) internal returns (Actions.Action[] memory a) {
		{
		(int24 tickSpacing, int24 tickLower, int24 tickUpper) = _getTicks(tokenId);
		address uniswapV3Pool = ITokenizedAeroCLPosition(pool.nftlp).getPool(tickSpacing);
		(, amount0, amount1) = UniswapV3Math.optimalLiquidity(uniswapV3Pool, tickLower, tickUpper, amount0, amount1, amount0Min, amount1Min);
		}
		(uint amount0Router, uint amount1Router) = (
			amount0 > amount0User ? amount0 - amount0User : 0,
			amount1 > amount1User ? amount1 - amount1User : 0
		);

		require(amount0Router > 0 || amount1Router > 0, "ImpermaxRouter: NO_ACTUAL_BORROWING");
		if (amount0Router > 0 && amount1Router > 0) {
			a = new Actions.Action[](3);		
			a[0] = Actions.getBorrowAction(0, amount0Router, address(this));
			a[1] = Actions.getBorrowAction(1, amount1Router, address(this));
		} else {
			a = new Actions.Action[](2);
			if (amount0Router > 0)	a[0] = Actions.getBorrowAction(0, amount0Router, address(this));
			if (amount1Router > 0)	a[0] = Actions.getBorrowAction(1, amount1Router, address(this));
		}
		a[a.length-1] = Actions.getMintUniV3InternalAction(0, amount0 - amount0Router, amount1 - amount1Router, amount0Router, amount1Router);
	}

	/*** EXECUTE ***/
	
	function _execute(
		LendingPool memory pool,
		uint tokenId,
		address msgSender,
		Actions.Action memory action
	) internal returns (uint) {
		if (action.actionType == Actions.Type.NO_ACTION) return tokenId;
		Actions.Action memory nextAction = abi.decode(action.nextAction, (Actions.Action));
		if (action.actionType == Actions.Type.MINT_AERO_EMPTY) {
			Actions.MintAeroEmptyData memory decoded = abi.decode(action.actionData, (Actions.MintAeroEmptyData));
			return _mintAeroEmpty(
				pool,
				msgSender,
				decoded.tickSpacing,
				decoded.tickLower,
				decoded.tickUpper,
				nextAction
			);
		}
		else if (action.actionType == Actions.Type.MINT_UNIV3_INTERNAL) {
			Actions.MintUniV3InternalData memory decoded = abi.decode(action.actionData, (Actions.MintUniV3InternalData));
			_mintUniV3Internal(
				pool,
				tokenId,
				msgSender,
				decoded.amount0User,
				decoded.amount1User,
				decoded.amount0Router,
				decoded.amount1Router
			);
		}
		else if (action.actionType == Actions.Type.MINT_UNIV3) {
			Actions.MintUniV3Data memory decoded = abi.decode(action.actionData, (Actions.MintUniV3Data));
			_mintUniV3(
				pool,
				tokenId,
				msgSender,
				decoded.amount0Desired,
				decoded.amount1Desired,
				decoded.amount0Min,
				decoded.amount1Min
			);
		}
		else if (action.actionType == Actions.Type.REDEEM_UNIV3) {
			Actions.RedeemUniV3Data memory decoded = abi.decode(action.actionData, (Actions.RedeemUniV3Data));
			_redeemUniV3Step1(
				pool,
				tokenId,
				msgSender,
				decoded.percentage,
				decoded.amount0Min,
				decoded.amount1Min,
				decoded.to,
				nextAction
			);
			return tokenId;
		}
		else if (action.actionType == Actions.Type.BORROW_AND_MINT_UNIV3) {
			Actions.BorrowAndMintUniV3Data memory decoded = abi.decode(action.actionData, (Actions.BorrowAndMintUniV3Data));
			Actions.Action[] memory actions = _borrowAndMintUniV3(
				pool,
				tokenId,
				decoded.amount0User,
				decoded.amount1User,
				decoded.amount0Desired,
				decoded.amount1Desired,
				decoded.amount0Min,
				decoded.amount1Min
			);
			nextAction = Actions.actionsSorter(actions, nextAction);
		}
		else if (action.actionType == Actions.Type.SWAP) {
			Actions.SwapData memory decoded = abi.decode(action.actionData, (Actions.SwapData));
			_swap(
				pool,
				decoded.indexOut,
				tokenId,
				decoded.amountOut,
				decoded.sqrtPriceLimitX96
			);
		}
		else return super._execute(pool, tokenId, msgSender, action);
		
		return _execute(
			pool,
			tokenId,
			msgSender,
			nextAction
		);
	}
	
	function _checkFirstAction(Actions.Type actionType) internal {
		require(actionType == Actions.Type.MINT_AERO_EMPTY, "ImpermaxRouter: INVALID_FIRST_ACTION");
	}
	
	function _reset() internal {
		ImpermaxV3BaseRouter02Library._withdrawToken(rewardsToken, msg.sender);
		storedTickSpacing = 0;
		storedTickLower = 0;
		storedTickUpper = 0;
	}
	
	/*** Callbacks ***/
	
	function nftlpMint(address sender, uint tokenId, bytes calldata data) external {
		MintCallbackData memory decoded = abi.decode(data, (MintCallbackData));
		
		// only succeeds if called by a nftlp and if that nftlp has been called by the router
		address declaredCaller = ITokenizedAeroCLFactory(tokenizedAeroCLFactory).getNFTLP(decoded.pool.tokens[0], decoded.pool.tokens[1]);
		require(sender == address(this), "ImpermaxRouter: SENDER_NOT_ROUTER");
		require(msg.sender == declaredCaller, "ImpermaxRouter: UNAUTHORIZED_CALLER");

		ITokenizedAeroCLPosition(decoded.pool.nftlp).transferFrom(address(this), decoded.pool.collateral, tokenId);
		ICollateral(decoded.pool.collateral).mint(address(this), tokenId);
		
		_execute(
			decoded.pool,
			tokenId,
			decoded.msgSender,
			decoded.nextAction
		);
	}
	
}
