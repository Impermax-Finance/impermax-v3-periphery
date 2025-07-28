pragma solidity >=0.5.0;

interface INftlpCallee {
    function nftlpMint(address sender, uint256 tokenId, bytes calldata data) external;
}