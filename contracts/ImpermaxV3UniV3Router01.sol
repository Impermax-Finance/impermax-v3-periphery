pragma solidity =0.5.16;
pragma experimental ABIEncoderV2;

import "./ImpermaxV3BaseRouter01.sol";
import "./interfaces/IV3UniV3Router01.sol";
import "./libraries/TickMath.sol";
import "./libraries/LiquidityAmounts.sol";
import "./impermax-v3-core/interfaces/ICollateral.sol";
import "./impermax-v3-core/extensions/interfaces/ITokenizedUniswapV3Position.sol";
import "./impermax-v3-core/extensions/interfaces/IUniswapV3Factory.sol";
import "./impermax-v3-core/extensions/interfaces/IUniswapV3Pool.sol";

contract ImpermaxV3UniV3Router01 is IV3UniV3Router01, ImpermaxV3BaseRouter01 {
	address public uniswapV3Factory;
	
	constructor(address _factory, address _uniswapV3Factory, address _WETH) public ImpermaxV3BaseRouter01(_factory, _WETH) {
		uniswapV3Factory = _uniswapV3Factory;
	}
	
	/*** Data Structures ***/
	
	struct MintUniV3EmptyData {
		uint24 fee;
		int24 tickLower;
		int24 tickUpper;
	}
	struct MintUniV3InternalData {
		uint128 liquidity;
		uint amount0User;
		uint amount1User;
		uint amount0Router;
		uint amount1Router;
	}
	struct MintUniV3Data {
		uint amount0Desired;
		uint amount1Desired;
		uint amount0Min;
		uint amount1Min;
	}
	struct RedeemUniV3Data {
		uint percentage;
		uint amount0Min;
		uint amount1Min;
		address to;
	}
	struct BorrowAndMintUniV3Data {
		uint amount0User;
		uint amount1User;
		uint amount0Desired;
		uint amount1Desired;
		uint amount0Min;
		uint amount1Min;
	}
	
	// callbacks
	struct UniV3MintCallbackData {
		address msgSender;
		address token0;
		address token1;
		uint24 fee;
		uint amount0Router;
		uint amount1Router;
	}
	
	/*** Primitive Actions ***/
	
	function _mintUniV3Empty(
		LendingPool memory pool,
		uint24 fee,
		int24 tickLower,
		int24 tickUpper
	) internal returns (uint tokenId) {
		tokenId = ITokenizedUniswapV3Position(pool.nftlp).mint(pool.collateral, fee, tickLower, tickUpper);
		ICollateral(pool.collateral).mint(address(this), tokenId);
	}
	function _mintUniV3Internal(
		LendingPool memory pool,
		uint tokenId,
		address msgSender,
		uint128 liquidity,
		uint amount0User,
		uint amount1User,
		uint amount0Router,
		uint amount1Router
	) internal {
		(uint24 fee, int24 tickLower, int24 tickUpper,,,) = ITokenizedUniswapV3Position(pool.nftlp).positions(tokenId);
		address uniswapV3Pool = ITokenizedUniswapV3Position(pool.nftlp).getPool(fee);
		
		// TODO this is the same as _mintUniV2Internal
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

		bytes memory encoded = abi.encode(UniV3MintCallbackData({
			msgSender: msgSender,
			token0: pool.tokens[0],
			token1: pool.tokens[1],
			fee: fee,
			amount0Router: amount0Router,
			amount1Router: amount1Router
		}));
		IUniswapV3Pool(uniswapV3Pool).mint(pool.nftlp, tickLower, tickUpper, liquidity, encoded);
		
		uint tokenToJoin = ITokenizedUniswapV3Position(pool.nftlp).mint(address(this), fee, tickLower, tickUpper);
		ITokenizedUniswapV3Position(pool.nftlp).join(tokenId, tokenToJoin);
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
		(uint24 fee, int24 tickLower, int24 tickUpper,,,) = ITokenizedUniswapV3Position(pool.nftlp).positions(tokenId);
		address uniswapV3Pool = ITokenizedUniswapV3Position(pool.nftlp).getPool(fee);
		(uint128 liquidity, uint amount0, uint amount1) = _optimalLiquidityUniV3(uniswapV3Pool, tickLower, tickUpper, amount0Desired, amount1Desired, amount0Min, amount1Min);
		_mintUniV3Internal(pool, tokenId, msgSender, liquidity, amount0, amount1, 0, 0);
	}
	
	function _redeemUniV3Step1(
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
		bytes memory decoded = abi.encode(RedeemCallbackData({
			pool: pool,
			msgSender: msgSender,
			redeemTo: to,
			amount0Min: amount0Min,
			amount1Min: amount1Min,
			nextAction: nextAction
		}));
		ICollateral(pool.collateral).redeem(address(this), tokenId, percentage, decoded);
	}
	function _redeemStep2(
		LendingPool memory pool,
		uint redeemTokenId,
		uint amount0Min,
		uint amount1Min,
		address to
	) internal {
		(uint amount0, uint amount1) = ITokenizedUniswapV3Position(pool.nftlp).redeem(to, redeemTokenId);
		require(amount0 >= amount0Min, "ImpermaxRouter: INSUFFICIENT_0_AMOUNT");
		require(amount1 >= amount1Min, "ImpermaxRouter: INSUFFICIENT_1_AMOUNT");
	}
	
	/*** Action Getters ***/
	
	function getMintUniV3EmptyAction(uint24 fee, int24 tickLower, int24 tickUpper) public pure returns (Action memory) {
		return _getAction(ActionType.MINT_UNIV3_EMPTY, abi.encode(MintUniV3EmptyData({
			fee: fee,
			tickLower: tickLower,
			tickUpper: tickUpper
		})));
	}
	function getMintUniV3InternalAction(uint128 liquidity, uint amount0User, uint amount1User, uint amount0Router, uint amount1Router) internal pure returns (Action memory) {
		return _getAction(ActionType.MINT_UNIV3_INTERNAL, abi.encode(MintUniV3InternalData({
			liquidity: liquidity,
			amount0User: amount0User,
			amount1User: amount1User,
			amount0Router: amount0Router,
			amount1Router: amount1Router
		})));
	}
	function getMintUniV3Action(uint amount0Desired, uint amount1Desired, uint amount0Min, uint amount1Min) public pure returns (Action memory) {
		return _getAction(ActionType.MINT_UNIV3, abi.encode(MintUniV3Data({
			amount0Desired: amount0Desired,
			amount1Desired: amount1Desired,
			amount0Min: amount0Min,
			amount1Min: amount1Min
		})));
	}
	
	function getRedeemUniV3Action(uint percentage, uint amount0Min, uint amount1Min, address to) public pure returns (Action memory) {
		return _getAction(ActionType.REDEEM_UNIV3, abi.encode(RedeemUniV3Data({
			percentage: percentage,
			amount0Min: amount0Min,
			amount1Min: amount1Min,
			to: to
		})));
	}
	
	/*** Composite Actions ***/
	
	function _borrowAndMintUniV3(
		LendingPool memory pool,
		uint tokenId,
		uint amount0User,
		uint amount1User,
		uint amount0Desired,	// intended as user amount + router amount
		uint amount1Desired,	// intended as user amount + router amount
		uint amount0Min,		// intended as user amount + router amount
		uint amount1Min			// intended as user amount + router amount
	) internal returns (Action[] memory a) {
		(uint24 fee, int24 tickLower, int24 tickUpper,,,) = ITokenizedUniswapV3Position(pool.nftlp).positions(tokenId);
		address uniswapV3Pool = ITokenizedUniswapV3Position(pool.nftlp).getPool(fee);
		(uint128 liquidity, uint amount0, uint amount1) = _optimalLiquidityUniV3(uniswapV3Pool, tickLower, tickUpper, amount0Desired, amount1Desired, amount0Min, amount1Min);
		(uint amount0Router, uint amount1Router) = (
			amount0 > amount0User ? amount0 - amount0User : 0,
			amount1 > amount1User ? amount1 - amount1User : 0
		);

		a = new Action[](3);		
		a[0] = getBorrowAction(0, amount0Router, address(this));
		a[1] = getBorrowAction(1, amount1Router, address(this));
		a[2] = getMintUniV3InternalAction(liquidity, amount0 - amount0Router, amount1 - amount1Router, amount0Router, amount1Router);
	}
	function getBorrowAndMintUniV3Action(
		uint amount0User,
		uint amount1User,
		uint amount0Desired,	// intended as user amount + router amount
		uint amount1Desired,	// intended as user amount + router amount
		uint amount0Min,		// intended as user amount + router amount
		uint amount1Min			// intended as user amount + router amount
	) external pure returns (Action memory) {
		return _getAction(ActionType.BORROW_AND_MINT_UNIV3, abi.encode(BorrowAndMintUniV3Data({
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
		if (action.actionType == ActionType.MINT_UNIV3_EMPTY) {
			MintUniV3EmptyData memory decoded = abi.decode(action.actionData, (MintUniV3EmptyData));
			tokenId = _mintUniV3Empty(
				pool,
				decoded.fee,
				decoded.tickLower,
				decoded.tickUpper
			);
		}
		else if (action.actionType == ActionType.MINT_UNIV3_INTERNAL) {
			MintUniV3InternalData memory decoded = abi.decode(action.actionData, (MintUniV3InternalData));
			_mintUniV3Internal(
				pool,
				tokenId,
				msgSender,
				decoded.liquidity,
				decoded.amount0User,
				decoded.amount1User,
				decoded.amount0Router,
				decoded.amount1Router
			);
		}
		else if (action.actionType == ActionType.MINT_UNIV3) {
			MintUniV3Data memory decoded = abi.decode(action.actionData, (MintUniV3Data));
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
		else if (action.actionType == ActionType.REDEEM_UNIV3) {
			RedeemUniV3Data memory decoded = abi.decode(action.actionData, (RedeemUniV3Data));
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
		else if (action.actionType == ActionType.BORROW_AND_MINT_UNIV3) {
			BorrowAndMintUniV3Data memory decoded = abi.decode(action.actionData, (BorrowAndMintUniV3Data));
			Action[] memory actions = _borrowAndMintUniV3(
				pool,
				tokenId,
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
		require(actionType == ActionType.MINT_UNIV3_EMPTY, "ImpermaxRouter: INVALID_FIRST_ACTION");
	}
	
	/*** Callbacks ***/
	
	function uniswapV3MintCallback(uint256 amount0Owed, uint256 amount1Owed, bytes calldata data) external {	
		UniV3MintCallbackData memory decoded = abi.decode(data, (UniV3MintCallbackData));
		
		// only succeeds if called by a uniswapV3Pool
		address uniswapV3Pool = IUniswapV3Factory(uniswapV3Factory).getPool(decoded.token0, decoded.token1, decoded.fee);
		require(msg.sender == uniswapV3Pool);
		
		uint amount0Router = Math.min(amount0Owed, decoded.amount0Router);
		uint amount1Router = Math.min(amount0Owed, decoded.amount1Router);
		uint amount0User = amount0Router < amount0Owed ? amount0Owed - amount0Router : 0;
		uint amount1User = amount1Router < amount1Owed ? amount1Owed - amount1Router : 0;
		
		if (amount0User > 0) ImpermaxPermit.safeTransferFrom(decoded.token0, decoded.msgSender, uniswapV3Pool, amount0User);
		if (amount1User > 0) ImpermaxPermit.safeTransferFrom(decoded.token1, decoded.msgSender, uniswapV3Pool, amount1User);
		if (amount0Router > 0) TransferHelper.safeTransfer(decoded.token0, uniswapV3Pool, amount0Router);
		if (amount1Router > 0) TransferHelper.safeTransfer(decoded.token1, uniswapV3Pool, amount1Router);
	}
	
	/*** Utilities ***/
	
	function _optimalLiquidityUniV3(
		address uniswapV3Pool,
		int24 tickLower,
		int24 tickUpper,
		uint amount0Desired,
		uint amount1Desired,
		uint amount0Min,
		uint amount1Min
	) public view returns (uint128 liquidity, uint amount0, uint amount1) {		
		(uint160 sqrtPriceX96, , , , , , ) = IUniswapV3Pool(uniswapV3Pool).slot0();
		uint160 sqrtRatioAX96 = TickMath.getSqrtRatioAtTick(tickLower);
		uint160 sqrtRatioBX96 = TickMath.getSqrtRatioAtTick(tickUpper);

		liquidity = LiquidityAmounts.getLiquidityForAmounts(
			sqrtPriceX96,
			sqrtRatioAX96,
			sqrtRatioBX96,
			amount0Desired,
			amount1Desired
		);
		// get amountsOut
		(amount0, amount1) = LiquidityAmounts.getAmountsForLiquidity(
			sqrtPriceX96,
			sqrtRatioAX96,
			sqrtRatioBX96,
			liquidity
		);
		// round up to get amountsIn
		if (amount0 < amount0Desired) amount0++; 
		if (amount1 < amount1Desired) amount1++; 
		
		require(amount0 >= amount0Min, "ImpermaxRouter: INSUFFICIENT_0_AMOUNT");
		require(amount1 >= amount1Min, "ImpermaxRouter: INSUFFICIENT_1_AMOUNT");
	}
}
