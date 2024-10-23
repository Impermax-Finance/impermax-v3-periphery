pragma solidity =0.5.16;

import "../../contracts/interfaces/IERC20.sol";

contract Recipient {

	function empty(address token, address to) public {
		uint balance = IERC20(token).balanceOf(address(this));
		IERC20(token).transfer(to, balance);
	}
	
}