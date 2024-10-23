pragma solidity =0.5.16;
pragma experimental ABIEncoderV2;

import "./interfaces/IERC20.sol";
import "./interfaces/IERC721.sol";
import "./interfaces/IWETH.sol";
import "./interfaces/IUniswapV2Pair.sol";
import "./interfaces/IRouter01V3.sol";
import "./libraries/Math.sol";
import "./libraries/SafeMath.sol";
import "./libraries/TransferHelper.sol";
import "./libraries/UniswapV2Library.sol";
import "./impermax-v3-core/interfaces/IPoolToken.sol";
import "./impermax-v3-core/interfaces/IBorrowable.sol";
import "./impermax-v3-core/interfaces/IFactory.sol";
import "./impermax-v3-core/interfaces/ICollateral.sol";
import "./impermax-v3-core/interfaces/IImpermaxCallee.sol";
import "./impermax-v3-core/interfaces/INFTLP.sol";
import "./impermax-v3-core/extensions/interfaces/ITokenizedUniswapV2Position.sol";


contract Router01V3_0 /*is IImpermaxCallee*/ {
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
	
	function _checkOwnerNftlp(address nftlp, uint256 tokenId) internal {
		address collateral = getCollateral(nftlp);
		require(IERC721(collateral).ownerOf(tokenId) == msg.sender, "ImpermaxRouter: UNAUTHORIZED");
	}
	modifier checkOwnerNftlp(address nftlp, uint256 tokenId) {
		_checkOwnerNftlp(nftlp, tokenId);
		_;
	}

	modifier checkOwner(uint256 tokenId, address collateral, address borrowable) {
		if (collateral == address(0)) {
			collateral = IBorrowable(borrowable).collateral();
		}
		require(IERC721(collateral).ownerOf(tokenId) == msg.sender, "ImpermaxRouter: UNAUTHORIZED");
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
	
	/*** Mint/Redeem Collateral ***/
	
	function mintNewCollateral(
		address nftlp, 
		uint amount,
		address to,
		uint deadline,
		bytes calldata permitData
	) external ensure(deadline) returns (uint tokenId) {
		address collateral = getCollateral(nftlp);
		address uniswapV2Pair = getUniswapV2Pair(nftlp);
		_permit(uniswapV2Pair, amount, deadline, permitData);
		TransferHelper.safeTransferFrom(uniswapV2Pair, msg.sender, nftlp, amount);
		tokenId = ITokenizedUniswapV2Position(nftlp).mint(collateral);
		ICollateral(collateral).mint(to, tokenId);
	}
	function mintCollateral(
		address nftlp, 
		uint tokenId,
		uint amount,
		uint deadline,
		bytes calldata permitData
	) external ensure(deadline) {
		address collateral = getCollateral(nftlp);
		address uniswapV2Pair = getUniswapV2Pair(nftlp);
		_permit(uniswapV2Pair, amount, deadline, permitData);
		TransferHelper.safeTransferFrom(uniswapV2Pair, msg.sender, nftlp, amount);
		uint tokenToJoin = ITokenizedUniswapV2Position(nftlp).mint(address(this));
		ITokenizedUniswapV2Position(nftlp).join(tokenId, tokenToJoin);
	}
	function redeemCollateral(
		address nftlp, 
		uint tokenId,
		uint percentage,
		address to,
		uint deadline,
		bytes calldata permitData
	) external ensure(deadline) checkOwnerNftlp(nftlp, tokenId) returns (uint amount) {
		address collateral = getCollateral(nftlp);
		_nftPermit(collateral, tokenId, deadline, permitData);
		uint newTokenId = ICollateral(collateral).redeem(address(this), tokenId, percentage);
		return ITokenizedUniswapV2Position(nftlp).redeem(to, newTokenId);
	}

	/*** Borrow ***/

	function borrow(
		address borrowable, 
		uint tokenId,
		uint amount,
		address to,
		uint deadline,
		bytes memory permitData
	) public ensure(deadline) checkOwner(tokenId, address(0), borrowable) {
		_borrowPermit(borrowable, amount, deadline, permitData);
		IBorrowable(borrowable).borrow(tokenId, to, amount, new bytes(0));
	}
	function borrowETH(
		address borrowable, 
		uint tokenId,
		uint amountETH,
		address to,
		uint deadline,
		bytes memory permitData
	) public ensure(deadline) checkETH(borrowable) {
		borrow(borrowable, tokenId, amountETH, address(this), deadline, permitData);
		IWETH(WETH).withdraw(amountETH);
		TransferHelper.safeTransferETH(to, amountETH);
	}
	
	/*** Repay ***/
	
	function _repayAmount(
		address borrowable,
		uint tokenId, 
		uint amountMax
	) internal returns (uint amount) {
		IBorrowable(borrowable).accrueInterest();
		uint borrowedAmount = IBorrowable(borrowable).borrowBalance(tokenId);
		amount = amountMax < borrowedAmount ? amountMax : borrowedAmount;
	}
	function repay(
		address borrowable, 
		uint tokenId,
		uint amountMax,
		uint deadline
	) external ensure(deadline) returns (uint amount) {
		amount = _repayAmount(borrowable, tokenId, amountMax);
		TransferHelper.safeTransferFrom(IBorrowable(borrowable).underlying(), msg.sender, borrowable, amount);
		IBorrowable(borrowable).borrow(tokenId, address(0), 0, new bytes(0));
	}
	function repayETH(
		address borrowable, 
		uint tokenId,
		uint deadline
	) external payable ensure(deadline) checkETH(borrowable) returns (uint amountETH) {
		amountETH = _repayAmount(borrowable, tokenId, msg.value);
		IWETH(WETH).deposit.value(amountETH)();
		assert(IWETH(WETH).transfer(borrowable, amountETH));
		IBorrowable(borrowable).borrow(tokenId, address(0), 0, new bytes(0));
		// refund surpluss eth, if any
		if (msg.value > amountETH) TransferHelper.safeTransferETH(msg.sender, msg.value - amountETH);
	}
	
	/*** Liquidate ***/

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
		
	/*** Leverage LP Token ***/
	
	function _leverage(
		address nftlp,
		uint tokenId, 
		uint amount0,
		uint amount1
	) internal {
		address borrowableA = getBorrowable(nftlp, 0);
		// mint collateral
		bytes memory borrowBData = abi.encode(CalleeData({
			callType: CallType.ADD_LIQUIDITY_AND_MINT,
			nftlp: nftlp,
			borrowableIndex: 1,
			data: abi.encode(AddLiquidityAndMintCalldata({
				amount0: amount0,
				amount1: amount1
			}))
		}));	
		// borrow borrowableB
		bytes memory borrowAData = abi.encode(CalleeData({
			callType: CallType.BORROWB,
			nftlp: nftlp,
			borrowableIndex: 0,
			data: abi.encode(BorrowBCalldata({
				receiver: address(this),
				borrowAmount: amount1,
				data: borrowBData
			}))
		}));
		// borrow borrowableA
		IBorrowable(borrowableA).borrow(tokenId, address(this), amount0, borrowAData);	
	}
	function leverage(
		address nftlp,
		uint tokenId,
		uint amount0Desired,
		uint amount1Desired,
		uint amount0Min,
		uint amount1Min,
		uint deadline//,
		//bytes calldata permitDataA,
		//bytes calldata permitDataB
	) external ensure(deadline) {
		// TODO why the modifier is obstructing the stack here?
		_checkOwnerNftlp(nftlp, tokenId);
		//_borrowPermit(getBorrowable(nftlp, 0), amount0Desired, deadline, permitDataA);
		//_borrowPermit(getBorrowable(nftlp, 1), amount1Desired, deadline, permitDataB);
		address uniswapV2Pair = getUniswapV2Pair(nftlp);
		(uint amount0, uint amount1) = _optimalLiquidity(uniswapV2Pair, amount0Desired, amount1Desired, amount0Min, amount1Min);
		_leverage(nftlp, tokenId, amount0, amount1);
	}

	function _addLiquidityAndMint(
		address nftlp, 
		uint tokenId,
		uint amount0,
		uint amount1
	) internal {
		(address collateral, address borrowableA, address borrowableB) = getLendingPool(nftlp);
		address uniswapV2Pair = getUniswapV2Pair(nftlp);
		// add liquidity to uniswap pair
		TransferHelper.safeTransfer(IBorrowable(borrowableA).underlying(), uniswapV2Pair, amount0);
		TransferHelper.safeTransfer(IBorrowable(borrowableB).underlying(), uniswapV2Pair, amount1);
		// mint LP token
		IUniswapV2Pair(uniswapV2Pair).mint(nftlp);
		uint newTokenId = ITokenizedUniswapV2Position(nftlp).mint(address(this));
		ITokenizedUniswapV2Position(nftlp).join(tokenId, newTokenId);
	}
		
	/*** Deleverage LP Token ***/
	
	function deleverage(
		address nftlp,
		uint tokenId,
		uint percentage,
		uint amount0Min,
		uint amount1Min,
		uint deadline,
		bytes calldata permitData
	) external ensure(deadline) {
		// TODO why the modifier is obstructing the stack here?
		_checkOwnerNftlp(nftlp, tokenId);
		address collateral = getCollateral(nftlp);
		_nftPermit(collateral, tokenId, deadline, permitData);
		require(percentage > 0, "ImpermaxRouter: REDEEM_ZERO");
		bytes memory redeemData = abi.encode(CalleeData({
			callType: CallType.REMOVE_LIQ_AND_REPAY,
			nftlp: nftlp,
			borrowableIndex: 0,
			data: abi.encode(RemoveLiqAndRepayCalldata({
				tokenId: tokenId,
				to: msg.sender,
				amount0Min: amount0Min,
				amount1Min: amount1Min
			}))
		}));
		ICollateral(collateral).redeem(address(this), tokenId, percentage, redeemData);
	}

	function _removeLiqAndRepay(
		address nftlp,
		uint tokenId,
		uint newTokenId,
		address to,
		uint amount0Min,
		uint amount1Min
	) internal {
		(address collateral, address borrowableA, address borrowableB) = getLendingPool(nftlp);
		address uniswapV2Pair = getUniswapV2Pair(nftlp);
		// removeLiquidity
		uint redeemAmount = ITokenizedUniswapV2Position(nftlp).redeem(address(this), newTokenId);
		IUniswapV2Pair(uniswapV2Pair).transfer(uniswapV2Pair, redeemAmount);
		(uint amount0Max, uint amount1Max) = IUniswapV2Pair(uniswapV2Pair).burn(address(this));
		require(amount0Max >= amount0Min, "ImpermaxRouter: INSUFFICIENT_0_AMOUNT");
		require(amount1Max >= amount1Min, "ImpermaxRouter: INSUFFICIENT_1_AMOUNT");
		// repay and refund
		_repayAndRefund(borrowableA, tokenId, to, amount0Max);
		_repayAndRefund(borrowableB, tokenId, to, amount1Max);
	}
	
	function _repayAndRefund(
		address borrowable,
		uint tokenId,
		address to,
		uint amountMax
	) internal {
		address token = IBorrowable(borrowable).underlying();
		//repay
		uint amount = _repayAmount(borrowable, tokenId, amountMax);
		TransferHelper.safeTransfer(token, borrowable, amount);
		IBorrowable(borrowable).borrow(tokenId, address(0), 0, new bytes(0));		
		// refund excess
		if (amountMax > amount) {
			uint refundAmount = amountMax - amount;
			if (token == WETH) {
				IWETH(WETH).withdraw(refundAmount);
				TransferHelper.safeTransferETH(to, refundAmount);
			}
			else TransferHelper.safeTransfer(token, to, refundAmount);
		}
	}
	
	/*** Impermax Callee ***/
		
	enum CallType {ADD_LIQUIDITY_AND_MINT, BORROWB, REMOVE_LIQ_AND_REPAY}
	struct CalleeData {
		CallType callType;
		address nftlp;
		uint8 borrowableIndex;
		bytes data;		
	}
	struct AddLiquidityAndMintCalldata {
		uint amount0;
		uint amount1;
	}
	struct BorrowBCalldata {
		address receiver;
		uint borrowAmount;
		bytes data;
	}
	struct RemoveLiqAndRepayCalldata {
		uint tokenId;
		address to;
		uint amount0Min;
		uint amount1Min;
	}
	
	function impermaxBorrow(address from, uint256 tokenId, uint borrowAmount, bytes calldata data) external {
		borrowAmount;
		CalleeData memory calleeData = abi.decode(data, (CalleeData));
		address declaredCaller = getBorrowable(calleeData.nftlp, calleeData.borrowableIndex);
		// only succeeds if called by a borrowable and if that borrowable has been called by the router
		require(from == address(this), "ImpermaxRouter: FROM_NOT_ROUTER");
		require(msg.sender == declaredCaller, "ImpermaxRouter: UNAUTHORIZED_CALLER");
		if (calleeData.callType == CallType.ADD_LIQUIDITY_AND_MINT) {
			AddLiquidityAndMintCalldata memory d = abi.decode(calleeData.data, (AddLiquidityAndMintCalldata));
			_addLiquidityAndMint(calleeData.nftlp, tokenId, d.amount0, d.amount1);
		}
		else if (calleeData.callType == CallType.BORROWB) {
			BorrowBCalldata memory d = abi.decode(calleeData.data, (BorrowBCalldata));
			address borrowableB = getBorrowable(calleeData.nftlp, 1);
			IBorrowable(borrowableB).borrow(tokenId, d.receiver, d.borrowAmount, d.data);
		}
		else revert("ImpermaxRouter: INVALID_CALLBACK");
	}
	
	function impermaxRedeem(address sender, uint256 tokenId, uint256 redeemTokenId, bytes calldata data) external {
		CalleeData memory calleeData = abi.decode(data, (CalleeData));
		
		// only succeeds if called by a collateral and if that collateral has been called by the router
		address declaredCaller = getCollateral(calleeData.nftlp);
		require(sender == address(this), "ImpermaxRouter: SENDER_NOT_ROUTER");
		require(msg.sender == declaredCaller, "ImpermaxRouter: UNAUTHORIZED_CALLER");
	
		if (calleeData.callType == CallType.REMOVE_LIQ_AND_REPAY) {
			RemoveLiqAndRepayCalldata memory d = abi.decode(calleeData.data, (RemoveLiqAndRepayCalldata));
			_removeLiqAndRepay(calleeData.nftlp, tokenId, redeemTokenId, d.to, d.amount0Min, d.amount1Min);
		}
		else revert("ImpermaxRouter: INVALID_CALLBACK");
	}
	
	function onERC721Received(address operator, address from, uint256 tokenId, bytes calldata data) external returns (bytes4 returnValue) {
		return bytes4(keccak256("onERC721Received(address,address,uint256,bytes)"));
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
	function _borrowPermit(
		address borrowable, 
		uint amount, 
		uint deadline,
		bytes memory permitData
	) internal {
		if (permitData.length == 0) return;
		(bool approveMax, uint8 v, bytes32 r, bytes32 s) = abi.decode(permitData, (bool, uint8, bytes32, bytes32));
		uint value = approveMax ? uint(-1) : amount;
		IBorrowable(borrowable).borrowPermit(msg.sender, address(this), value, deadline, v, r, s);
	}
	function _nftPermit(
		address erc721, 
		uint tokenId, 
		uint deadline,
		bytes memory permitData
	) internal {
		if (permitData.length == 0) return;
		// TOOD should I keep the bool to maintain the standard or should I remove it?
		(, uint8 v, bytes32 r, bytes32 s) = abi.decode(permitData, (bool, uint8, bytes32, bytes32));
		IERC721(erc721).permit(address(this), tokenId, deadline, v, r, s);
	}
	
	function _optimalLiquidity(
		address uniswapV2Pair,
		uint amount0Desired,
		uint amount1Desired,
		uint amount0Min,
		uint amount1Min
	) public view returns (uint amount0, uint amount1) {
		(uint reserveA, uint reserveB,) = IUniswapV2Pair(uniswapV2Pair).getReserves();
		uint amount1Optimal = UniswapV2Library.quote(amount0Desired, reserveA, reserveB);
		if (amount1Optimal <= amount1Desired) {
			require(amount1Optimal >= amount1Min, "ImpermaxRouter: INSUFFICIENT_1_AMOUNT");
			(amount0, amount1) = (amount0Desired, amount1Optimal);
		} else {
			uint amount0Optimal = UniswapV2Library.quote(amount1Desired, reserveB, reserveA);
			assert(amount0Optimal <= amount0Desired);
			require(amount0Optimal >= amount0Min, "ImpermaxRouter: INSUFFICIENT_0_AMOUNT");
			(amount0, amount1) = (amount0Optimal, amount1Desired);
		}
	}
	
	function getUniswapV2Pair(address nftlp) public view returns (address) {
		//try IStakedLPToken01(underlying).underlying() returns (address u) {
		//	if (u != address(0)) return u;
		//	return underlying;
		//} catch {
		return ITokenizedUniswapV2Position(nftlp).underlying();
		//}
	}
	
	// TODO setup cache for this!!?
	function getBorrowable(address nftlp, uint8 index) public view returns (address borrowable) {
		require(index < 2, "ImpermaxRouter: INDEX_TOO_HIGH");
		(,,,address borrowable0, address borrowable1) = IFactory(factory).getLendingPool(nftlp);
		return index == 0 ? borrowable0 : borrowable1;
	}
	function getCollateral(address nftlp) public view returns (address collateral) {
		(,,collateral,,) = IFactory(factory).getLendingPool(nftlp);
	}
	function getLendingPool(address nftlp) public view returns (address collateral, address borrowableA, address borrowableB) {
		collateral = getCollateral(nftlp);
		borrowableA = getBorrowable(nftlp, 0);
		borrowableB = getBorrowable(nftlp, 1);
	}
}
