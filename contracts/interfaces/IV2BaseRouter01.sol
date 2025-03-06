pragma solidity >=0.5.0;
pragma experimental ABIEncoderV2;

interface IV2BaseRouter01 {
	struct LendingPool {
		address lp;
		address collateral;
		address[2] borrowables;
		address[2] tokens;
	}
	function getLendingPool(address lp) external view returns (LendingPool memory pool);
	function factory() external view returns (address);
	
	function execute(
		address lp,
		bytes calldata actionsData,
		bytes calldata permitsData
	) external payable;
}
