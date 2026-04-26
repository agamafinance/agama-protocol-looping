// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title MockOracle
/// @notice Pure spot price feed for AMFI/USD-at-par. The yield-bearing nature
///         of AMFI is modeled inside MockAMFI via `pricePerShare()`; this
///         oracle is the USD-per-par-share component (think BRL/USD FX times
///         the parity assumption). For the demo crash, the owner sets a new
///         price and `lastUpdate` is bumped so adapters can enforce staleness.
contract MockOracle is Ownable {
    uint256 public constant PRICE_SCALE = 1e18;

    uint256 public price;
    uint256 public lastUpdate;

    event PriceSet(uint256 newPrice, uint256 timestamp);

    error ZeroPrice();

    constructor(address admin, uint256 initialPrice) Ownable(admin) {
        if (initialPrice == 0) revert ZeroPrice();
        price = initialPrice;
        lastUpdate = block.timestamp;
    }

    /// @notice Test-only override of `lastUpdate` so we can exercise the
    ///         per-adapter staleness circuit breaker without waiting 24h on
    ///         a real chain. Has no effect on `price`.
    function setLastUpdate(uint256 ts) external onlyOwner {
        lastUpdate = ts;
    }

    function setPrice(uint256 newPrice) external onlyOwner {
        if (newPrice == 0) revert ZeroPrice();
        price = newPrice;
        lastUpdate = block.timestamp;
        emit PriceSet(newPrice, block.timestamp);
    }

    function getPrice() external view returns (uint256) {
        return price;
    }
}
