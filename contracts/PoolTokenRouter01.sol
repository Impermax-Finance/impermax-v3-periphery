pragma solidity =0.5.16;
pragma experimental ABIEncoderV2;

import "./interfaces/IERC20.sol";
import "./interfaces/IWETH.sol";
import "./libraries/SafeMath.sol";
import "./libraries/TransferHelper.sol";
import "./libraries/ImpermaxPermit.sol";
import "./impermax-v3-core/interfaces/IPoolToken.sol";
import "./impermax-v3-core/interfaces/IBorrowable.sol";

contract PoolTokenRouter01 {
	using SafeMath for uint;

	address public WETH;

	modifier checkETH(address poolToken) {
		require(WETH == IPoolToken(poolToken).underlying(), "ImpermaxRouter: NOT_WETH");
		_;
	}
	
	modifier permit(bytes memory permitsData) {
		ImpermaxPermit.executePermits(permitsData);
		_;
	}
	
	constructor(address _WETH) public {
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
		else ImpermaxPermit.safeTransferFrom(token, from, poolToken, amount);
		tokens = IPoolToken(poolToken).mint(to);
	}
	function mint(
		address poolToken, 
		uint amount,
		address to,
		bytes calldata permitsData
	) external permit(permitsData) returns (uint tokens) {
		return _mint(poolToken, IPoolToken(poolToken).underlying(), amount, msg.sender, to);
	}
	function mintETH(
		address poolToken, 
		address to
	) external payable checkETH(poolToken) returns (uint tokens) {
		IWETH(WETH).deposit.value(msg.value)();
		return _mint(poolToken, WETH, msg.value, address(this), to);
	}
	
	/*** Redeem ***/
	
	function redeem(
		address poolToken,
		uint tokens,
		address to,
		bytes memory permitsData
	) public permit(permitsData) returns (uint amount) {
		uint tokensBalance = IERC20(poolToken).balanceOf(msg.sender);
		tokens = tokens < tokensBalance ? tokens : tokensBalance;
		IPoolToken(poolToken).transferFrom(msg.sender, poolToken, tokens);
		return IPoolToken(poolToken).redeem(to);
	}
	function redeemETH(
		address poolToken, 
		uint tokens,
		address to,
		bytes memory permitsData
	) public checkETH(poolToken) permit(permitsData) returns (uint amountETH) {
		uint tokensBalance = IERC20(poolToken).balanceOf(msg.sender);
		tokens = tokens < tokensBalance ? tokens : tokensBalance;
		IPoolToken(poolToken).transferFrom(msg.sender, poolToken, tokens);
		amountETH = IPoolToken(poolToken).redeem(address(this));
		IWETH(WETH).withdraw(amountETH);
		TransferHelper.safeTransferETH(to, amountETH);
	}
}
