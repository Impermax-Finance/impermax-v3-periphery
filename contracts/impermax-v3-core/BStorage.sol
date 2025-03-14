pragma solidity =0.5.16;

contract BStorage {

	address public collateral;

	mapping (address => mapping (address => uint256)) public borrowAllowance;
	
	struct BorrowSnapshot {
		uint112 principal;		// amount in underlying when the borrow was last updated
		uint112 interestIndex;	// borrow index when borrow was last updated
	}
	mapping(uint256 => BorrowSnapshot) internal borrowBalances;	

	// use one memory slot
	uint112 public borrowIndex = 1e18;
	uint112 public totalBorrows;
	uint32 public accrualTimestamp = uint32(block.timestamp % 2**32);	

	uint public exchangeRateLast;
		
	// use one memory slot
	uint48 public borrowRate;
	uint48 public kinkBorrowRate = 6.3419584e9; //20% per year
	uint32 public rateUpdateTimestamp = uint32(block.timestamp % 2**32);

	uint public reserveFactor = 0.10e18; //10%
	uint public kinkUtilizationRate = 0.75e18; //75%
	uint public adjustSpeed = 5.787037e12; //50% per day
	uint public debtCeiling = uint(-1);

    function safe112(uint n) internal pure returns (uint112) {
        require(n < 2**112, "Impermax: SAFE112");
        return uint112(n);
    }
}