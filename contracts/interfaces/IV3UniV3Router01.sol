pragma solidity >=0.5.0;
pragma experimental ABIEncoderV2;

import "./IV3BaseRouter01.sol";

interface IV3UniV3Router01 {
	function getLendingPool(address nftlp) external view returns (IV3BaseRouter01.LendingPool memory pool);
	
	function execute(
		address nftlp,
		uint _tokenId,
		uint deadline,
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
	) external pure returns (IV3BaseRouter01.Action memory);
	
	// repay
	function getRepayUserAction(
		uint8 index, 
		uint amountMax
	) external pure returns (IV3BaseRouter01.Action memory);
	function getRepayRouterAction(
		uint8 index, 
		uint amountMax,
		address refundTo
	) external pure returns (IV3BaseRouter01.Action memory);
	
	// withdraw token (for advanced use cases)
	function getWithdrawTokenAction(
		address token, 
		address to
	) external pure returns (IV3BaseRouter01.Action memory);
	
	// withdraw ETH (expect WETH to be in the contract)
	function getWithdrawEthAction(
		address to
	) external pure returns (IV3BaseRouter01.Action memory);

	// add liquidity
	function getMintUniV3EmptyAction(
		uint24 fee,
		int24 tickLower,
		int24 tickUpper
	) external pure returns (IV3BaseRouter01.Action memory);
	function getMintUniV3Action(
		uint amount0Desired, 	// intended as user amount
		uint amount1Desired, 	// intended as user amount
		uint amount0Min, 		// intended as user amount
		uint amount1Min			// intended as user amount
	) external pure returns (IV3BaseRouter01.Action memory);
	function getBorrowAndMintUniV3Action(
		uint amount0User,
		uint amount1User,
		uint amount0Desired,	// intended as user amount + router amount
		uint amount1Desired,	// intended as user amount + router amount
		uint amount0Min,		// intended as user amount + router amount
		uint amount1Min		// intended as user amount + router amount
	) external pure returns (IV3BaseRouter01.Action memory);
	
	// remove liquidity
	function getRedeemUniV3Action(
		uint percentage,
		uint amount0Min, 
		uint amount1Min, 
		address to
	) external pure returns (IV3BaseRouter01.Action memory);
	
}
