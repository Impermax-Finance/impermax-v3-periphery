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
	
	function execute(
		address nftlp,
		uint _tokenId,
		bytes calldata actionsData,
		bytes calldata permitsData,
		bool withCollateralTransfer
	) external payable;
}
