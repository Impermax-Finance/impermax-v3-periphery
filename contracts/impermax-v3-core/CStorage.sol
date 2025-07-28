pragma solidity =0.5.16;

contract CStorage {
	address public underlying;
	address public factory;
	address public borrowable0;
	address public borrowable1;
	uint public safetyMarginSqrt = 1.58113884e18; //safetyMargin: 250%
	uint public liquidationIncentive = 1.05e18; //105%
	uint public liquidationFee = 0.08e18; //8%
	mapping(uint => uint) public blockOfLastRestructureOrLiquidation;	
	
	function liquidationPenalty() public view returns (uint) {
		return liquidationIncentive + liquidationFee;
	}
}