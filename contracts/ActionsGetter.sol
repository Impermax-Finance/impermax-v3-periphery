pragma solidity =0.5.16;
pragma experimental ABIEncoderV2;

import "./libraries/Actions.sol";

contract ActionsGetter {

	constructor () public {}

	function getNoAction() public pure returns (Actions.Action memory) {
		return Actions.getNoAction();
	}
	
	function getBorrowAction(uint8 index, uint amount, address to) external pure returns (Actions.Action memory) {
		return Actions.getBorrowAction(index, amount, to);
	}
	
	function getRepayUserAction(uint8 index, uint amountMax) external pure returns (Actions.Action memory) {
		return Actions.getRepayUserAction(index, amountMax);
	}
	function getRepayRouterAction(uint8 index, uint amountMax, address refundTo) external pure returns (Actions.Action memory) {
		return Actions.getRepayRouterAction(index, amountMax, refundTo);
	}
	
	function getWithdrawTokenAction(address token, address to) external pure returns (Actions.Action memory) {
		return Actions.getWithdrawTokenAction(token, to);
	}
	
	function getWithdrawEthAction(address to) external pure returns (Actions.Action memory) {
		return Actions.getWithdrawEthAction(to);
	}
	
	function getMintUniV2EmptyAction() external pure returns (Actions.Action memory) {
		return Actions.getMintUniV2EmptyAction();
	}
	function getMintUniV2InternalAction(uint lpAmountUser, uint amount0User, uint amount1User, uint amount0Router, uint amount1Router) external pure returns (Actions.Action memory) {
		return Actions.getMintUniV2InternalAction(lpAmountUser, amount0User, amount1User, amount0Router, amount1Router);
	}
	function getMintUniV2Action(uint lpAmountUser, uint amount0Desired, uint amount1Desired, uint amount0Min, uint amount1Min) external pure returns (Actions.Action memory) {
		return Actions.getMintUniV2Action(lpAmountUser, amount0Desired, amount1Desired, amount0Min, amount1Min);
	}
	
	function getRedeemUniV2Action(uint percentage, uint amount0Min, uint amount1Min, address to) external pure returns (Actions.Action memory) {
		return Actions.getRedeemUniV2Action(percentage, amount0Min, amount1Min, to);
	}
	
	function getMintUniV3EmptyAction(uint24 fee, int24 tickLower, int24 tickUpper) external pure returns (Actions.Action memory) {
		return Actions.getMintUniV3EmptyAction(fee, tickLower, tickUpper);
	}
	
	function getBorrowAndMintUniV2Action(
		uint lpAmountUser,
		uint amount0User,
		uint amount1User,
		uint amount0Desired,	// intended as user amount + router amount
		uint amount1Desired,	// intended as user amount + router amount
		uint amount0Min,		// intended as user amount + router amount
		uint amount1Min			// intended as user amount + router amount
	) external pure returns (Actions.Action memory) {
		return Actions.getBorrowAndMintUniV2Action(
			lpAmountUser,
			amount0User,
			amount1User,
			amount0Desired,	
			amount1Desired,	
			amount0Min,		
			amount1Min
		);
	}
	
	function getMintUniV3Action(uint amount0Desired, uint amount1Desired, uint amount0Min, uint amount1Min) external pure returns (Actions.Action memory) {
		return Actions.getMintUniV3Action(amount0Desired, amount1Desired, amount0Min, amount1Min);
	}
	
	function getMintUniV3InternalAction(uint128 liquidity, uint amount0User, uint amount1User, uint amount0Router, uint amount1Router) external pure returns (Actions.Action memory) {
		return Actions.getMintUniV3InternalAction(liquidity, amount0User, amount1User, amount0Router, amount1Router);
	}
	
	function getRedeemUniV3Action(uint percentage, uint amount0Min, uint amount1Min, address to) external pure returns (Actions.Action memory) {
		return Actions.getRedeemUniV3Action(percentage, amount0Min, amount1Min, to);
	}
	
	function getBorrowAndMintUniV3Action(
		uint amount0User,
		uint amount1User,
		uint amount0Desired,	// intended as user amount + router amount
		uint amount1Desired,	// intended as user amount + router amount
		uint amount0Min,		// intended as user amount + router amount
		uint amount1Min			// intended as user amount + router amount
	) external pure returns (Actions.Action memory) {
		return Actions.getBorrowAndMintUniV3Action(
			amount0User,
			amount1User,
			amount0Desired,	
			amount1Desired,	
			amount0Min,		
			amount1Min
		);
	}
}
