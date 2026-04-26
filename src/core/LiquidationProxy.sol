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
/// @dev    Pure pass-through. Centralizing the manager-facing surface here
///         keeps the LP/SP contracts free of human role plumbing and lets us
///         swap the proxy out (governance op) without touching either pool.
contract LiquidationProxy is AccessControl {
    bytes32 public constant MANAGER_ROLE = keccak256("MANAGER_ROLE");

    AgamaLendingPool public immutable LP;
    AgamaStabilityPool public immutable SP;

    event ManagerSet(address indexed account, bool enabled);
    event LiquidationInitiated(address indexed adapter, address indexed user);
    event LiquidationFinalized(address indexed adapter, address indexed user);

    error AddressZero();

    constructor(AgamaLendingPool lp, AgamaStabilityPool sp, address admin) {
        if (address(lp) == address(0) || address(sp) == address(0) || admin == address(0)) revert AddressZero();
        LP = lp;
        SP = sp;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    /// @notice Phase 1: flag a position for liquidation; starts the grace period.
    function initiateLiquidation(address adapter, address user, bytes calldata data)
        external
        onlyRole(MANAGER_ROLE)
    {
        LP.initiateLiquidation(adapter, user, data);
        emit LiquidationInitiated(adapter, user);
    }

    /// @notice Phase 3: post-grace, drives the SP to absorb and the LP to
    ///         finalize. The SP routes seized RWA into the SettlementVault.
    function liquidateBorrower(
        address poolAdapter,
        address vaultAdapter,
        address user,
        bytes calldata data,
        uint256 minSharesOut
    ) external onlyRole(MANAGER_ROLE) {
        SP.liquidateBorrower(poolAdapter, vaultAdapter, user, data, minSharesOut);
        emit LiquidationFinalized(poolAdapter, user);
    }

    // ---- Manager registry ------------------------------------------------

    function setManager(address account, bool enabled) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (enabled) _grantRole(MANAGER_ROLE, account);
        else _revokeRole(MANAGER_ROLE, account);
        emit ManagerSet(account, enabled);
    }
}
