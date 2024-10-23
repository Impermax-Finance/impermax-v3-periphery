pragma solidity >=0.5.0;

interface IBorrowTracker {
	function trackBorrow(uint256 tokenId, uint borrowBalance, uint borrowIndex) external;
}