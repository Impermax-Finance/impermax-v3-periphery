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
		address nftlp;
		address collateral;
		address[2] borrowables;
		address[2] tokens;
	}
	function getLendingPool(address nftlp) external view returns (LendingPool memory pool);
		
	enum ActionType {
		BORROW, 
		REPAY_USER,
		REPAY_ROUTER,
		WITHDRAW_TOKEN,
		WITHDRAW_ETH,
		NO_ACTION,
		MINT_UNIV2_INTERNAL, 
		MINT_UNIV2, 
		REDEEM_UNIV2,
		BORROW_AND_MINT_UNIV2
		//ADD_LIQUIDITY_UNIV3_INTERNAL, 
		//ADD_LIQUIDITY_UNIV3, 
		//REMOVE_LIQUIDITY_UNIV3,
		//BORROW_AND_ADD_LIQUIDITY_UNIV3
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
	
	// withdraw token (for advanced use cases)
	function getWithdrawTokenAction(
		address token, 
		address to
	) external pure returns (Action memory);
	
	// withdraw ETH (expect WETH to be in the contract)
	function getWithdrawEthAction(
		address to
	) external pure returns (Action memory);
	
	// add liquidity
	function getMintUniV2Action(
		uint lpAmountUser,
		uint amount0Desired, 	// intended as user amount
		uint amount1Desired, 	// intended as user amount
		uint amount0Min, 		// intended as user amount
		uint amount1Min			// intended as user amount
	) external pure returns (Action memory);
	function getBorrowAndMintUniV2Action(
		uint lpAmountUser,
		uint amount0User,
		uint amount1User,
		uint amount0Desired,	// intended as user amount + router amount
		uint amount1Desired,	// intended as user amount + router amount
		uint amount0Min,		// intended as user amount + router amount
		uint amount1Min		// intended as user amount + router amount
	) external pure returns (Action memory);
	
	// remove liquidity
	function getRedeemUniV2Action(
		uint percentage,
		uint amount0Min, 
		uint amount1Min, 
		address to
	) external pure returns (Action memory);
	
}
