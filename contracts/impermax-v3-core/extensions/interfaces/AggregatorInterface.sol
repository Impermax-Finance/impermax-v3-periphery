pragma solidity >=0.5.0;

interface AggregatorInterface {
  function decimals() external view returns (uint8);
  function latestAnswer() external view returns (int256);
  function latestTimestamp() external view returns (uint256);
  function latestRound() external view returns (uint256);
  function description() external view returns (string memory);
}
 