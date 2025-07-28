pragma solidity =0.5.16;
pragma experimental ABIEncoderV2;

import "./interfaces/IERC20.sol";
import "./impermax-v3-core/extensions/interfaces/INonfungiblePositionManagerAero.sol";

contract NextAeroIdGetter {
    INonfungiblePositionManagerAero public nfpManager;
    address public WETH;
    address public USDC;

    constructor(address _nfpManager, address _weth, address _usdc)  public {
        nfpManager = INonfungiblePositionManagerAero(_nfpManager);
        WETH = _weth;
        USDC = _usdc;
        IERC20(WETH).approve(_nfpManager, uint(-1));
    }

    function mintDummy() public returns (uint256 tokenId, uint128 liquidity) {
        (address token0, address token1) = WETH < USDC ? (WETH, USDC) : (USDC, WETH);
        (uint amount0, uint amount1) = WETH < USDC ? (100, 0) : (0, 100);
        (int24 tickLower, int24 tickUpper) = WETH < USDC ? (int24(400000), int24(400100)) : (-400100, -400000);
        (tokenId,liquidity,,) = nfpManager.mint(INonfungiblePositionManagerAero.MintParams({
            token0: token0,
            token1: token1,
            tickSpacing: 100,
            tickLower: tickLower,
            tickUpper: tickUpper,
            amount0Desired: amount0,
            amount1Desired: amount1,
            amount0Min: 0,
            amount1Min: 0,
            recipient: address(this),
            deadline: uint(-1),
            sqrtPriceX96: 0
        }));
    }

    function mintDummyAndBurn() public returns (uint256 tokenId, uint128 liquidity) {
        (tokenId,liquidity) = mintDummy();
        nfpManager.decreaseLiquidity(INonfungiblePositionManagerAero.DecreaseLiquidityParams({
            tokenId: tokenId,
            liquidity: liquidity,
            amount0Min: 0,
            amount1Min: 0,
            deadline: uint(-1)
        }));
        nfpManager.collect(INonfungiblePositionManagerAero.CollectParams({
            tokenId: tokenId,
            recipient: address(this),
            amount0Max: uint128(-1),
            amount1Max: uint128(-1)
        }));
        nfpManager.burn(tokenId);
    }
}