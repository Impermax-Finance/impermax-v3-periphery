pragma solidity =0.5.16;
pragma experimental ABIEncoderV2;

import "../ImpermaxERC721.sol";
import "../interfaces/INFTLP.sol";
import "./interfaces/IUniswapV3Factory.sol";
import "./interfaces/IUniswapV3Pool.sol";
import "./interfaces/IV3Oracle.sol";
import "./interfaces/ITokenizedUniswapV3Position.sol";
import "./interfaces/ITokenizedUniswapV3Factory.sol";
import "./libraries/LiquidityAmounts.sol";
import "./libraries/UniswapV3Position.sol";
import "./libraries/TickMath.sol";

contract TokenizedUniswapV3Position is ITokenizedUniswapV3Position, INFTLP, ImpermaxERC721 {
	using TickMath for int24;
	
    uint constant Q128 = 2**128;
	
	address public factory;
	address public uniswapV3Factory;
	address public oracle;
	address public token0;
	address public token1;
	
	mapping(uint24 => 
		mapping(int24 => 
			mapping(int24 => uint256)
		)
	) public totalBalance;
	
	mapping(uint256 => Position) public positions;
	uint256 public positionsLength;
		
	/*** Global state ***/
	
	// called once by the factory at the time of deployment
	function _initialize (
		address _uniswapV3Factory, 
		address _oracle, 
		address _token0, 
		address _token1
	) external {
		require(factory == address(0), "Impermax: FACTORY_ALREADY_SET"); // sufficient check
		factory = msg.sender;
		_setName("Tokenized Uniswap V3", "NFT-UNI-V3");
		uniswapV3Factory = _uniswapV3Factory;
		oracle = _oracle;
		token0 = _token0;
		token1 = _token1;
		
		// quickly check if the oracle support this tokens pair
		oraclePriceSqrtX96();
	}
	
	function getPool(uint24 fee) public view returns (address pool) {
		pool = IUniswapV3Factory(uniswapV3Factory).getPool(token0, token1, fee);
		require(pool != address(0), "TokenizedUniswapV3Position: UNSUPPORTED_FEE");
	}
	
	function _updateBalance(uint24 fee, int24 tickLower, int24 tickUpper) internal {
		address pool = getPool(fee);
		bytes32 hash = UniswapV3Position.getHash(address(this), tickLower, tickUpper);
		(uint balance,,,,) = IUniswapV3Pool(pool).positions(hash);
		totalBalance[fee][tickLower][tickUpper] = balance;
	}
	
	function oraclePriceSqrtX96() public returns (uint256) {
		return IV3Oracle(oracle).oraclePriceSqrtX96(token0, token1);
	}
 
	/*** Position state ***/
	
	// this assumes that the position fee growth snapshot has already been updated through burn()
	function _getfeeCollectedAndGrowth(Position memory position, address pool) internal view returns (uint256 fg0, uint256 fg1, uint256 feeCollected0, uint256 feeCollected1) {
		bytes32 hash = UniswapV3Position.getHash(address(this), position.tickLower, position.tickUpper);
		(,fg0, fg1,,) = IUniswapV3Pool(pool).positions(hash);
		
		uint256 delta0 = fg0 - position.feeGrowthInside0LastX128;
		uint256 delta1 = fg1 - position.feeGrowthInside1LastX128;
		
		feeCollected0 = delta0.mul(position.liquidity).div(Q128).add(position.unclaimedFees0);
		feeCollected1 = delta1.mul(position.liquidity).div(Q128).add(position.unclaimedFees1);
	}
	function _getFeeCollected(Position memory position, address pool) internal view returns (uint256 feeCollected0, uint256 feeCollected1) {
		(,,feeCollected0, feeCollected1) = _getfeeCollectedAndGrowth(position, pool);
	}
	
	function getPositionData(uint256 tokenId, uint256 safetyMarginSqrt) external returns (
		uint256 priceSqrtX96,
		INFTLP.RealXYs memory realXYs
	) {
		Position memory position = positions[tokenId];
	
		require(safetyMarginSqrt >= 1e18, "TokenizedUniswapV3Position: INVALID_SAFETY_MARGIN");
		_requireOwned(tokenId);
		
		uint160 pa = position.tickLower.getSqrtRatioAtTick();
		uint160 pb = position.tickUpper.getSqrtRatioAtTick();
		
		priceSqrtX96 = oraclePriceSqrtX96();
		uint160 currentPrice = safe160(priceSqrtX96);
		uint160 lowestPrice = safe160(priceSqrtX96.mul(1e18).div(safetyMarginSqrt));
		uint160 highestPrice = safe160(priceSqrtX96.mul(safetyMarginSqrt).div(1e18));
		
		(realXYs.lowestPrice.realX, realXYs.lowestPrice.realY) = LiquidityAmounts.getAmountsForLiquidity(lowestPrice, pa, pb, position.liquidity);
		(realXYs.currentPrice.realX, realXYs.currentPrice.realY) = LiquidityAmounts.getAmountsForLiquidity(currentPrice, pa, pb, position.liquidity);
		(realXYs.highestPrice.realX, realXYs.highestPrice.realY) = LiquidityAmounts.getAmountsForLiquidity(highestPrice, pa, pb, position.liquidity);
	}
 
	/*** Interactions ***/
	
	// this low-level function should be called from another contract
	function mint(address to, uint24 fee, int24 tickLower, int24 tickUpper) external nonReentrant returns (uint256 newTokenId) {
		address pool = getPool(fee);		
		bytes32 hash = UniswapV3Position.getHash(address(this), tickLower, tickUpper);
		(uint balance, uint256 fg0, uint256 fg1,,) = IUniswapV3Pool(pool).positions(hash);
		uint liquidity = balance.sub(totalBalance[fee][tickLower][tickUpper]);
		
		newTokenId = positionsLength++;
		_mint(to, newTokenId);		
		positions[newTokenId] = Position({
			fee: fee,
			tickLower: tickLower,
			tickUpper: tickUpper,
			liquidity: safe128(liquidity),
			feeGrowthInside0LastX128: fg0,
			feeGrowthInside1LastX128: fg1,
			unclaimedFees0: 0,
			unclaimedFees1: 0
		});
		
		_updateBalance(fee, tickLower, tickUpper);
		
		emit MintPosition(newTokenId, fee, tickLower, tickUpper);
		emit UpdatePositionLiquidity(newTokenId, liquidity);
		emit UpdatePositionFeeGrowthInside(newTokenId, fg0, fg1);
		emit UpdatePositionUnclaimedFees(newTokenId, 0, 0);
	}

	// this low-level function should be called from another contract
	function redeem(address to, uint256 tokenId) external nonReentrant returns (uint256 amount0, uint256 amount1) {
		_checkAuthorized(_requireOwned(tokenId), msg.sender, tokenId);
		
		Position memory position = positions[tokenId];
		delete positions[tokenId];
		_burn(tokenId);
		
		address pool = getPool(position.fee);		
		(amount0, amount1) = IUniswapV3Pool(pool).burn(position.tickLower, position.tickUpper, position.liquidity);
		_updateBalance(position.fee, position.tickLower, position.tickUpper);
		
		(uint256 feeCollected0, uint256 feeCollected1) = _getFeeCollected(position, pool);
		amount0 = amount0.add(feeCollected0);
		amount1 = amount1.add(feeCollected1);

		(amount0, amount1) = IUniswapV3Pool(pool).collect(to, position.tickLower, position.tickUpper, safe128(amount0), safe128(amount1));
		
		emit UpdatePositionLiquidity(tokenId, 0);
		emit UpdatePositionUnclaimedFees(tokenId, 0, 0);
	}
	
	function _splitUint(uint256 n, uint256 percentage) internal pure returns (uint256 a, uint256 b) {
		a = n.mul(percentage).div(1e18);
		b = n.sub(a);
	}
	function split(uint256 tokenId, uint256 percentage) external nonReentrant returns (uint256 newTokenId) {
		require(percentage <= 1e18, "TokenizedUniswapV3Position: ABOVE_100_PERCENT");
		address owner = _requireOwned(tokenId);
		_checkAuthorized(owner, msg.sender, tokenId);
		_approve(address(0), tokenId, address(0)); // reset approval
		
		_updatePositionUnclaimedFees(tokenId);
		
		Position memory oldPosition = positions[tokenId];
		(uint256 newLiquidity, uint256 oldLiquidity) = _splitUint(oldPosition.liquidity, percentage);
		positions[tokenId].liquidity = safe128(oldLiquidity);
		newTokenId = positionsLength++;
		_mint(owner, newTokenId);
		positions[newTokenId] = Position({
			fee: oldPosition.fee,
			tickLower: oldPosition.tickLower,
			tickUpper: oldPosition.tickUpper,
			liquidity: safe128(newLiquidity),
			feeGrowthInside0LastX128: oldPosition.feeGrowthInside0LastX128,
			feeGrowthInside1LastX128: oldPosition.feeGrowthInside1LastX128,
			unclaimedFees0: 0,
			unclaimedFees1: 0
		});
		
		emit UpdatePositionLiquidity(tokenId, oldLiquidity);
		emit MintPosition(newTokenId, oldPosition.fee, oldPosition.tickLower, oldPosition.tickUpper);
		emit UpdatePositionLiquidity(newTokenId, newLiquidity);
		emit UpdatePositionFeeGrowthInside(newTokenId, oldPosition.feeGrowthInside0LastX128, oldPosition.feeGrowthInside1LastX128);
		emit UpdatePositionUnclaimedFees(newTokenId, 0, 0);
	}
	
	function join(uint256 tokenId, uint256 tokenToJoin) external nonReentrant {
		_checkAuthorized(_requireOwned(tokenToJoin), msg.sender, tokenToJoin);
		
		Position memory positionA = positions[tokenId];
		Position memory positionB = positions[tokenToJoin];
		
		require(tokenId != tokenToJoin, "TokenizedUniswapV3Position: SAME_ID");
		require(positionA.fee == positionB.fee, "TokenizedUniswapV3Position: INCOMPATIBLE_TOKENS_META");
		require(positionA.tickLower == positionB.tickLower, "TokenizedUniswapV3Position: INCOMPATIBLE_TOKENS_META");
		require(positionA.tickUpper == positionB.tickUpper, "TokenizedUniswapV3Position: INCOMPATIBLE_TOKENS_META");
		
		uint256 newLiquidity = uint256(positionA.liquidity).add(positionB.liquidity);
		
		// update feeGrowthInside and feeCollected based on the latest snapshot
		// it's not necessary to call burn() in order to update the feeGrowthInside of the position
		uint256 newUnclaimedFees0; uint256 newUnclaimedFees1;
		address pool = getPool(positionA.fee);
		(
			uint256 newFeeGrowthInside0LastX128, 
			uint256 newFeeGrowthInside1LastX128, 
			uint256 feeCollectedA0, 
			uint256 feeCollectedA1
		) = _getfeeCollectedAndGrowth(positionA, pool);
		{
		(
			uint256 feeCollectedB0, 
			uint256 feeCollectedB1
		) = _getFeeCollected(positionB, pool);
		newUnclaimedFees0 = feeCollectedA0.add(feeCollectedB0);
		newUnclaimedFees1 = feeCollectedA1.add(feeCollectedB1);
		}
		
		positions[tokenId].liquidity = safe128(newLiquidity);
		positions[tokenId].feeGrowthInside0LastX128 = newFeeGrowthInside0LastX128;
		positions[tokenId].feeGrowthInside1LastX128 = newFeeGrowthInside1LastX128;
		positions[tokenId].unclaimedFees0 = newUnclaimedFees0;
		positions[tokenId].unclaimedFees1 = newUnclaimedFees1;
		delete positions[tokenToJoin];
		_burn(tokenToJoin);
		
		emit UpdatePositionLiquidity(tokenId, newLiquidity);
		emit UpdatePositionFeeGrowthInside(tokenId, newFeeGrowthInside0LastX128, newFeeGrowthInside1LastX128);
		emit UpdatePositionUnclaimedFees(tokenId, newUnclaimedFees0, newUnclaimedFees1);
		emit UpdatePositionLiquidity(tokenToJoin, 0);
		emit UpdatePositionUnclaimedFees(tokenToJoin, 0, 0);
	}
	
	/*** Claim Fees ***/

	function _checkAuthorizedCollateral(uint256 tokenId) internal view {
		// check that the sender is authorized to spend the tokenId of the collateral contract that owns this nft
		address collateral = _requireOwned(tokenId);
		address owner = IERC721(collateral).ownerOf(tokenId);
		if (owner == msg.sender) return;
		if (IERC721(collateral).getApproved(tokenId) == msg.sender) return;
		if (IERC721(collateral).isApprovedForAll(owner, msg.sender)) return;
		revert("TokenizedUniswapV3Position: UNAUTHORIZED");
	}
	function _updatePositionUnclaimedFees(uint256 tokenId) internal {
		Position memory position = positions[tokenId];
		
		address pool = getPool(position.fee);
		IUniswapV3Pool(pool).burn(position.tickLower, position.tickUpper, 0);
		
		(
			uint256 feeGrowthInside0LastX128,
			uint256 feeGrowthInside1LastX128,
			uint256 unclaimedFees0,
			uint256 unclaimedFees1
		) = _getfeeCollectedAndGrowth(position, pool);
		
		positions[tokenId].feeGrowthInside0LastX128 = feeGrowthInside0LastX128;
		positions[tokenId].feeGrowthInside1LastX128 = feeGrowthInside1LastX128;
		positions[tokenId].unclaimedFees0 = unclaimedFees0;
		positions[tokenId].unclaimedFees1 = unclaimedFees1;
		
		emit UpdatePositionFeeGrowthInside(tokenId, feeGrowthInside0LastX128, feeGrowthInside1LastX128);
		emit UpdatePositionUnclaimedFees(tokenId, unclaimedFees0, unclaimedFees1);
	}
	function _claim(address to, uint256 tokenId) internal returns (uint256, uint256) {
		_updatePositionUnclaimedFees(tokenId);
		Position memory position = positions[tokenId];
		
		uint256 feeCollected0 = position.unclaimedFees0;
		uint256 feeCollected1 = position.unclaimedFees1;
		if (feeCollected0 == 0 && feeCollected1 == 0) return (0, 0);
		
		address pool = getPool(position.fee);
		IUniswapV3Pool(pool).collect(to, position.tickLower, position.tickUpper, safe128(feeCollected0), safe128(feeCollected1));
		
		positions[tokenId].unclaimedFees0 = 0;
		positions[tokenId].unclaimedFees1 = 0;
		
		emit UpdatePositionUnclaimedFees(tokenId, 0, 0);
		
		return (feeCollected0, feeCollected1);
	}
	function claim(address to, uint256 tokenId) external nonReentrant returns (uint256, uint256) {
		_checkAuthorizedCollateral(tokenId);
		return _claim(to, tokenId);
	}
	
	/*** Utilities ***/

    function safe128(uint n) internal pure returns (uint128) {
        require(n < 2**128, "Impermax: SAFE128");
        return uint128(n);
    }

    function safe160(uint n) internal pure returns (uint160) {
        require(n < 2**160, "Impermax: SAFE160");
        return uint160(n);
    }
	
	// prevents a contract from calling itself, directly or indirectly.
	bool internal _notEntered = true;
	modifier nonReentrant() {
		require(_notEntered, "Impermax: REENTERED");
		_notEntered = false;
		_;
		_notEntered = true;
	}
}