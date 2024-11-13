pragma solidity >=0.5.0;

interface IImpermaxCallee {
    function impermaxV3Borrow(address sender, uint256 tokenId, uint borrowAmount, bytes calldata data) external;
    function impermaxV3Redeem(address sender, uint256 tokenId, uint256 redeemTokenId, bytes calldata data) external;
}