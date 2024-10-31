pragma solidity >=0.5.0;
pragma experimental ABIEncoderV2;

/**
	TODO
	- permits 
	- permits erc20
	- and test all approvals
	- cleanup and check other TODOs
	- make sure of reentrancy attack through execute
	- AddLiquidityUniV2 for uniswapV3
	- test uniswapV3
	- try to merge everything in a single contract
*/

interface IRouter01V3 {
	struct LendingPool {
		address uniswapV2Pair;
		address nftlp;
		address collateral;
		address[2] borrowables;
		address[2] tokens;
	}
	function getLendingPool(address nftlp) external view returns (LendingPool memory pool);
		
	enum ActionType {
		MINT_COLLATERAL,
		REDEEM_COLLATERAL, 
		BORROW, 
		REPAY_USER,
		REPAY_ROUTER,
		ADD_LIQUIDITY_UNIV2_INTERNAL, 
		ADD_LIQUIDITY_UNIV2, 
		REMOVE_LIQUIDITY_UNIV2,
		WITHDRAW_TOKEN,
		WITHDRAW_ETH,
		NO_ACTION,
		BORROW_AND_ADD_LIQUIDITY_UNIV2
	}
	struct Action {
		ActionType actionType;
		bytes actionData;
		bytes nextAction;
	}
	
	function execute(
		address nftlp,
		uint _tokenId,
		uint deadline,
		bytes calldata actionsData,
		bytes calldata permitsData
	) external payable returns (uint tokenId);
	
	/*** Available actions ***/
		
	// mint/redeem
	function getMintCollateralAction(uint lpAmount) external pure returns (Action memory);
	function getRedeemCollateralAction(
		uint percentage, 
		address to
	) external pure returns (Action memory);
	
	// borrow
	function getBorrowAction(
		uint8 index, 
		uint amount, 
		address to
	) external pure returns (Action memory);
	
	// repay
	function getRepayUserAction(
		uint8 index, 
		uint amountMax
	) external pure returns (Action memory);
	function getRepayRouterAction(
		uint8 index, 
		uint amountMax,
		address refundTo
	) external pure returns (Action memory);
	
	// add liquidity
	function getAddLiquidityUniV2Action(
		uint amount0Desired, 	// intended as user amount
		uint amount1Desired, 	// intended as user amount
		uint amount0Min, 		// intended as user amount
		uint amount1Min, 		// intended as user amount
		address to
	) external pure returns (Action memory);
	function getBorrowAndAddLiquidityUniV2Action(
		uint amount0User,
		uint amount1User,
		uint amount0Desired,	// intended as user amount + router amount
		uint amount1Desired,	// intended as user amount + router amount
		uint amount0Min,		// intended as user amount + router amount
		uint amount1Min,		// intended as user amount + router amount
		address to
	) external pure returns (Action memory);
	
	// remove liquidity
	function getRemoveLiquidityUniV2Action(
		uint lpAmount,
		uint amount0Min, 
		uint amount1Min, 
		address to
	) external pure returns (Action memory);
	
	// withdraw token (for advanced use cases)
	function getWithdrawTokenAction(
		address token, 
		address to
	) external pure returns (Action memory);
	
	// withdraw ETH (expect WETH to be in the contract)
	function getWithdrawEthAction(
		address to
	) external pure returns (Action memory);
	
}
