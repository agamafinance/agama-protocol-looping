// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/// @title IPricedToken
/// @notice Yield-bearing ERC20 with a `pricePerShare()` accessor. Any RWA
///         tranche token used as collateral must implement this surface so
///         the adapter can value the position as
///             balance × pricePerShare() × oracleSpotUsd / 1e36.
/// @dev    `pricePerShare()` returns the par value in 1e18-fixed (so 1.16e18
///         means 1.16x par). Both MockAMFI (legacy single-tranche) and
///         MockTrancheToken (multi-tranche) implement this interface.
interface IPricedToken is IERC20Metadata {
    function pricePerShare() external view returns (uint256);
}
