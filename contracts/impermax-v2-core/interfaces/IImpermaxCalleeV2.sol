pragma solidity >=0.5.0;

interface IImpermaxCalleeV2 {
    function impermaxBorrow(address sender, address borrower, uint borrowAmount, bytes calldata data) external;
    function impermaxRedeem(address sender, uint redeemAmount, bytes calldata data) external;
}