pragma solidity =0.5.16;

import "./PoolToken.sol";
import "./BAllowance.sol";
import "./BInterestRateModel.sol";
import "./BSetter.sol";
import "./BStorage.sol";
import "./interfaces/IBorrowable.sol";
import "./interfaces/ICollateral.sol";
import "./interfaces/IImpermaxCallee.sol";
import "./interfaces/IERC20.sol";
import "./interfaces/IERC721.sol";
import "./interfaces/IFactory.sol";
import "./interfaces/IBorrowTracker.sol";
import "./libraries/Math.sol";

contract ImpermaxV3Borrowable is IBorrowable, PoolToken, BStorage, BSetter, BInterestRateModel, BAllowance {
		
	constructor() public {}

	/*** PoolToken ***/
	
	function _update() internal {
		super._update();
		_calculateBorrowRate();
	}
	
	function _mintReserves(uint _exchangeRate, uint _totalSupply) internal returns (uint) {
		uint _exchangeRateLast = exchangeRateLast;
		if (_exchangeRate > _exchangeRateLast) {
			uint _exchangeRateNew = _exchangeRate.sub( _exchangeRate.sub(_exchangeRateLast).mul(reserveFactor).div(1e18) );
			uint liquidity = _totalSupply.mul(_exchangeRate).div(_exchangeRateNew).sub(_totalSupply);
			if (liquidity > 0) {
				address reservesManager = IFactory(factory).reservesManager();
				_mint(reservesManager, liquidity);
			}
			exchangeRateLast = _exchangeRateNew;
			return _exchangeRateNew;
		}
		else return _exchangeRate;
	}
	
	function exchangeRate() public accrue returns (uint) {
		uint _totalSupply = totalSupply;
		uint _actualBalance = totalBalance.add(totalBorrows);
		if (_totalSupply == 0 || _actualBalance == 0) return initialExchangeRate;
		uint _exchangeRate = _actualBalance.mul(1e18).div(_totalSupply);
		return _mintReserves(_exchangeRate, _totalSupply);
	}
	
	// force totalBalance to match real balance
	function sync() external nonReentrant update accrue {}
	
	/*** Borrowable ***/
	
	// this is the stored borrow balance; the current borrow balance may be slightly higher
	function borrowBalance(uint256 tokenId) public view returns (uint) {
		BorrowSnapshot memory borrowSnapshot = borrowBalances[tokenId];
		if (borrowSnapshot.interestIndex == 0) return 0; // not initialized
		return uint(borrowSnapshot.principal).mul(borrowIndex).div(borrowSnapshot.interestIndex);
	}
	
	function _trackBorrow(uint256 tokenId, uint accountBorrows, uint _borrowIndex) internal {
		address _borrowTracker = borrowTracker;
		if (_borrowTracker == address(0)) return;
		IBorrowTracker(_borrowTracker).trackBorrow(tokenId, accountBorrows, _borrowIndex);
	}
	
	function _updateBorrow(uint256 tokenId, uint borrowAmount, uint repayAmount) private returns (uint accountBorrowsPrior, uint accountBorrows, uint _totalBorrows) {
		accountBorrowsPrior = borrowBalance(tokenId);
		if (borrowAmount == repayAmount) return (accountBorrowsPrior, accountBorrowsPrior, totalBorrows);
		uint112 _borrowIndex = borrowIndex;
		if (borrowAmount > repayAmount) {
			BorrowSnapshot storage borrowSnapshot = borrowBalances[tokenId];
			uint increaseAmount = borrowAmount - repayAmount;
			accountBorrows = accountBorrowsPrior.add(increaseAmount);
			borrowSnapshot.principal = safe112(accountBorrows);
			borrowSnapshot.interestIndex = _borrowIndex;
			_totalBorrows = uint(totalBorrows).add(increaseAmount);	
			totalBorrows = safe112(_totalBorrows);
		}
		else {
			BorrowSnapshot storage borrowSnapshot = borrowBalances[tokenId];
			uint decreaseAmount = repayAmount - borrowAmount;		
			accountBorrows = accountBorrowsPrior > decreaseAmount ? accountBorrowsPrior - decreaseAmount : 0;
			borrowSnapshot.principal = safe112(accountBorrows);
			if(accountBorrows == 0) {
				borrowSnapshot.interestIndex = 0;
			} else {
				borrowSnapshot.interestIndex = _borrowIndex;
			}
			uint actualDecreaseAmount = accountBorrowsPrior.sub(accountBorrows);
			_totalBorrows = totalBorrows; // gas savings
			_totalBorrows = _totalBorrows > actualDecreaseAmount ? _totalBorrows - actualDecreaseAmount : 0;
			totalBorrows = safe112(_totalBorrows);			
		}
		_trackBorrow(tokenId, accountBorrows, _borrowIndex);
	}
	
	// this low-level function should be called from another contract
	function borrow(uint256 tokenId, address receiver, uint borrowAmount, bytes calldata data) external nonReentrant update accrue {
		uint _totalBalance = totalBalance;
		require(borrowAmount <= _totalBalance, "ImpermaxV3Borrowable: INSUFFICIENT_CASH");
		
		address borrower = IERC721(collateral).ownerOf(tokenId);
		_checkBorrowAllowance(borrower, msg.sender, borrowAmount);
		
		// optimistically transfer funds
		if (borrowAmount > 0) _safeTransfer(receiver, borrowAmount);
		if (data.length > 0) IImpermaxCallee(receiver).impermaxBorrow(msg.sender, tokenId, borrowAmount, data);
		uint balance = IERC20(underlying).balanceOf(address(this));
		
		uint repayAmount = balance.add(borrowAmount).sub(_totalBalance);
		(uint accountBorrowsPrior, uint accountBorrows, uint _totalBorrows) = _updateBorrow(tokenId, borrowAmount, repayAmount);
		
		if(borrowAmount > repayAmount) require(
			ICollateral(collateral).canBorrow(tokenId, address(this), accountBorrows),
			"ImpermaxV3Borrowable: INSUFFICIENT_LIQUIDITY"
		);
		
		emit Borrow(msg.sender, tokenId, receiver, borrowAmount, repayAmount, accountBorrowsPrior, accountBorrows, _totalBorrows);
	}

	// this low-level function should be called from another contract
	function liquidate(uint256 tokenId, uint repayAmount, address liquidator, bytes calldata data) external nonReentrant update accrue returns (uint seizeTokenId) {
		repayAmount = repayAmount < borrowBalance(tokenId) ? repayAmount : borrowBalance(tokenId);
		seizeTokenId = ICollateral(collateral).seize(tokenId, repayAmount, liquidator, data);
		
		uint balance = IERC20(underlying).balanceOf(address(this));
		require(balance.sub(totalBalance) >= repayAmount, "ImpermaxV3Borrowable: INSUFFICIENT_ACTUAL_REPAY");
		
		(uint accountBorrowsPrior, uint accountBorrows, uint _totalBorrows) = _updateBorrow(tokenId, 0, repayAmount);
		
		emit Liquidate(msg.sender, tokenId, liquidator, seizeTokenId, repayAmount, accountBorrowsPrior, accountBorrows, _totalBorrows);
	}
	
	// this function must be called from collateral
	function restructureDebt(uint tokenId, uint reduceToRatio) public nonReentrant update accrue {
		require(msg.sender == collateral, "ImpermaxV3Borrowable: UNAUTHORIZED");
		require(reduceToRatio < 1e18, "ImpermaxV3Borrowable: NOT_UNDERWATER");
	
		uint currentBorrowBalance = borrowBalance(tokenId);
		uint repayAmount = currentBorrowBalance.sub(currentBorrowBalance.mul(reduceToRatio).div(1e18));
		(uint accountBorrowsPrior, uint accountBorrows, uint _totalBorrows) = _updateBorrow(tokenId, 0, repayAmount);
		
		emit RestructureDebt(tokenId, reduceToRatio, repayAmount, accountBorrowsPrior, accountBorrows, _totalBorrows);
	}
		
	function trackBorrow(uint256 tokenId) external {
		_trackBorrow(tokenId, borrowBalance(tokenId), borrowIndex);
	}
	
	modifier accrue() {
		accrueInterest();
		_;
	}
}