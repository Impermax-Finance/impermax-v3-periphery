pragma solidity =0.5.16;
pragma experimental ABIEncoderV2;

import "./CSetter.sol";
import "./interfaces/IBorrowable.sol";
import "./interfaces/ICollateral.sol";
import "./interfaces/IImpermaxCallee.sol";
import "./interfaces/IFactory.sol";
import "./interfaces/INFTLP.sol";
import "./libraries/CollateralMath.sol";

contract ImpermaxV3Collateral is ICollateral, CSetter {	
	using CollateralMath for CollateralMath.PositionObject;

    uint256 internal constant Q192 = 2**192;

	constructor() public {}
	
	/*** Collateralization Model ***/
	
	function _getPositionObjectAmounts(uint tokenId, uint debtX, uint debtY) internal returns (CollateralMath.PositionObject memory positionObject) {
		if (debtX == uint(-1)) debtX = IBorrowable(borrowable0).borrowBalance(tokenId);
		if (debtY == uint(-1)) debtY = IBorrowable(borrowable1).borrowBalance(tokenId);
		
		(uint priceSqrtX96, INFTLP.RealXYs memory realXYs) = 
			INFTLP(underlying).getPositionData(tokenId, safetyMarginSqrt);
		require(priceSqrtX96 > 100 && priceSqrtX96 < Q192 / 100, "ImpermaxV3Collateral: PRICE_CALCULATION_ERROR");
		
		positionObject = CollateralMath.newPosition(realXYs, priceSqrtX96, debtX, debtY, liquidationPenalty(), safetyMarginSqrt);
	}
	
	function _getPositionObject(uint tokenId) internal returns (CollateralMath.PositionObject memory positionObject) {
		return _getPositionObjectAmounts(tokenId, uint(-1), uint(-1));
	}
	
	/*** ERC721 Wrapper ***/
	
	function mint(address to, uint256 tokenId) external nonReentrant {
		require(ownerOf[tokenId] == address(0), "ImpermaxV3Collateral: NFT_ALREADY_MINTED");
		require(INFTLP(underlying).ownerOf(tokenId) == address(this), "ImpermaxV3Collateral: NFT_NOT_RECEIVED");
		_mint(to, tokenId);
		emit Mint(to, tokenId);
	}

	function redeem(address to, uint256 tokenId, uint256 percentage, bytes memory data) public nonReentrant returns (uint256 redeemTokenId) {
		require(percentage <= 1e18, "ImpermaxV3Collateral: PERCENTAGE_ABOVE_100");
		_checkAuthorized(ownerOf[tokenId], msg.sender, tokenId);
		_approve(address(0), tokenId, address(0)); // reset approval
				
		// optimistically redeem
		if (percentage == 1e18) {
			redeemTokenId = tokenId;
			_burn(tokenId);
			INFTLP(underlying).safeTransferFrom(address(this), to, redeemTokenId);
			if (data.length > 0) IImpermaxCallee(to).impermaxRedeem(msg.sender, tokenId, redeemTokenId, data);
			
			// finally check that the position is not left underwater
			require(IBorrowable(borrowable0).borrowBalance(tokenId) == 0, "ImpermaxV3Collateral: INSUFFICIENT_LIQUIDITY");
			require(IBorrowable(borrowable1).borrowBalance(tokenId) == 0, "ImpermaxV3Collateral: INSUFFICIENT_LIQUIDITY");
		} else {
			redeemTokenId = INFTLP(underlying).split(tokenId, percentage);
			INFTLP(underlying).safeTransferFrom(address(this), to, redeemTokenId);
			if (data.length > 0) IImpermaxCallee(to).impermaxRedeem(msg.sender, tokenId, redeemTokenId, data);
			
			// finally check that the position is not left underwater
			require(!isLiquidatable(tokenId), "ImpermaxV3Collateral: INSUFFICIENT_LIQUIDITY");
		}
		
		emit Redeem(to, tokenId, percentage, redeemTokenId);
	}
	function redeem(address to, uint256 tokenId, uint256 percentage) external returns (uint256 redeemTokenId) {
		return redeem(to, tokenId, percentage, "");
	}
	
	/*** Collateral ***/
	
	function isLiquidatable(uint tokenId) public returns (bool) {
		CollateralMath.PositionObject memory positionObject = _getPositionObject(tokenId);
		return positionObject.isLiquidatable();
	}
	
	function isUnderwater(uint tokenId) public returns (bool) {
		CollateralMath.PositionObject memory positionObject = _getPositionObject(tokenId);
		return positionObject.isUnderwater();
	}
	
	function canBorrow(uint tokenId, address borrowable, uint accountBorrows) public returns (bool) {
		address _borrowable0 = borrowable0;
		address _borrowable1 = borrowable1;
		require(borrowable == _borrowable0 || borrowable == _borrowable1, "ImpermaxV3Collateral: INVALID_BORROWABLE");
		
		uint debtX = borrowable == _borrowable0 ? accountBorrows : uint(-1);
		uint debtY = borrowable == _borrowable1 ? accountBorrows : uint(-1);
		
		CollateralMath.PositionObject memory positionObject = _getPositionObjectAmounts(tokenId, debtX, debtY);
		return !positionObject.isLiquidatable();
	}
	
	function restructureBadDebt(uint tokenId) external nonReentrant {
		CollateralMath.PositionObject memory positionObject = _getPositionObject(tokenId);
		uint postLiquidationCollateralRatio = positionObject.getPostLiquidationCollateralRatio();
		require(postLiquidationCollateralRatio < 1e18, "ImpermaxV3Collateral: NOT_UNDERWATER");
		IBorrowable(borrowable0).restructureDebt(tokenId, postLiquidationCollateralRatio);
		IBorrowable(borrowable1).restructureDebt(tokenId, postLiquidationCollateralRatio);
		positionObject = _getPositionObject(tokenId);
		assert(!positionObject.isUnderwater());
		
		emit RestructureBadDebt(tokenId, postLiquidationCollateralRatio);
	}
	
	// this function must be called from borrowable0 or borrowable1
	function seize(uint tokenId, uint repayAmount, address liquidator, bytes calldata data) external nonReentrant returns (uint seizeTokenId) {
		require(msg.sender == borrowable0 || msg.sender == borrowable1, "ImpermaxV3Collateral: UNAUTHORIZED");
		
		uint repayToCollateralRatio;
		{
			CollateralMath.PositionObject memory positionObject = _getPositionObject(tokenId);
			
			require(positionObject.isLiquidatable(), "ImpermaxV3Collateral: INSUFFICIENT_SHORTFALL");
			require(!positionObject.isUnderwater(), "ImpermaxV3Collateral: CANNOT_LIQUIDATE_UNDERWATER_POSITION");
			
			uint collateralValue = positionObject.getCollateralValue(CollateralMath.Price.CURRENT);
			uint repayValue = msg.sender == borrowable0
				? positionObject.getValue(CollateralMath.Price.CURRENT, repayAmount, 0)
				: positionObject.getValue(CollateralMath.Price.CURRENT, 0, repayAmount);
			
			repayToCollateralRatio = repayValue.mul(1e18).div(collateralValue);
			require(repayToCollateralRatio.mul(liquidationPenalty()) <= 1e36, "ImpermaxV3Collateral: UNEXPECTED_RATIO");
		}
		
		uint seizePercentage = repayToCollateralRatio.mul(liquidationIncentive).div(1e18);
		uint feePercentage = repayToCollateralRatio.mul(liquidationFee).div(uint(1e18).sub(seizePercentage));	
		
		seizeTokenId = INFTLP(underlying).split(tokenId, seizePercentage);

		address reservesManager = IFactory(factory).reservesManager();		
		if (feePercentage > 0 && reservesManager != address(0)) {
			uint feeTokenId = INFTLP(underlying).split(tokenId, feePercentage);		
			_mint(reservesManager, feeTokenId);
			emit Seize(reservesManager, tokenId, feePercentage, feeTokenId);
		}
		
		INFTLP(underlying).safeTransferFrom(address(this), liquidator, seizeTokenId, data);
		emit Seize(liquidator, tokenId, seizePercentage, seizeTokenId);
	}
}