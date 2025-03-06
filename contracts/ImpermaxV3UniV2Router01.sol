pragma solidity =0.5.16;
pragma experimental ABIEncoderV2;

import "./ImpermaxV3BaseRouter01.sol";
import "./interfaces/IUniswapV2Pair.sol";
import "./libraries/UniswapV2Library.sol";
import "./impermax-v3-core/interfaces/ICollateral.sol";
import "./impermax-v3-core/extensions/interfaces/ITokenizedUniswapV2Position.sol";

contract ImpermaxV3UniV2Router01 is ImpermaxV3BaseRouter01 {

	constructor(address _factory, address _WETH) public ImpermaxV3BaseRouter01(_factory, _WETH) {}
	
	/*** Primitive Actions ***/
	
	function _mintUniV2Empty(
		LendingPool memory pool
	) internal returns (uint tokenId) {
		tokenId = ITokenizedUniswapV2Position(pool.nftlp).mint(pool.collateral);
		ICollateral(pool.collateral).mint(address(this), tokenId);
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
		if (amount0User > 0) ImpermaxPermit.safeTransferFrom(pool.tokens[0], msgSender, uniswapV2Pair, amount0User);
		if (amount1User > 0) ImpermaxPermit.safeTransferFrom(pool.tokens[1], msgSender, uniswapV2Pair, amount1User);
		if (amount0Router > 0) TransferHelper.safeTransfer(pool.tokens[0], uniswapV2Pair, amount0Router);
		if (amount1Router > 0) TransferHelper.safeTransfer(pool.tokens[1], uniswapV2Pair, amount1Router);
		// mint LP token
		if (amount0User + amount0Router > 0) IUniswapV2Pair(uniswapV2Pair).mint(pool.nftlp);
		// mint collateral
		if (lpAmountUser > 0) ImpermaxPermit.safeTransferFrom(uniswapV2Pair, msgSender, pool.nftlp, lpAmountUser);
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
		(uint amount0, uint amount1) = _optimalLiquidityUniV2(uniswapV2Pair, amount0Desired, amount1Desired, amount0Min, amount1Min);
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
		Actions.Action memory nextAction
	) internal {
		require(percentage > 0, "ImpermaxRouter: REDEEM_ZERO");
		bytes memory encoded = abi.encode(RedeemCallbackData({
			pool: pool,
			msgSender: msgSender,
			redeemTo: to,
			amount0Min: amount0Min,
			amount1Min: amount1Min,
			nextAction: nextAction
		}));
		ICollateral(pool.collateral).redeem(address(this), tokenId, percentage, encoded);
	}
	function _redeemStep2(
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
	) internal view returns (Actions.Action[] memory a) {
		address uniswapV2Pair = ITokenizedUniswapV2Position(pool.nftlp).underlying();
		(uint amount0, uint amount1) = _optimalLiquidityUniV2(uniswapV2Pair, amount0Desired, amount1Desired, amount0Min, amount1Min);
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
		a[a.length-1] = Actions.getMintUniV2InternalAction(lpAmountUser, amount0 - amount0Router, amount1 - amount1Router, amount0Router, amount1Router);
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
		if (action.actionType == Actions.Type.MINT_UNIV2_EMPTY) {
			tokenId = _mintUniV2Empty(pool);
		}
		else if (action.actionType == Actions.Type.MINT_UNIV2_INTERNAL) {
			Actions.MintUniV2InternalData memory decoded = abi.decode(action.actionData, (Actions.MintUniV2InternalData));
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
		else if (action.actionType == Actions.Type.MINT_UNIV2) {
			Actions.MintUniV2Data memory decoded = abi.decode(action.actionData, (Actions.MintUniV2Data));
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
		else if (action.actionType == Actions.Type.REDEEM_UNIV2) {
			Actions.RedeemUniV2Data memory decoded = abi.decode(action.actionData, (Actions.RedeemUniV2Data));
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
			return tokenId;
		}
		else if (action.actionType == Actions.Type.BORROW_AND_MINT_UNIV2) {
			Actions.BorrowAndMintUniV2Data memory decoded = abi.decode(action.actionData, (Actions.BorrowAndMintUniV2Data));
			Actions.Action[] memory actions = _borrowAndMintUniV2(
				pool,
				decoded.lpAmountUser,
				decoded.amount0User,
				decoded.amount1User,
				decoded.amount0Desired,
				decoded.amount1Desired,
				decoded.amount0Min,
				decoded.amount1Min
			);
			nextAction = Actions.actionsSorter(actions, nextAction);
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
		require(actionType == Actions.Type.MINT_UNIV2_EMPTY, "ImpermaxRouter: INVALID_FIRST_ACTION");
	}
	
	/*** Utilities ***/
	
	function _optimalLiquidityUniV2(
		address uniswapV2Pair,
		uint amount0Desired,
		uint amount1Desired,
		uint amount0Min,
		uint amount1Min
	) public view returns (uint amount0, uint amount1) {
		if (amount0Desired == 0) return (0, 0);
		(uint reserve0, uint reserve1,) = IUniswapV2Pair(uniswapV2Pair).getReserves();
		uint amount1Optimal = UniswapV2Library.quote(amount0Desired, reserve0, reserve1);
		if (amount1Optimal <= amount1Desired) {
			require(amount1Optimal >= amount1Min, "ImpermaxRouter: INSUFFICIENT_1_AMOUNT");
			(amount0, amount1) = (amount0Desired, amount1Optimal);
		} else {
			uint amount0Optimal = UniswapV2Library.quote(amount1Desired, reserve1, reserve0);
			assert(amount0Optimal <= amount0Desired);
			require(amount0Optimal >= amount0Min, "ImpermaxRouter: INSUFFICIENT_0_AMOUNT");
			(amount0, amount1) = (amount0Optimal, amount1Desired);
		}
	}
}
