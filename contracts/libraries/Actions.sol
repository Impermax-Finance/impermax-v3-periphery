pragma solidity =0.5.16;
pragma experimental ABIEncoderV2;

library Actions {

	enum Type {
		BORROW, 
		REPAY_USER,
		REPAY_ROUTER,
		WITHDRAW_TOKEN,
		WITHDRAW_ETH,
		NO_ACTION,
		MINT_UNIV2_EMPTY, 
		MINT_UNIV2_INTERNAL, 
		MINT_UNIV2, 
		REDEEM_UNIV2,
		BORROW_AND_MINT_UNIV2,
		MINT_UNIV3_EMPTY, 
		MINT_UNIV3_INTERNAL, 
		MINT_UNIV3, 
		REDEEM_UNIV3,
		BORROW_AND_MINT_UNIV3
	}
	struct Action {
		Type actionType;
		bytes actionData;
		bytes nextAction;
	}
	
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
	
	/*** Actions sorter: sorts actions and composite actions ***/
	
	function actionsSorter(Action[] memory actions, Action memory nextAction) public pure returns (Action memory) {
		require(actions.length > 0, "ImpermaxRouter: UNEXPECTED_ACTIONS_LENGTH");
		actions[actions.length-1].nextAction = abi.encode(nextAction);
		for(uint i = actions.length-1; i > 0; i--) {
			actions[i-1].nextAction = abi.encode(actions[i]);
		}
		return actions[0];
	}
	function actionsSorter(Action[] memory actions) public pure returns (Action memory) {
		return actionsSorter(actions, getNoAction());
	}
	
	/*** Action Getters ***/
	
	function _getAction(Type actionType, bytes memory actionData) private pure returns (Action memory) {
		return Action({
			actionType: actionType,
			actionData: actionData,
			nextAction: bytes("")
		});
	}
	
	function getNoAction() public pure returns (Action memory) {
		return _getAction(Type.NO_ACTION, bytes(""));
	}
	
	function getBorrowAction(uint8 index, uint amount, address to) external pure returns (Action memory) {
		return _getAction(Type.BORROW, abi.encode(BorrowData({
			index: index,
			amount: amount,
			to: to
		})));
	}
	
	function getRepayUserAction(uint8 index, uint amountMax) external pure returns (Action memory) {
		return _getAction(Type.REPAY_USER, abi.encode(RepayUserData({
			index: index,
			amountMax: amountMax
		})));
	}
	function getRepayRouterAction(uint8 index, uint amountMax, address refundTo) external pure returns (Action memory) {
		return _getAction(Type.REPAY_ROUTER, abi.encode(RepayRouterData({
			index: index,
			amountMax: amountMax,
			refundTo: refundTo
		})));
	}
	
	function getWithdrawTokenAction(address token, address to) external pure returns (Action memory) {
		return _getAction(Type.WITHDRAW_TOKEN, abi.encode(WithdrawTokenData({
			token: token,
			to: to
		})));
	}
	
	function getWithdrawEthAction(address to) external pure returns (Action memory) {
		return _getAction(Type.WITHDRAW_ETH, abi.encode(WithdrawEthData({
			to: to
		})));
	}
	
	function getMintUniV2EmptyAction() external pure returns (Action memory) {
		return _getAction(Type.MINT_UNIV2_EMPTY, bytes(""));
	}
	function getMintUniV2InternalAction(uint lpAmountUser, uint amount0User, uint amount1User, uint amount0Router, uint amount1Router) external pure returns (Action memory) {
		return _getAction(Type.MINT_UNIV2_INTERNAL, abi.encode(MintUniV2InternalData({
			lpAmountUser: lpAmountUser,
			amount0User: amount0User,
			amount1User: amount1User,
			amount0Router: amount0Router,
			amount1Router: amount1Router
		})));
	}
	function getMintUniV2Action(uint lpAmountUser, uint amount0Desired, uint amount1Desired, uint amount0Min, uint amount1Min) external pure returns (Action memory) {
		return _getAction(Type.MINT_UNIV2, abi.encode(MintUniV2Data({
			lpAmountUser: lpAmountUser,
			amount0Desired: amount0Desired,
			amount1Desired: amount1Desired,
			amount0Min: amount0Min,
			amount1Min: amount1Min
		})));
	}
	
	function getRedeemUniV2Action(uint percentage, uint amount0Min, uint amount1Min, address to) external pure returns (Action memory) {
		return _getAction(Type.REDEEM_UNIV2, abi.encode(RedeemUniV2Data({
			percentage: percentage,
			amount0Min: amount0Min,
			amount1Min: amount1Min,
			to: to
		})));
	}
	
	function getMintUniV3EmptyAction(uint24 fee, int24 tickLower, int24 tickUpper) external pure returns (Action memory) {
		return _getAction(Type.MINT_UNIV3_EMPTY, abi.encode(MintUniV3EmptyData({
			fee: fee,
			tickLower: tickLower,
			tickUpper: tickUpper
		})));
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
		return _getAction(Type.BORROW_AND_MINT_UNIV2, abi.encode(BorrowAndMintUniV2Data({
			lpAmountUser: lpAmountUser,
			amount0User: amount0User,
			amount1User: amount1User,
			amount0Desired: amount0Desired,
			amount1Desired: amount1Desired,
			amount0Min: amount0Min,
			amount1Min: amount1Min
		})));
	}
	
	function getMintUniV3Action(uint amount0Desired, uint amount1Desired, uint amount0Min, uint amount1Min) external pure returns (Action memory) {
		return _getAction(Type.MINT_UNIV3, abi.encode(MintUniV3Data({
			amount0Desired: amount0Desired,
			amount1Desired: amount1Desired,
			amount0Min: amount0Min,
			amount1Min: amount1Min
		})));
	}
	
	function getMintUniV3InternalAction(uint128 liquidity, uint amount0User, uint amount1User, uint amount0Router, uint amount1Router) external pure returns (Action memory) {
		return _getAction(Type.MINT_UNIV3_INTERNAL, abi.encode(MintUniV3InternalData({
			liquidity: liquidity,
			amount0User: amount0User,
			amount1User: amount1User,
			amount0Router: amount0Router,
			amount1Router: amount1Router
		})));
	}
	
	function getRedeemUniV3Action(uint percentage, uint amount0Min, uint amount1Min, address to) external pure returns (Action memory) {
		return _getAction(Type.REDEEM_UNIV3, abi.encode(RedeemUniV3Data({
			percentage: percentage,
			amount0Min: amount0Min,
			amount1Min: amount1Min,
			to: to
		})));
	}
	
	function getBorrowAndMintUniV3Action(
		uint amount0User,
		uint amount1User,
		uint amount0Desired,	// intended as user amount + router amount
		uint amount1Desired,	// intended as user amount + router amount
		uint amount0Min,		// intended as user amount + router amount
		uint amount1Min			// intended as user amount + router amount
	) external pure returns (Action memory) {
		return _getAction(Type.BORROW_AND_MINT_UNIV3, abi.encode(BorrowAndMintUniV3Data({
			amount0User: amount0User,
			amount1User: amount1User,
			amount0Desired: amount0Desired,
			amount1Desired: amount1Desired,
			amount0Min: amount0Min,
			amount1Min: amount1Min
		})));
	}
}
