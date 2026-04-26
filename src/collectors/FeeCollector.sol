// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

interface ITreasuryDeposit {
    function deposit(address token, uint256 amount) external;
}

/// @title AgamaFeeCollector
/// @notice Routes every protocol fee (origination, vault opening, future
///         reserve-factor accrual) to the Treasury. V1 policy: 100% to
///         Treasury, no split to ReserveFund — the RF is a pro-rata SP
///         staker like everyone else, and Treasury can top it up via
///         governance if needed.
/// @dev    NON-STANDARD vs the doc's Aave-style pull-based design (which
///         used `accumulated[feeType][token]` + manual `distributeFees`).
///         For V1 simplicity we push immediately: every `collectFee` call
///         forwards to Treasury in the same transaction. Per-feeType events
///         still feed the off-chain dashboard.
contract AgamaFeeCollector is AccessControl {
    using SafeERC20 for IERC20;

    bytes32 public constant POOL_ROLE = keccak256("POOL_ROLE");

    bytes32 public constant FEE_ORIGINATION = keccak256("FEE_ORIGINATION");
    bytes32 public constant FEE_VAULT_OPENING = keccak256("FEE_VAULT_OPENING");
    bytes32 public constant FEE_DEPOSIT = keccak256("FEE_DEPOSIT");
    bytes32 public constant FEE_PROTOCOL_REVENUE = keccak256("FEE_PROTOCOL_REVENUE");

    ITreasuryDeposit public treasury;

    /// @notice Lifetime totals (cumulative) per fee type per token. Drives
    ///         off-chain dashboards.
    mapping(bytes32 feeType => mapping(address token => uint256)) public lifetimeFees;

    event FeeCollected(address indexed token, address indexed from, uint256 amount, bytes32 indexed feeType);
    event FeeForwarded(address indexed token, uint256 amount, bytes32 indexed feeType);
    event TreasuryUpdated(address indexed treasury);

    error AmountZero();
    error TreasuryNotSet();

    constructor(address admin, ITreasuryDeposit _treasury) {
        treasury = _treasury;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    /// @notice Pull `amount` of `token` from `from` (caller's authority is
    ///         POOL_ROLE) and forward it to the Treasury in the same call.
    /// @dev    `from` must have approved this contract for `amount`.
    function collectFee(address token, address from, uint256 amount, bytes32 feeType)
        external
        onlyRole(POOL_ROLE)
    {
        if (amount == 0) revert AmountZero();
        if (address(treasury) == address(0)) revert TreasuryNotSet();
        IERC20(token).safeTransferFrom(from, address(this), amount);
        lifetimeFees[feeType][token] += amount;
        emit FeeCollected(token, from, amount, feeType);
        _forward(token, amount, feeType);
    }

    /// @notice Push entrypoint when the LP transfers fee tokens directly here
    ///         (`safeTransfer` instead of `transferFrom`). The LP can choose
    ///         either pattern. This sweeps any idle balance to the Treasury
    ///         and tags it under `feeType`.
    function settle(address token, bytes32 feeType) external onlyRole(POOL_ROLE) {
        uint256 bal = IERC20(token).balanceOf(address(this));
        if (bal == 0) return;
        lifetimeFees[feeType][token] += bal;
        _forward(token, bal, feeType);
    }

    function _forward(address token, uint256 amount, bytes32 feeType) internal {
        IERC20(token).approve(address(treasury), amount);
        treasury.deposit(token, amount);
        emit FeeForwarded(token, amount, feeType);
    }

    // ---- Admin -----------------------------------------------------------

    function setTreasury(ITreasuryDeposit _treasury) external onlyRole(DEFAULT_ADMIN_ROLE) {
        treasury = _treasury;
        emit TreasuryUpdated(address(_treasury));
    }

    function grantPool(address pool) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _grantRole(POOL_ROLE, pool);
    }
}
