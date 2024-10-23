pragma solidity =0.5.16;
pragma experimental ABIEncoderV2;

import "../ImpermaxERC721.sol";
import "../interfaces/INFTLP.sol";
import "./interfaces/IUniswapV3Factory.sol";
import "./interfaces/IUniswapV3Pool.sol";
import "./interfaces/ITokenizedUniswapV3Position.sol";
import "./libraries/UniswapV3CollateralMath.sol";
import "./libraries/UniswapV3WeightedOracleLibrary.sol";
import "./libraries/UniswapV3Position.sol";
import "./libraries/TickMath.sol";

contract TokenizedUniswapV3Position is ITokenizedUniswapV3Position, INFTLP, ImpermaxERC721 {
	using TickMath for int24;
	using UniswapV3CollateralMath for UniswapV3CollateralMath.PositionObject;
	using UniswapV3WeightedOracleLibrary for UniswapV3WeightedOracleLibrary.PeriodObservation[];
	
    uint constant Q128 = 2**128;
	
	struct Position {
		uint24 fee;
		int24 tickLower;
		int24 tickUpper;
		uint128 liquidity;
		uint256 feeGrowthInside0LastX128;
		uint256 feeGrowthInside1LastX128;
	}

	uint32 constant ORACLE_T = 1800;

	address public factory;
	address public uniswapV3Factory;
	address public token0;
	address public token1;
	
	mapping(uint24 => 
		mapping(int24 => 
			mapping(int24 => uint256)
		)
	) public totalBalance;
	
	mapping(uint256 => Position) public positions;
	uint256 public positionLength;
	
	mapping(uint24 => address) public uniswapV3PoolByFee;
	address[] public poolsList;
	
	/*** Global state ***/
	
	// called once by the factory at the time of deployment
	function _initialize (
		address _uniswapV3Factory, 
		address _token0, 
		address _token1
	) external {
		require(factory == address(0), "Impermax: FACTORY_ALREADY_SET"); // sufficient check
		factory = msg.sender;
		_setName("Tokenized Uniswap V3", "NFT-UNI-V3");
		uniswapV3Factory = _uniswapV3Factory;
		token0 = _token0;
		token1 = _token1;
	}
	
	function _getPool(uint24 fee) internal returns (address pool) {
		pool = uniswapV3PoolByFee[fee];
		if (pool == address(0)) {
			pool = IUniswapV3Factory(uniswapV3Factory).getPool(token0, token1, fee);
			require(pool != address(0), "TokenizedUniswapV3Position: UNSUPPORTED_FEE");
			uniswapV3PoolByFee[fee] = pool;
			poolsList.push(pool);
		}
	}
	
	function _updateBalance(uint24 fee, int24 tickLower, int24 tickUpper) internal {
		address pool = uniswapV3PoolByFee[fee];
		bytes32 hash = UniswapV3Position.getHash(address(this), tickLower, tickUpper);
		(uint balance,,,,) = IUniswapV3Pool(pool).positions(hash);
		totalBalance[fee][tickLower][tickUpper] = balance;
	}
	
	function oraclePriceSqrtX96() public returns (uint256) {
		UniswapV3WeightedOracleLibrary.PeriodObservation[] memory observations = new UniswapV3WeightedOracleLibrary.PeriodObservation[](poolsList.length);
		for (uint i = 0; i < poolsList.length; i++) {
			observations[i] = UniswapV3WeightedOracleLibrary.consult(poolsList[i], ORACLE_T);
		}
		int24 arithmeticMeanWeightedTick = observations.getArithmeticMeanTickWeightedByLiquidity();
		return arithmeticMeanWeightedTick.getSqrtRatioAtTick();
	}
 
	/*** Position state ***/
	
	// thia assumes that the position fee growth snapshot has already been updated through burn()
	function _getFeeCollected(Position memory position, address pool) internal returns (uint256 feeCollectedA, uint256 feeCollectedB) {
		bytes32 hash = UniswapV3Position.getHash(address(this), position.tickLower, position.tickUpper);
		(,uint256 fg0, uint256 fg1,,) = IUniswapV3Pool(pool).positions(hash);
		
		feeCollectedA = fg0.sub(position.feeGrowthInside0LastX128).mul(position.liquidity).div(Q128);
		feeCollectedB = fg1.sub(position.feeGrowthInside1LastX128).mul(position.liquidity).div(Q128);
	}
	
	function getPositionData(uint256 tokenId, uint256 safetyMarginSqrt) external returns (
		uint256 priceSqrtX96,
		INFTLP.RealXYs memory realXYs
	) {
		Position memory position = positions[tokenId];
		
		// trigger update of fee growth
		address pool = uniswapV3PoolByFee[position.fee];
		IUniswapV3Pool(pool).burn(position.tickLower, position.tickUpper, 0);
		(uint256 feeCollectedX, uint256 feeCollectedY) = _getFeeCollected(position, pool);
	
		require(safetyMarginSqrt >= 1e18, "TokenizedUniswapV3Position: INVALID_SAFETY_MARGIN");
		require(ownerOf[tokenId] != address(0), "TokenizedUniswapV3Position: UNINITIALIZED_POSITION");
		UniswapV3CollateralMath.PositionObject memory positionObject = UniswapV3CollateralMath.newPosition(
			position.liquidity,
			position.tickLower.getSqrtRatioAtTick(),
			position.tickUpper.getSqrtRatioAtTick()
		);
		
		priceSqrtX96 = oraclePriceSqrtX96();
		uint256 currentPrice = priceSqrtX96;
		uint256 lowestPrice = priceSqrtX96.mul(1e18).div(safetyMarginSqrt);
		uint256 highestPrice = priceSqrtX96.mul(safetyMarginSqrt).div(1e18);
		
		realXYs.lowestPrice.realX = positionObject.getRealX(lowestPrice).add(feeCollectedX);
		realXYs.lowestPrice.realY = positionObject.getRealY(lowestPrice).add(feeCollectedY);
		realXYs.currentPrice.realX = positionObject.getRealX(currentPrice).add(feeCollectedX);
		realXYs.currentPrice.realY = positionObject.getRealY(currentPrice).add(feeCollectedY);
		realXYs.highestPrice.realX = positionObject.getRealX(highestPrice).add(feeCollectedX);
		realXYs.highestPrice.realY = positionObject.getRealY(highestPrice).add(feeCollectedY);
	}
 
	/*** Interactions ***/
	
	// this low-level function should be called from another contract
	function mint(address to, uint24 fee, int24 tickLower, int24 tickUpper) external nonReentrant returns (uint256 newTokenId) {
		address pool = _getPool(fee);		
		bytes32 hash = UniswapV3Position.getHash(address(this), tickLower, tickUpper);
		(uint balance, uint256 fg0, uint256 fg1,,) = IUniswapV3Pool(pool).positions(hash);
		uint liquidity = balance.sub(totalBalance[fee][tickLower][tickUpper]);
		
		newTokenId = positionLength++;
		_mint(to, newTokenId);		
		positions[newTokenId] = Position({
			fee: fee,
			tickLower: tickLower,
			tickUpper: tickUpper,
			liquidity: safe128(liquidity),
			feeGrowthInside0LastX128: fg0,
			feeGrowthInside1LastX128: fg1
		});
		
		_updateBalance(fee, tickLower, tickUpper);
		
		emit MintPosition(newTokenId, fee, tickLower, tickUpper);
		emit UpdatePositionLiquidity(newTokenId, liquidity);
		emit UpdatePositionFeeGrowthInside(newTokenId, fg0, fg1);
	}

	// this low-level function should be called from another contract
	function redeem(address to, uint256 tokenId) external nonReentrant returns (uint256 amount0, uint256 amount1) {
		_checkAuthorized(ownerOf[tokenId], msg.sender, tokenId);
		
		Position memory position = positions[tokenId];
		delete positions[tokenId];
		_burn(tokenId);
		
		address pool = _getPool(position.fee);		
		(amount0, amount1) = IUniswapV3Pool(pool).burn(position.tickLower, position.tickUpper, position.liquidity);
		_updateBalance(position.fee, position.tickLower, position.tickUpper);
		
		(uint256 feeCollected0, uint256 feeCollected1) = _getFeeCollected(position, pool);
		amount0 = amount0.add(feeCollected0);
		amount1 = amount1.add(feeCollected1);

		(amount0, amount1) = IUniswapV3Pool(pool).collect(to, position.tickLower, position.tickUpper, safe128(amount0), safe128(amount1));
		
		emit UpdatePositionLiquidity(tokenId, 0);
	}
	
	function split(uint256 tokenId, uint256 percentage) external nonReentrant returns (uint256 newTokenId) {
		require(percentage < 1e18, "TokenizedUniswapV3Position: ABOVE_100_PERCENT");
		address owner = ownerOf[tokenId];
		_checkAuthorized(owner, msg.sender, tokenId);
		_approve(address(0), tokenId, address(0)); // reset approval
		
		Position memory oldPosition = positions[tokenId];
		uint256 newTokenLiquidity = uint256(oldPosition.liquidity).mul(percentage).div(1e18);
		uint128 oldTokenLiquidity = safe128(oldPosition.liquidity - newTokenLiquidity);
		positions[tokenId].liquidity = oldTokenLiquidity;
		newTokenId = positionLength++;
		_mint(owner, newTokenId);
		positions[newTokenId] = Position({
			fee: oldPosition.fee,
			tickLower: oldPosition.tickLower,
			tickUpper: oldPosition.tickUpper,
			liquidity: safe128(newTokenLiquidity),
			feeGrowthInside0LastX128: oldPosition.feeGrowthInside0LastX128,
			feeGrowthInside1LastX128: oldPosition.feeGrowthInside1LastX128
		});
		
		emit UpdatePositionLiquidity(tokenId, oldTokenLiquidity);
		emit MintPosition(newTokenId, oldPosition.fee, oldPosition.tickLower, oldPosition.tickUpper);
		emit UpdatePositionLiquidity(newTokenId, newTokenLiquidity);
		emit UpdatePositionFeeGrowthInside(newTokenId, oldPosition.feeGrowthInside0LastX128, oldPosition.feeGrowthInside1LastX128);
	}
	
	// TODO WTFFFF -> I'm not checking if the positions have the same range?
	function join(uint256 tokenId, uint256 tokenToJoin) external nonReentrant {
		_checkAuthorized(ownerOf[tokenToJoin], msg.sender, tokenToJoin);
		
		Position memory positionA = positions[tokenId];
		Position memory positionB = positions[tokenToJoin];
		
		require(positionA.fee == positionB.fee, "TokenizedUniswapV3Position: INCOMPATIBLE_TOKENS_META");
		require(positionA.tickLower == positionB.tickLower, "TokenizedUniswapV3Position: INCOMPATIBLE_TOKENS_META");
		require(positionA.tickUpper == positionB.tickUpper, "TokenizedUniswapV3Position: INCOMPATIBLE_TOKENS_META");
		
		// new fee growth is calculated as average of the 2 positions weighted by liquidity
		uint256 newLiquidity = uint256(positionA.liquidity).add(positionB.liquidity);
		uint256 tA0 = positionA.feeGrowthInside0LastX128.mul(positionA.liquidity);
		uint256 tA1 = positionA.feeGrowthInside1LastX128.mul(positionA.liquidity);
		uint256 tB0 = positionB.feeGrowthInside0LastX128.mul(positionB.liquidity);
		uint256 tB1 = positionB.feeGrowthInside1LastX128.mul(positionB.liquidity);
		uint256 newFeeGrowthInside0LastX128 = tA0.add(tB0).div(newLiquidity);
		uint256 newFeeGrowthInside1LastX128 = tA1.add(tB1).div(newLiquidity);
		
		positions[tokenId].liquidity = safe128(newLiquidity);
		positions[tokenId].feeGrowthInside0LastX128 = newFeeGrowthInside0LastX128;
		positions[tokenId].feeGrowthInside1LastX128 = newFeeGrowthInside1LastX128;
		delete positions[tokenToJoin];
		_burn(tokenToJoin);
		
		emit UpdatePositionLiquidity(tokenId, newLiquidity);
		emit UpdatePositionFeeGrowthInside(tokenId, newFeeGrowthInside0LastX128, newFeeGrowthInside1LastX128);
		emit UpdatePositionLiquidity(tokenToJoin, 0);
	}
	
	// THERE ARE MANY PROBLEMS WITH MANUAL CLAIM
	// - handling multiple calls
	// - we should check the collateral is enough after claiming, so it can't be permissionless
	
	/*** Utilities ***/

    function safe128(uint n) internal pure returns (uint128) {
        require(n < 2**128, "Impermax: SAFE128");
        return uint128(n);
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