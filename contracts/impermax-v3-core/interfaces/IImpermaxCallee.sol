pragma solidity >=0.5.0;

interface IImpermaxCallee {
    function impermaxBorrow(address sender, uint256 tokenId, uint borrowAmount, bytes calldata data) external;
    function impermaxRedeem(address sender, uint256 tokenId, uint256 redeemTokenId, bytes calldata data) external;
}