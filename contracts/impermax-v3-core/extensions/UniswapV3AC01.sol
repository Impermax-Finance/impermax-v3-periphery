pragma solidity =0.5.16;
pragma experimental ABIEncoderV2;

import "../interfaces/IERC20.sol";
import "../libraries/Math.sol";
import "../libraries/SafeMath.sol";
import "./interfaces/ITokenizedUniswapV3Factory.sol";
import "./interfaces/ITokenizedUniswapV3Position.sol";
import "./interfaces/IUniswapV3Factory.sol";
import "./interfaces/IUniswapV3Pool.sol";
import "./interfaces/IUniswapV3AC01.sol";
import "./libraries/TransferHelper.sol";
import "./libraries/LiquidityAmounts.sol";
import "./libraries/TickMath.sol";

contract UniswapV3AC01 is IUniswapV3AC01 {
	using SafeMath for uint256;
	using TickMath for int24;
	
	address public uniswapV3Factory;
	address public tokenizedUniswapV3Factory;
	address public reservesAdmin;
	address public reservesPendingAdmin;
	address public reservesManager;
	
	constructor(address _uniswapV3Factory, address _tokenizedUniswapV3Factory, address _reservesAdmin, address _reservesManager) public {
		uniswapV3Factory = _uniswapV3Factory;
		tokenizedUniswapV3Factory = _tokenizedUniswapV3Factory;
		reservesAdmin = _reservesAdmin;
		reservesManager = _reservesManager;
		emit NewReservesAdmin(address(0), _reservesAdmin);
		emit NewReservesManager(address(0), _reservesManager);
	}
	
	/*** Autocompounder ***/
	
	function _checkCaller() internal view returns (address token0, address token1) {
		token0 = ITokenizedUniswapV3Position(msg.sender).token0();
		token1 = ITokenizedUniswapV3Position(msg.sender).token1();
		require(
			ITokenizedUniswapV3Factory(tokenizedUniswapV3Factory).getNFTLP(token0, token1) == msg.sender,
			"UniswapV3AC01: UNAUTHORIZED_CALLER"
		);
	}
	
    uint constant Q96 = 2**96;
		
	uint256 public constant MAX_REINVEST_BOUNTY = 0.02e18; // 2%
	uint256 public constant MAX_BOUNTY_T = 7 * 24 * 60 * 60; // 1 week
	uint256 public constant PROTOCOL_SHARE = 0.5e18; // 50%
	
	mapping(address => mapping(uint256 => uint256)) internal lastReinvest;
	
	function _getBounty(address nftlp, uint256 tokenId) internal returns (uint256) {
		uint timeDelta = block.timestamp - lastReinvest[nftlp][tokenId];
		lastReinvest[nftlp][tokenId] = block.timestamp;
		return timeDelta > MAX_BOUNTY_T 
			? MAX_REINVEST_BOUNTY 
			: MAX_REINVEST_BOUNTY * timeDelta / MAX_BOUNTY_T;
	}
	
	function _getReinvestAmounts(
		uint256 liquidity,
		uint256 realX,
		uint256 realY,
		uint256 feeCollected0,
		uint256 feeCollected1
	) internal pure returns (uint256 newLiquidity, uint256 amount0, uint256 amount1) {
		if (realX == 0) {
			amount0 = 0;
			amount1 = feeCollected1;
			newLiquidity = liquidity.mul(amount1).div(realY);
		} 
		else if (realY == 0) {
			amount0 = feeCollected0;
			amount1 = 0;
			newLiquidity = liquidity.mul(amount0).div(realX);
		} else {
			uint256 ratioX = feeCollected0.mul(1e18).div(realX);
			uint256 ratioY = feeCollected1.mul(1e18).div(realY);
			if (ratioX < ratioY) {
				amount0 = feeCollected0;
				amount1 = feeCollected1.mul(ratioX).div(ratioY);
			} else {
				amount0 = feeCollected0.mul(ratioY).div(ratioX);
				amount1 = feeCollected1;
			}
			newLiquidity = Math.min(liquidity.mul(amount0).div(realX), liquidity.mul(amount1).div(realY));
		}
	}
	
	struct AutocompoundData {
		address pool;
		ITokenizedUniswapV3Position.Position position;
		uint256 tokenId;
		uint256 collect0; 
		uint256 collect1; 
		uint256 newLiquidity;
	}
		
	function getToCollect(
		ITokenizedUniswapV3Position.Position calldata position, 
		uint256 tokenId, 
		uint256 feeCollected0, 
		uint256 feeCollected1
	) external returns (uint256 collect0, uint256 collect1, bytes memory data) {
		_checkCaller();
	
		// 1. Initialize
		address pool = ITokenizedUniswapV3Position(msg.sender).getPool(position.fee);
		(uint160 priceSqrtX96,,,,,,) = IUniswapV3Pool(pool).slot0();
		uint256 reinvestBounty = _getBounty(msg.sender, tokenId);

		// 2. Read position proportion
		(uint256 realX, uint256 realY) = LiquidityAmounts.getAmountsForLiquidity(
			priceSqrtX96, 
			position.tickLower.getSqrtRatioAtTick(), 
			position.tickUpper.getSqrtRatioAtTick(), 
			position.liquidity
		);
		
		// 3. Calculate how much of the earned fee we can compound for each side
		uint256 newLiquidity;
		(newLiquidity, collect0, collect1) = _getReinvestAmounts(position.liquidity, realX, realY, feeCollected0, feeCollected1);
		newLiquidity = newLiquidity.mul(1e18 - reinvestBounty).div(1e18);
		
		data = abi.encode(AutocompoundData({
			pool: pool,
			position: position,
			tokenId: tokenId,
			collect0: collect0,
			collect1: collect1,
			newLiquidity: newLiquidity
		}));
	}
	
	function mintLiquidity(
		address bountyTo, 
		bytes calldata data
	) external returns (uint256 bounty0, uint256 bounty1) {
		(address token0, address token1) = _checkCaller();
		AutocompoundData memory d = abi.decode(data, (AutocompoundData));
		
		(uint256 amount0, uint256 amount1) = IUniswapV3Pool(d.pool).mint(msg.sender, d.position.tickLower, d.position.tickUpper, safe128(d.newLiquidity), abi.encode(d.position.fee, token0, token1));

		uint256 protocolShare = reservesManager != address(0) ? PROTOCOL_SHARE : 0;
		bounty0 = d.collect0.sub(amount0).mul(1e18 - protocolShare).div(1e18);
		bounty1 = d.collect1.sub(amount1).mul(1e18 - protocolShare).div(1e18);
		if (bounty0 > 0) TransferHelper.safeTransfer(token0, bountyTo, bounty0);
		if (bounty1 > 0) TransferHelper.safeTransfer(token1, bountyTo, bounty1);
	}
	
	function uniswapV3MintCallback(uint256 amount0Owed, uint256 amount1Owed, bytes calldata data) external {	
		(uint24 fee, address token0, address token1) = abi.decode(data, (uint24, address, address));
		require(
			IUniswapV3Factory(uniswapV3Factory).getPool(token0, token1, fee) == msg.sender,
			"UniswapV3AC01: UNAUTHORIZED_CALLER"
		);
		
		if (amount0Owed > 0) TransferHelper.safeTransfer(token0, msg.sender, amount0Owed);
		if (amount1Owed > 0) TransferHelper.safeTransfer(token1, msg.sender, amount1Owed);
	}
	
	/*** Reserves Manager ***/
	
	function _setReservesPendingAdmin(address newReservesPendingAdmin) external {
		require(msg.sender == reservesAdmin, "TokenizedUniswapV3Factory: UNAUTHORIZED");
		address oldReservesPendingAdmin = reservesPendingAdmin;
		reservesPendingAdmin = newReservesPendingAdmin;
		emit NewReservesPendingAdmin(oldReservesPendingAdmin, newReservesPendingAdmin);
	}

	function _acceptReservesAdmin() external {
		require(msg.sender == reservesPendingAdmin, "TokenizedUniswapV3Factory: UNAUTHORIZED");
		address oldReservesAdmin = reservesAdmin;
		address oldReservesPendingAdmin = reservesPendingAdmin;
		reservesAdmin = reservesPendingAdmin;
		reservesPendingAdmin = address(0);
		emit NewReservesAdmin(oldReservesAdmin, reservesAdmin);
		emit NewReservesPendingAdmin(oldReservesPendingAdmin, address(0));
	}

	function _setReservesManager(address newReservesManager) external {
		require(msg.sender == reservesAdmin, "TokenizedUniswapV3Factory: UNAUTHORIZED");
		address oldReservesManager = reservesManager;
		reservesManager = newReservesManager;
		emit NewReservesManager(oldReservesManager, newReservesManager);
	}
	
	function claimToken(address token) public {
		uint256 amount = IERC20(token).balanceOf(address(this));
		if (amount > 0) TransferHelper.safeTransfer(token, reservesManager, amount);
	}
	function claimTokens(address[] calldata tokens) external {
		for (uint i = 0; i < tokens.length; i++) {
			claimToken(tokens[i]);
		}
	}
	
	/*** Utilities ***/

    function safe128(uint n) internal pure returns (uint128) {
        require(n < 2**128, "Impermax: SAFE128");
        return uint128(n);
    }
}