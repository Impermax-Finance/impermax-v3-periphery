pragma solidity =0.5.16;

contract CStorage {
	address public underlying;
	address public factory;
	address public borrowable0;
	address public borrowable1;
	uint public safetyMarginSqrt = 1.58113883e18; //safetyMargin: 250%
	uint public liquidationIncentive = 1.02e18; //2%
	uint public liquidationFee = 0.02e18; //2%
	mapping(uint => uint) public blockOfLastRestructureOrLiquidation;	
	
	function liquidationPenalty() public view returns (uint) {
		return liquidationIncentive + liquidationFee;
	}
}