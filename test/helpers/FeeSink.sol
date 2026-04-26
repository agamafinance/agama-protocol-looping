// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice Minimal `IFeeCollector` stand-in for tests that don't exercise the
///         real Treasury / FeeCollector pipeline. Implements the
///         `collectFee(token, from, amount, feeType)` ABI by pulling the
///         tokens and holding them. Tests assert against this contract's
///         `IERC20.balanceOf` to confirm fees were routed correctly.
contract FeeSink {
    using SafeERC20 for IERC20;

    event FeeReceived(address indexed token, address indexed from, uint256 amount, bytes32 indexed feeType);

    function collectFee(address token, address from, uint256 amount, bytes32 feeType) external {
        IERC20(token).safeTransferFrom(from, address(this), amount);
        emit FeeReceived(token, from, amount, feeType);
    }
}
