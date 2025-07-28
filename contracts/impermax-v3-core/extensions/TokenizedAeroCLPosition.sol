pragma solidity =0.5.16;
pragma experimental ABIEncoderV2;

import "../ImpermaxERC721.sol";
import "../interfaces/INFTLP.sol";
import "../interfaces/IERC20.sol";
import "../interfaces/IERC721.sol";
import "./interfaces/ICLFactory.sol";
import "./interfaces/IV3Oracle.sol";
import "./interfaces/ITokenizedAeroCLPosition.sol";
import "./interfaces/ITokenizedAeroCLFactory.sol";
import "./interfaces/INonfungiblePositionManagerAero.sol";
import "./interfaces/ICLGaugeAero.sol";
import "./interfaces/INftlpCallee.sol";
import "../libraries/TransferHelper.sol";
import "./libraries/LiquidityAmounts.sol";
import "./libraries/TickMath.sol";
import "./libraries/NfpmAeroInteractions.sol";

contract TokenizedAeroCLPosition is ITokenizedAeroCLPosition, INFTLP, ImpermaxERC721 {
	using TickMath for int24;
	
	uint constant Q128 = 2**128;
	
	address public factory;
	address public clFactory;
	address public nfpManager;
	address public oracle;
	address public token0;
	address public token1;
	address public rewardsToken;
	
	mapping(int24 => address) public tickSpacingToGauge;
	
	uint public totalRewardBalance = 0;
	mapping(uint256 => uint256) public rewardOwed;
			
	/*** Global state ***/
	
	// called once by the factory at the time of deployment
	function _initialize (
		address _clFactory, 
		address _nfpManager, 
		address _oracle, 
		address _token0, 
		address _token1,
		address _rewardsToken
	) external {
		require(factory == address(0), "Impermax: FACTORY_ALREADY_SET"); // sufficient check
		factory = msg.sender;
		_setName("Tokenized Uniswap V3", "NFT-UNI-V3");
		clFactory = _clFactory;
		nfpManager = _nfpManager;
		oracle = _oracle;
		token0 = _token0;
		token1 = _token1;
		rewardsToken = _rewardsToken;
		
		IERC20(token0).approve(nfpManager, uint256(-1));
		IERC20(token1).approve(nfpManager, uint256(-1));
		
		// quickly check if the oracle support this tokens pair
		oraclePriceSqrtX96();
	}
	
	function getPool(int24 tickSpacing) public view returns (address pool) {
		pool = ICLFactory(clFactory).getPool(token0, token1, tickSpacing);
		require(pool != address(0), "TokenizedAeroCLPosition: UNSUPPORTED_TICK_SPACING");
	}
	function getGauge(uint256 tokenId) public view returns (address gauge) {
		(,,,,int24 tickSpacing,,,) = INonfungiblePositionManagerAero(nfpManager).positions(tokenId);
		gauge = tickSpacingToGauge[tickSpacing];
		require(gauge != address(0), "TokenizedAeroCLPosition: UNSUPPORTED_TICK_SPACING");
	}
	
	function _updateReward() internal {
		totalRewardBalance = IERC20(rewardsToken).balanceOf(address(this));
		emit SyncReward(totalRewardBalance);
	}
	function _getClaimAmount(uint256 tokenId) internal view returns (uint256 claimAmount) {
		uint256 rewardBalance = IERC20(rewardsToken).balanceOf(address(this));
		return rewardOwed[tokenId].add(rewardBalance.sub(totalRewardBalance));
	}
	
	function oraclePriceSqrtX96() public returns (uint256) {
		return IV3Oracle(oracle).oraclePriceSqrtX96(token0, token1);
	}
 
	/*** Position state ***/
	
	function getPositionData(uint256 tokenId, uint256 safetyMarginSqrt) external returns (
		uint256 priceSqrtX96,
		INFTLP.RealXYs memory realXYs
	) {
		require(safetyMarginSqrt >= 1e18, "TokenizedAeroCLPosition: INVALID_SAFETY_MARGIN");
		
		(,,,,, int24 tickLower, int24 tickUpper, uint128 liquidity) = INonfungiblePositionManagerAero(nfpManager).positions(tokenId);
		_requireOwnedNfp(tokenId);
		
		uint160 pa = tickLower.getSqrtRatioAtTick();
		uint160 pb = tickUpper.getSqrtRatioAtTick();
		
		priceSqrtX96 = oraclePriceSqrtX96();
		uint160 currentPrice = safe160(priceSqrtX96);
		uint160 lowestPrice = safe160(priceSqrtX96.mul(1e18).div(safetyMarginSqrt));
		uint160 highestPrice = safe160(priceSqrtX96.mul(safetyMarginSqrt).div(1e18));
		
		(realXYs.lowestPrice.realX, realXYs.lowestPrice.realY) = LiquidityAmounts.getAmountsForLiquidity(lowestPrice, pa, pb, liquidity);
		(realXYs.currentPrice.realX, realXYs.currentPrice.realY) = LiquidityAmounts.getAmountsForLiquidity(currentPrice, pa, pb, liquidity);
		(realXYs.highestPrice.realX, realXYs.highestPrice.realY) = LiquidityAmounts.getAmountsForLiquidity(highestPrice, pa, pb, liquidity);
	}
 
	/*** Interactions ***/
	
	// this low-level function should be called from another contract
	function mint(address to, uint256 tokenId, bytes calldata data) external nonReentrant {
		require(_ownerOf[tokenId] == address(0), "TokenizedAeroCLPosition: NFT_ALREADY_MINTED");
		
		// optimistically mint the nft
		_mint(to, tokenId);
		if (data.length > 0) INftlpCallee(to).nftlpMint(msg.sender, tokenId, data);
		
		require(IERC721(nfpManager).ownerOf(tokenId) == address(this), "TokenizedAeroCLPosition: NFT_NOT_RECEIVED");
		
		(,,address _token0, address _token1, int24 tickSpacing, int24 tickLower, int24 tickUpper, uint128 liquidity) = INonfungiblePositionManagerAero(nfpManager).positions(tokenId);
		require(_token0 == token0, "TokenizedAeroCLPosition: INCOMPATIBLE_POSITION");
		require(_token1 == token1, "TokenizedAeroCLPosition: INCOMPATIBLE_POSITION");
		
		address gauge = getGauge(tokenId);
		IERC721(nfpManager).approve(gauge, tokenId);
		ICLGaugeAero(gauge).deposit(tokenId);
		
		emit MintPosition(tokenId, tickSpacing, tickLower, tickUpper);
		emit UpdatePositionLiquidity(tokenId, liquidity);
	}

	// this low-level function should be called from another contract
	function redeem(address to, uint256 tokenId) external nonReentrant updateReward {
		_checkAuthorized(_requireOwned(tokenId), msg.sender, tokenId);
		_burn(tokenId);
		
		address gauge = getGauge(tokenId);
		ICLGaugeAero(gauge).withdraw(tokenId);
		
		uint256 claimAmount = _getClaimAmount(tokenId);
		rewardOwed[tokenId] = 0;
		if (claimAmount > 0) TransferHelper.safeTransfer(rewardsToken, to, claimAmount);
		IERC721(nfpManager).safeTransferFrom(address(this), to, tokenId);
		
		emit UpdatePositionLiquidity(tokenId, 0);
		emit UpdatePositionReward(tokenId, 0, claimAmount);
	}
	
	function split(uint256 tokenId, uint256 percentage) external nonReentrant updateReward returns (uint256 newTokenId) {
		require(percentage <= 1e18, "TokenizedAeroCLPosition: ABOVE_100_PERCENT");
		address owner = _requireOwned(tokenId);
		_checkAuthorized(owner, msg.sender, tokenId);
		_approve(address(0), tokenId, address(0)); // reset approval
		
		address gauge = getGauge(tokenId);
		ICLGaugeAero(gauge).withdraw(tokenId);
		
		uint128 oldTokenLiquidity; uint128 newTokenLiquidity;
		(newTokenId, oldTokenLiquidity, newTokenLiquidity) = NfpmAeroInteractions.decreaseAndMint(nfpManager, tokenId, percentage);
		
		IERC721(nfpManager).approve(gauge, tokenId);
		ICLGaugeAero(gauge).deposit(tokenId);
		IERC721(nfpManager).approve(gauge, newTokenId);
		ICLGaugeAero(gauge).deposit(newTokenId);
		_mint(owner, newTokenId);
		
		uint256 claimAmount = _getClaimAmount(tokenId);
		rewardOwed[tokenId] = claimAmount;
		
		emit SplitPosition(tokenId, newTokenId);
		emit UpdatePositionLiquidity(tokenId, oldTokenLiquidity);
		emit UpdatePositionLiquidity(newTokenId, newTokenLiquidity);
		emit UpdatePositionReward(tokenId, claimAmount, 0);
	}
	
	function increaseLiquidity(uint256 tokenId) external nonReentrant updateReward returns (uint128 liquidity, uint256 amount0, uint256 amount1) {
		address gauge = getGauge(tokenId);
		ICLGaugeAero(gauge).withdraw(tokenId);
		
		uint128 totalLiquidity;
		(liquidity, totalLiquidity, amount0, amount1) = NfpmAeroInteractions.increase(nfpManager, tokenId);
			
		IERC721(nfpManager).approve(gauge, tokenId);
		ICLGaugeAero(gauge).deposit(tokenId);
		
		uint256 claimAmount = _getClaimAmount(tokenId);
		rewardOwed[tokenId] = claimAmount;
		
		emit UpdatePositionLiquidity(tokenId, totalLiquidity);
		emit UpdatePositionReward(tokenId, claimAmount, 0);
	}
	
	// withdraw dust
	function skim(address to) external nonReentrant returns (uint256 balance0, uint256 balance1) {
		balance0 = IERC20(token0).balanceOf(address(this));
		balance1 = IERC20(token1).balanceOf(address(this));
		if (balance0 > 0) TransferHelper.safeTransfer(token0, to, balance0);
		if (balance1 > 0) TransferHelper.safeTransfer(token1, to, balance1);
	}
	
	/*** Claim Fees ***/

	function _checkAuthorizedCollateral(uint256 tokenId) internal view {
		// check that the sender is authorized to spend the tokenId of the collateral contract that owns this nft
		address collateral = _requireOwned(tokenId);
		address owner = IERC721(collateral).ownerOf(tokenId);
		if (owner == msg.sender) return;
		if (IERC721(collateral).getApproved(tokenId) == msg.sender) return;
		if (IERC721(collateral).isApprovedForAll(owner, msg.sender)) return;
		revert("TokenizedAeroCLPosition: UNAUTHORIZED");
	}
	function claim(uint256 tokenId, address to) external nonReentrant updateReward returns (uint256 claimAmount) {
		_checkAuthorizedCollateral(tokenId);
		
		address gauge = getGauge(tokenId);
		ICLGaugeAero(gauge).getReward(tokenId);
		
		claimAmount = _getClaimAmount(tokenId);
		rewardOwed[tokenId] = 0;
		if (claimAmount > 0) TransferHelper.safeTransfer(rewardsToken, to, claimAmount);
		
		emit UpdatePositionReward(tokenId, 0, claimAmount);
	}
	
	/*** Admin ***/
	
	function _addGauge(int24 tickSpacing, address gauge) external {
		address admin = ITokenizedAeroCLFactory(factory).admin();
		require(msg.sender == admin, "TokenizedAeroCLPosition: UNAUTHORIZED");
		require(tickSpacingToGauge[tickSpacing] == address(0), "TokenizedAeroCLPosition: TICKSPACING_INITIALIZED");
		require(ICLGaugeAero(gauge).pool() == getPool(tickSpacing), "TokenizedAeroCLPosition: INCOMPATIBLE_GAUGE");
		tickSpacingToGauge[tickSpacing] = gauge;
		emit GaugeAdded(tickSpacing, gauge);
	}
	
	/*** Utilities ***/
	
	function onERC721Received(address operator, address from, uint256 tokenId, bytes calldata data) external pure returns (bytes4 returnValue) {
		operator; from; tokenId; data;
		return bytes4(keccak256("onERC721Received(address,address,uint256,bytes)"));
	}
	
	function _requireOwnedNfp(uint tokenId) internal {
		_requireOwned(tokenId);
		address owner = IERC721(nfpManager).ownerOf(tokenId);
		if (owner == address(this)) return;
		address gauge = getGauge(tokenId);
		require(owner == gauge);
		// this will revert if we're not the onwer of the staked token
		ICLGaugeAero(gauge).earned(address(this), tokenId);
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
	
	// update totalRewardBalance with current balance
	modifier updateReward() {
		_;
		_updateReward();
	}
}