pragma solidity =0.5.16;
pragma experimental ABIEncoderV2;

import "../ImpermaxERC721.sol";
import "../interfaces/INFTLP.sol";
import "./interfaces/IUniswapV3Factory.sol";
import "./interfaces/IUniswapV3Pool.sol";
import "./interfaces/IUniswapV3AC.sol";
import "./interfaces/IV3Oracle.sol";
import "./interfaces/ITokenizedUniswapV3Position.sol";
import "./interfaces/ITokenizedUniswapV3Factory.sol";
import "./libraries/LiquidityAmounts.sol";
import "./libraries/UniswapV3Position.sol";
import "./libraries/TickMath.sol";

contract TokenizedUniswapV3Position is ITokenizedUniswapV3Position, INFTLP, ImpermaxERC721 {
	using TickMath for int24;
	
    uint constant Q128 = 2**128;

	uint256 public constant FEE_COLLECTED_WEIGHT = 0.95e18; // 95%
	
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
		
		// trigger update of fee growth
		address pool = getPool(position.fee);
		IUniswapV3Pool(pool).burn(position.tickLower, position.tickUpper, 0);
		(uint256 feeCollectedX, uint256 feeCollectedY) = _getFeeCollected(position, pool);
	
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
		
		uint256 feeCollectedWeightedX = feeCollectedX.mul(FEE_COLLECTED_WEIGHT).div(1e18);
		uint256 feeCollectedWeightedY = feeCollectedY.mul(FEE_COLLECTED_WEIGHT).div(1e18);
		
		realXYs.lowestPrice.realX += feeCollectedWeightedX;
		realXYs.lowestPrice.realY += feeCollectedWeightedY; 
		realXYs.currentPrice.realX += feeCollectedX;
		realXYs.currentPrice.realY += feeCollectedY;
		realXYs.highestPrice.realX += feeCollectedWeightedX;
		realXYs.highestPrice.realY += feeCollectedWeightedY;
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
		
		Position memory oldPosition = positions[tokenId];
		(uint256 newLiquidity, uint256 oldLiquidity) = _splitUint(oldPosition.liquidity, percentage);
		(uint256 newUnclaimedFees0, uint256 oldUnclaimedFees0) = _splitUint(oldPosition.unclaimedFees0, percentage);
		(uint256 newUnclaimedFees1, uint256 oldUnclaimedFees1) = _splitUint(oldPosition.unclaimedFees1, percentage);
		positions[tokenId].liquidity = safe128(oldLiquidity);
		positions[tokenId].unclaimedFees0 = oldUnclaimedFees0;
		positions[tokenId].unclaimedFees1 = oldUnclaimedFees1;
		newTokenId = positionsLength++;
		_mint(owner, newTokenId);
		positions[newTokenId] = Position({
			fee: oldPosition.fee,
			tickLower: oldPosition.tickLower,
			tickUpper: oldPosition.tickUpper,
			liquidity: safe128(newLiquidity),
			feeGrowthInside0LastX128: oldPosition.feeGrowthInside0LastX128,
			feeGrowthInside1LastX128: oldPosition.feeGrowthInside1LastX128,
			unclaimedFees0: newUnclaimedFees0,
			unclaimedFees1: newUnclaimedFees1
		});
		
		emit UpdatePositionLiquidity(tokenId, oldLiquidity);
		emit UpdatePositionUnclaimedFees(tokenId, oldUnclaimedFees0, oldUnclaimedFees1);
		emit MintPosition(newTokenId, oldPosition.fee, oldPosition.tickLower, oldPosition.tickUpper);
		emit UpdatePositionLiquidity(newTokenId, newLiquidity);
		emit UpdatePositionUnclaimedFees(newTokenId, newUnclaimedFees0, newUnclaimedFees1);
		emit UpdatePositionFeeGrowthInside(newTokenId, oldPosition.feeGrowthInside0LastX128, oldPosition.feeGrowthInside1LastX128);
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
	
	/*** Autocompounding Module ***/
	
	function reinvest(uint256 tokenId, address bountyTo) external nonReentrant returns (uint256 bounty0, uint256 bounty1) {
		// 1. Initialize and read fee collected
		address acModule = ITokenizedUniswapV3Factory(factory).acModule();
		Position memory position = positions[tokenId];
		Position memory newPosition = positions[tokenId];
		uint256 feeCollected0; uint256 feeCollected1;
		address pool = getPool(position.fee);
		IUniswapV3Pool(pool).burn(position.tickLower, position.tickUpper, 0);
		(
			newPosition.feeGrowthInside0LastX128,
			newPosition.feeGrowthInside1LastX128,
			feeCollected0,
			feeCollected1
		) = _getfeeCollectedAndGrowth(position, pool);
		require(feeCollected0 > 0 || feeCollected1 > 0, "TokenizedUniswapV3Position: NO_FEES_COLLECTED");
	
		// 2. Calculate how much to collect and send it to autocompounder (and update unclaimedFees)
		(uint256 collect0, uint256 collect1, bytes memory data) = IUniswapV3AC(acModule).getToCollect(
			position, 
			tokenId, 
			feeCollected0, 
			feeCollected1
		);
		newPosition.unclaimedFees0 = feeCollected0.sub(collect0, "TokenizedUniswapV3Position: COLLECT_0_TOO_HIGH");
		newPosition.unclaimedFees1 = feeCollected1.sub(collect1, "TokenizedUniswapV3Position: COLLECT_1_TOO_HIGH");
		
		IUniswapV3Pool(pool).collect(acModule, position.tickLower, position.tickUpper, safe128(collect0), safe128(collect1));
		
		
		// 3. Let the autocompounder convert the fees to liquidity
		{
		uint256 totalBalanceBefore = totalBalance[position.fee][position.tickLower][position.tickUpper];
		(bounty0, bounty1) = IUniswapV3AC(acModule).mintLiquidity(bountyTo, data);		
		_updateBalance(position.fee, position.tickLower, position.tickUpper);
		uint256 newLiquidity = totalBalance[position.fee][position.tickLower][position.tickUpper].sub(totalBalanceBefore);
		require(newLiquidity > 0, "TokenizedUniswapV3Position: NO_LIQUIDITY_ADDED");
		newPosition.liquidity = safe128(newLiquidity.add(position.liquidity));
		}
		
		// 4. Update the position
		positions[tokenId] = newPosition;
		
		emit UpdatePositionLiquidity(tokenId, newPosition.liquidity);
		emit UpdatePositionFeeGrowthInside(tokenId, newPosition.feeGrowthInside0LastX128, newPosition.feeGrowthInside1LastX128);
		emit UpdatePositionUnclaimedFees(tokenId, newPosition.unclaimedFees0, newPosition.unclaimedFees1);
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