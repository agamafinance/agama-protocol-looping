// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

/// @notice Treasury / ReserveFund inflow surface used by FeeCollector and
///         SettlementVault.
interface ITreasuryDeposit {
    function deposit(address token, uint256 amount) external;
}

/// @notice IERC4626 + protocol-specific extension used by SettlementVault and
///         the Treasury / ReserveFund auto-stake path.
interface IAgamaPool is IERC4626 {
    function depositOnBehalf(uint256 assets, address receiver) external returns (uint256 shares);
}

/// @notice IERC4626 + the SP's snapshot-vote surface + the V2 unstake
///         cooldown queue. ERC-4626 `redeem`/`withdraw` revert on the SP
///         implementation; exits flow through `requestUnstake` + `claim`.
interface IAgamaSP is IERC4626 {
    function getPastVotes(address account, uint256 timepoint) external view returns (uint256);
    function getPastTotalSupply(uint256 timepoint) external view returns (uint256);
    function requestUnstake(uint256 amount) external returns (uint256 requestId);
    function claim(uint256 requestId) external returns (uint256 assetsOut);
}
