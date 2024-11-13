pragma solidity =0.5.16;
pragma experimental ABIEncoderV2;

import "./interfaces/IERC20.sol";
import "./interfaces/IWETH.sol";
import "./libraries/SafeMath.sol";
import "./libraries/TransferHelper.sol";
import "./impermax-v3-core/interfaces/IPoolToken.sol";
import "./impermax-v3-core/interfaces/IBorrowable.sol";

contract ImpermaxV3LendRouter01 {
	using SafeMath for uint;

	address public factory;
	address public WETH;

	modifier ensure(uint deadline) {
		require(deadline >= block.timestamp, "ImpermaxRouter: EXPIRED");
		_;
	}

	modifier checkETH(address poolToken) {
		require(WETH == IPoolToken(poolToken).underlying(), "ImpermaxRouter: NOT_WETH");
		_;
	}
	
	constructor(address _factory, address _WETH) public {
		factory = _factory;
		WETH = _WETH;
	}

	function () external payable {
		assert(msg.sender == WETH); // only accept ETH via fallback from the WETH contract
	}

	/*** Mint ***/
	
	function _mint(
		address poolToken, 
		address token, 
		uint amount,
		address from,
		address to
	) internal returns (uint tokens) {
		if (from == address(this)) TransferHelper.safeTransfer(token, poolToken, amount);
		else TransferHelper.safeTransferFrom(token, from, poolToken, amount);
		tokens = IPoolToken(poolToken).mint(to);
	}
	function mint(
		address poolToken, 
		uint amount,
		address to,
		uint deadline
	) external ensure(deadline) returns (uint tokens) {
		return _mint(poolToken, IPoolToken(poolToken).underlying(), amount, msg.sender, to);
	}
	function mintETH(
		address poolToken, 
		address to,
		uint deadline
	) external payable ensure(deadline) checkETH(poolToken) returns (uint tokens) {
		IWETH(WETH).deposit.value(msg.value)();
		return _mint(poolToken, WETH, msg.value, address(this), to);
	}
	
	/*** Redeem ***/
	
	function redeem(
		address poolToken,
		uint tokens,
		address to,
		uint deadline,
		bytes memory permitData
	) public ensure(deadline) returns (uint amount) {
		_permit(poolToken, tokens, deadline, permitData);
		uint tokensBalance = IERC20(poolToken).balanceOf(msg.sender);
		tokens = tokens < tokensBalance ? tokens : tokensBalance;
		IPoolToken(poolToken).transferFrom(msg.sender, poolToken, tokens);
		return IPoolToken(poolToken).redeem(to);
	}
	function redeemETH(
		address poolToken, 
		uint tokens,
		address to,
		uint deadline,
		bytes memory permitData
	) public ensure(deadline) checkETH(poolToken) returns (uint amountETH) {
		_permit(poolToken, tokens, deadline, permitData);
		uint tokensBalance = IERC20(poolToken).balanceOf(msg.sender);
		tokens = tokens < tokensBalance ? tokens : tokensBalance;
		IPoolToken(poolToken).transferFrom(msg.sender, poolToken, tokens);
		amountETH = IPoolToken(poolToken).redeem(address(this));
		IWETH(WETH).withdraw(amountETH);
		TransferHelper.safeTransferETH(to, amountETH);
	}

	/*** Liquidate ***/
	
	function _repayAmount(
		address borrowable,
		uint tokenId, 
		uint amountMax
	) internal returns (uint amount) {
		IBorrowable(borrowable).accrueInterest();
		uint borrowedAmount = IBorrowable(borrowable).borrowBalance(tokenId);
		amount = amountMax < borrowedAmount ? amountMax : borrowedAmount;
	}
	function liquidate(
		address borrowable, 
		uint tokenId,
		uint amountMax,
		address to,
		uint deadline
	) external ensure(deadline) returns (uint amount, uint seizeTokenId) {
		// TODO liquidate position underwater
		amount = _repayAmount(borrowable, tokenId, amountMax);
		TransferHelper.safeTransferFrom(IBorrowable(borrowable).underlying(), msg.sender, borrowable, amount);
		seizeTokenId = IBorrowable(borrowable).liquidate(tokenId, amount, to, "0x");
	}
	function liquidateETH(
		address borrowable, 
		uint tokenId,
		address to,
		uint deadline
	) external payable ensure(deadline) checkETH(borrowable) returns (uint amountETH, uint seizeTokenId) {
		amountETH = _repayAmount(borrowable, tokenId, msg.value);
		IWETH(WETH).deposit.value(amountETH)();
		assert(IWETH(WETH).transfer(borrowable, amountETH));
		seizeTokenId = IBorrowable(borrowable).liquidate(tokenId, amountETH, to, "0x");
		// refund surpluss eth, if any
		if (msg.value > amountETH) TransferHelper.safeTransferETH(msg.sender, msg.value - amountETH);
	}
		
	/*** Utilities ***/
	
	function _permit(
		address poolToken, 
		uint amount, 
		uint deadline,
		bytes memory permitData
	) internal {
		if (permitData.length == 0) return;
		(bool approveMax, uint8 v, bytes32 r, bytes32 s) = abi.decode(permitData, (bool, uint8, bytes32, bytes32));
		uint value = approveMax ? uint(-1) : amount;
		IPoolToken(poolToken).permit(msg.sender, address(this), value, deadline, v, r, s);
	}
}
