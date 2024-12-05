pragma solidity >=0.5.0;
pragma experimental ABIEncoderV2;

interface IV3BaseRouter01 {
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
		ActionType actionType;
		bytes actionData;
		bytes nextAction;
	}
	
	function execute(
		address nftlp,
		uint _tokenId,
		bytes calldata actionsData,
		bytes calldata permitsData,
		bool withCollateralTransfer
	) external payable;
	
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
}
