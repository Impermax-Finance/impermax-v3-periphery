pragma solidity =0.5.16;
pragma experimental ABIEncoderV2;

import "../ImpermaxERC721.sol";
import "./interfaces/ISimpleUniswapOracle.sol";
import "./interfaces/IUniswapV2Pair.sol";
import "./interfaces/ITokenizedUniswapV2Position.sol";
import "../interfaces/IERC20.sol";
import "../interfaces/INFTLP.sol";
import "../libraries/Math.sol";

contract TokenizedUniswapV2Position is ITokenizedUniswapV2Position, INFTLP, ImpermaxERC721 {

    uint256 constant Q24 = 2**24;
    uint256 constant Q32 = 2**32;
    uint256 constant Q96 = 2**96;

	address public factory;
	address public simpleUniswapOracle;
	address public underlying;
	uint256 public totalBalance;
	address public token0;
	address public token1;
	
	mapping(uint256 => uint256) public liquidity;
	uint256 public positionLength;
	
	event Mint(address indexed to, uint256 mintAmount, uint256 newTokenId);
	event Redeem(address indexed to, uint256 redeemAmount, uint256 tokenId);
		
	// called once by the factory at the time of deployment
	function _initialize (
		address _underlying, 
		address _token0, 
		address _token1,
		address _simpleUniswapOracle
	) external {
		require(factory == address(0), "TokenizedUniswapV2Position: FACTORY_ALREADY_SET"); // sufficient check
		factory = msg.sender;
		_setName("Tokenized Uniswap V2", "NFT-UNI-V2");
		underlying = _underlying;
		token0 = _token0;
		token1 = _token1;
		simpleUniswapOracle = _simpleUniswapOracle;
	}
 
	/*** Position Math ***/
	
	function oraclePriceSqrtX96() public returns (uint256) {
		(uint256 twapPrice112x112,) = ISimpleUniswapOracle(simpleUniswapOracle).getResult(underlying);
		return Math.sqrt(twapPrice112x112.mul(Q32)).mul(Q24);
	}
	
	function _getAdjustFactor() internal view returns (uint256) {
		(uint112 reserve0, uint112 reserve1,) = IUniswapV2Pair(underlying).getReserves();
		uint256 collateralTotalSupply = IUniswapV2Pair(underlying).totalSupply();
		uint256 kSqrt = Math.sqrt(uint256(reserve0).mul(reserve1));
		return kSqrt.mul(1e18).div(collateralTotalSupply, "TokenizedUniswapV2Position: ZERO_COLLATERAL_TOTAL_SUPPLY");
	}
	
	function _getRealX(uint256 tokenId, uint256 priceSqrtX96, uint256 adjustFactor) internal view returns (uint256) {
		return liquidity[tokenId].mul(Q96).div(priceSqrtX96).mul(adjustFactor).div(1e18);
	}
	function _getRealY(uint256 tokenId, uint256 priceSqrtX96, uint256 adjustFactor) internal view returns (uint256) {
		return liquidity[tokenId].mul(priceSqrtX96).div(Q96).mul(adjustFactor).div(1e18);
	}
	
	function getPositionData(uint256 tokenId, uint256 safetyMarginSqrt) external	returns (
		uint256 priceSqrtX96,
		INFTLP.RealXYs memory realXYs
	) {
		priceSqrtX96 = oraclePriceSqrtX96();
		uint256 adjustFactor = _getAdjustFactor();
		uint256 currentPrice = priceSqrtX96;
		uint256 lowestPrice = priceSqrtX96.mul(1e18).div(safetyMarginSqrt);
		uint256 highestPrice = priceSqrtX96.mul(safetyMarginSqrt).div(1e18);
		realXYs.lowestPrice.realX = _getRealX(tokenId, lowestPrice, adjustFactor);
		realXYs.lowestPrice.realY = _getRealY(tokenId, lowestPrice, adjustFactor);
		realXYs.currentPrice.realX = _getRealX(tokenId, currentPrice, adjustFactor);
		realXYs.currentPrice.realY = _getRealY(tokenId, currentPrice, adjustFactor);
		realXYs.highestPrice.realX = _getRealX(tokenId, highestPrice, adjustFactor);
		realXYs.highestPrice.realY = _getRealY(tokenId, highestPrice, adjustFactor);
	}
 
	/*** Interactions ***/
	
	// this low-level function should be called from another contract
	function mint(address to) external nonReentrant update returns (uint256 newTokenId) {
		uint256 balance = IERC20(underlying).balanceOf(address(this));
		uint256 mintAmount = balance.sub(totalBalance);
		
		newTokenId = positionLength++;
		_mint(to, newTokenId);
		liquidity[newTokenId] = mintAmount;
		
		emit UpdatePositionLiquidity(newTokenId, mintAmount);
	}

	// this low-level function should be called from another contract
	function redeem(address to, uint256 tokenId) external nonReentrant update returns (uint256 redeemAmount) {
		_checkAuthorized(_requireOwned(tokenId), msg.sender, tokenId);
		
		redeemAmount = liquidity[tokenId];
		liquidity[tokenId] = 0;
		_burn(tokenId);
		_safeTransfer(to, redeemAmount);
		
		emit UpdatePositionLiquidity(tokenId, 0);
	}
	
	function split(uint256 tokenId, uint256 percentage) external nonReentrant returns (uint256 newTokenId) {
		require(percentage <= 1e18, "TokenizedUniswapV2Position: ABOVE_100_PERCENT");
		address owner = _requireOwned(tokenId);
		_checkAuthorized(owner, msg.sender, tokenId);
		_approve(address(0), tokenId, address(0)); // reset approval
		
		uint256 oldLiquidity = liquidity[tokenId];		
		uint256 newTokenLiquidity = uint256(oldLiquidity).mul(percentage).div(1e18);
		uint256 oldTokenLiquidity = oldLiquidity - newTokenLiquidity;
		liquidity[tokenId] = oldTokenLiquidity;
		newTokenId = positionLength++;
		_mint(owner, newTokenId);
		liquidity[newTokenId] = newTokenLiquidity;
		
		emit UpdatePositionLiquidity(tokenId, oldTokenLiquidity);
		emit UpdatePositionLiquidity(newTokenId, newTokenLiquidity);
	}
	
	function join(uint256 tokenId, uint256 tokenToJoin) external nonReentrant {
		_checkAuthorized(_requireOwned(tokenToJoin), msg.sender, tokenToJoin);
		_requireOwned(tokenId);
		require(tokenId != tokenToJoin, "TokenizedUniswapV3Position: SAME_ID");
		
		uint256 initialLiquidity = liquidity[tokenId];
		uint256 liquidityToAdd = liquidity[tokenToJoin];
		liquidity[tokenId] = initialLiquidity.add(liquidityToAdd);
		liquidity[tokenToJoin] = 0;
		_burn(tokenToJoin);
		
		emit UpdatePositionLiquidity(tokenId, initialLiquidity.add(liquidityToAdd));
		emit UpdatePositionLiquidity(tokenToJoin, 0);
	}
	
	/*** Utilities ***/

	// same safe transfer function used by UniSwapV2 (with fixed underlying)
	bytes4 private constant SELECTOR = bytes4(keccak256(bytes("transfer(address,uint256)")));
	function _safeTransfer(address to, uint256 amount) internal {
		(bool success, bytes memory data) = underlying.call(abi.encodeWithSelector(SELECTOR, to, amount));
		require(success && (data.length == 0 || abi.decode(data, (bool))), "TokenizedUniswapV2Position: TRANSFER_FAILED");
	}
	
	function _updateBalance() internal {
		totalBalance = IERC20(underlying).balanceOf(address(this));
	}
	
	// prevents a contract from calling itself, directly or indirectly.
	bool internal _notEntered = true;
	modifier nonReentrant() {
		require(_notEntered, "TokenizedUniswapV2Position: REENTERED");
		_notEntered = false;
		_;
		_notEntered = true;
	}
	
	// update totalBalance with current balance
	modifier update() {
		_;
		_updateBalance();
	}
}