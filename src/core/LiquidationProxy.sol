// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

import {AgamaLendingPool} from "./LendingPool.sol";
import {AgamaStabilityPool} from "./StabilityPool.sol";

/// @title LiquidationProxy
/// @notice Single entry point for the human / keeper-bot manager(s) to drive
///         liquidations. Holds LIQUIDATION_PROXY_ROLE on the LendingPool and
///         MANAGER_ROLE on the StabilityPool. Real human managers hold this
///         contract's MANAGER_ROLE.
/// @dev    V1: liquidations are INSTANT — single `liquidate` call when HF < 1.
///         No initiate/grace/finalize staging.
contract LiquidationProxy is AccessControl {
    bytes32 public constant MANAGER_ROLE = keccak256("MANAGER_ROLE");

    AgamaLendingPool public immutable LP;
    AgamaStabilityPool public immutable SP;

    event ManagerSet(address indexed account, bool enabled);
    event Liquidated(address indexed adapter, address indexed user);

    error AddressZero();

    constructor(AgamaLendingPool lp, AgamaStabilityPool sp, address admin) {
        if (address(lp) == address(0) || address(sp) == address(0) || admin == address(0)) {
            revert AddressZero();
        }
        LP = lp;
        SP = sp;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    /// @notice Liquidate a borrower whose HF is below 1. Drives the SP to
    ///         absorb the debt and seize the collateral via `LP.liquidate`,
    ///         then routes the seized RWA into the SettlementVault for
    ///         off-chain redemption.
    function liquidate(
        address poolAdapter,
        address vaultAdapter,
        address user,
        bytes calldata data,
        uint256 minSharesOut
    ) external onlyRole(MANAGER_ROLE) {
        SP.liquidateBorrower(poolAdapter, vaultAdapter, user, data, minSharesOut);
        emit Liquidated(poolAdapter, user);
    }

    // ---- Manager registry ------------------------------------------------

    function setManager(address account, bool enabled) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (enabled) _grantRole(MANAGER_ROLE, account);
        else _revokeRole(MANAGER_ROLE, account);
        emit ManagerSet(account, enabled);
    }
}
