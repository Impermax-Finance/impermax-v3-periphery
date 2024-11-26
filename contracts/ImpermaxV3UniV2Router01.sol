pragma solidity =0.5.16;
pragma experimental ABIEncoderV2;

import "./ImpermaxV3BaseRouter01.sol";
import "./interfaces/IERC20.sol";
import "./interfaces/IUniswapV2Pair.sol";
import "./interfaces/IV3UniV2Router01.sol";
import "./libraries/Math.sol";
import "./libraries/SafeMath.sol";
import "./libraries/TransferHelper.sol";
import "./libraries/UniswapV2Library.sol";
import "./impermax-v3-core/interfaces/ICollateral.sol";
import "./impermax-v3-core/extensions/interfaces/ITokenizedUniswapV2Position.sol";

contract ImpermaxV3UniV2Router01 is IV3UniV2Router01, ImpermaxV3BaseRouter01 {
	using SafeMath for uint;

	constructor(address _factory, address _WETH) public ImpermaxV3BaseRouter01(_factory, _WETH) {}
	
	/*** Data Structures ***/
	
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
		Action memory nextAction
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
	
	/*** Action Getters ***/
	
	function getMintUniV2EmptyAction() public pure returns (Action memory) {
		return _getAction(ActionType.MINT_UNIV2_EMPTY, bytes(""));
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
		(uint amount0, uint amount1) = _optimalLiquidityUniV2(uniswapV2Pair, amount0Desired, amount1Desired, amount0Min, amount1Min);
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
	
	/*** EXECUTE ***/
	
	function _execute(
		LendingPool memory pool,
		uint tokenId,
		address msgSender,
		Action memory action
	) internal returns (uint) {
		if (action.actionType == ActionType.NO_ACTION) return tokenId;
		Action memory nextAction = abi.decode(action.nextAction, (Action));
		if (action.actionType == ActionType.MINT_UNIV2_EMPTY) {
			tokenId = _mintUniV2Empty(pool);
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
			return tokenId;
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
		else return super._execute(pool, tokenId, msgSender, action);
		
		return _execute(
			pool,
			tokenId,
			msgSender,
			nextAction
		);
	}
	
	function _checkFirstAction(ActionType actionType) internal {
		require(actionType == ActionType.MINT_UNIV2_EMPTY, "ImpermaxRouter: INVALID_FIRST_ACTION");
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
