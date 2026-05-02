// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

import {IAgamaPool, IAgamaSP} from "../interfaces/IAgamaCollectors.sol";

/// @title AgamaTreasury
/// @notice Holds protocol-level reserves. In V1, every USDr inflow is
///         immediately deposited into the LendingPool and staked into the
///         StabilityPool — so the Treasury earns alongside other agaSP
///         holders pro-rata, increasing SP depth without paying out as
///         individual rewards. The auto-stake hook is gated by
///         `autoStakeEnabled`, which governance can flip to a hold-liquid
///         posture (e.g. for paying ops/audits) without code changes.
/// @dev    Withdrawals from the SP are direct ERC-4626 redeems (no timelock,
///         per the V1 D2 refactor).
contract AgamaTreasury is AccessControl {
    using SafeERC20 for IERC20;

    bytes32 public constant DEPOSITOR_ROLE = keccak256("DEPOSITOR_ROLE");
    bytes32 public constant MANAGER_ROLE = keccak256("MANAGER_ROLE");

    IAgamaPool public immutable LP;
    IAgamaSP public immutable SP;
    IERC20 public immutable USDR;

    /// @notice When true, every `deposit(USDR, …)` triggers an
    ///         LP-deposit-then-SP-stake. V1 default = true. Governance can
    ///         flip to false to switch to a hold-liquid posture (e.g. for
    ///         paying ops/audits in V2).
    bool public autoStakeEnabled;

    mapping(address token => bool) public supportedTokens;

    event Deposited(address indexed token, address indexed from, uint256 amount);
    event AutoStaked(uint256 usdrIn, uint256 agTokenMinted, uint256 agaSPMinted);
    event WithdrawnFromSP(address indexed to, uint256 requestId, uint256 agYLDOut);
    event WithdrawCompleted(address indexed to, uint256 usdrAmount);
    event StakeIdleProcessed(uint256 amount);
    event SupportedTokenSet(address indexed token, bool supported);
    event AutoStakeFlagSet(bool enabled);

    error TokenNotSupported();
    error AmountZero();

    constructor(address admin, IAgamaPool lp, IAgamaSP sp, IERC20 usdr) {
        LP = lp;
        SP = sp;
        USDR = usdr;
        autoStakeEnabled = true;

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(MANAGER_ROLE, admin);

        supportedTokens[address(usdr)] = true;
        supportedTokens[address(lp)] = true; // agTOKEN
    }

    // ---- Inflows ---------------------------------------------------------

    /// @notice Push entrypoint for FeeCollector / SettlementVault. Pull tokens
    ///         from `msg.sender` (caller approved) using balance-delta
    ///         accounting; auto-stake if USDr.
    function deposit(address token, uint256 amount) external onlyRole(DEPOSITOR_ROLE) {
        if (!supportedTokens[token]) revert TokenNotSupported();
        if (amount == 0) revert AmountZero();

        uint256 before = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = IERC20(token).balanceOf(address(this)) - before;
        emit Deposited(token, msg.sender, received);

        if (autoStakeEnabled && token == address(USDR) && received > 0) {
            _autoStake(received);
        }
    }

    /// @notice Catch-all: stakes any USDr balance held idle on this contract
    ///         (e.g. arrived via direct transfer outside `deposit`). Anyone
    ///         can call.
    function stakeIdleUsdr() external returns (uint256 staked) {
        if (!autoStakeEnabled) return 0;
        staked = USDR.balanceOf(address(this));
        if (staked > 0) _autoStake(staked);
        emit StakeIdleProcessed(staked);
    }

    function _autoStake(uint256 amount) internal {
        SafeERC20.forceApprove(USDR, address(LP), amount);
        uint256 agShares = LP.deposit(amount, address(this));
        SafeERC20.forceApprove(IERC20(address(LP)), address(SP), agShares);
        uint256 agaSPShares = SP.deposit(agShares, address(this));
        emit AutoStaked(amount, agShares, agaSPShares);
    }

    // ---- Outflows --------------------------------------------------------

    /// @notice Queue an unstake of `sagYLDAmount` Treasury sagYLD shares.
    ///         The Treasury must wait the SP cooldown (default 7 days,
    ///         possibly extended by an in-flight settlement) before
    ///         calling `claimUnstake`. Subject to the same backstop
    ///         semantics as user stakers — the Treasury absorbs
    ///         liquidations during the cooldown.
    function requestUnstakeFromSP(uint256 sagYLDAmount)
        external
        onlyRole(MANAGER_ROLE)
        returns (uint256 requestId)
    {
        requestId = SP.requestUnstake(sagYLDAmount);
    }

    /// @notice Claim a previously queued unstake. Pulls agYLD from the SP
    ///         and forwards to `recipient`. If `recipient == address(this)`
    ///         the agYLD stays on the Treasury (e.g. for re-deployment).
    function claimUnstakeFromSP(uint256 requestId, address recipient)
        external
        onlyRole(MANAGER_ROLE)
        returns (uint256 agYLDOut)
    {
        agYLDOut = SP.claim(requestId);
        if (recipient != address(this) && agYLDOut > 0) {
            IERC20(address(LP)).safeTransfer(recipient, agYLDOut);
        }
        emit WithdrawnFromSP(recipient, requestId, agYLDOut);
    }

    /// @notice Full exit: claim the cooldown ticket then unwrap the agYLD
    ///         into USDr and forward to `to`. Manager must already have
    ///         called `requestUnstakeFromSP` and waited out the cooldown.
    function claimAndUnwrapToAddress(uint256 requestId, address to) external onlyRole(MANAGER_ROLE) {
        uint256 agYLDOut = SP.claim(requestId);
        uint256 usdrOut = 0;
        if (agYLDOut > 0) {
            usdrOut = LP.redeem(agYLDOut, to, address(this));
        }
        emit WithdrawCompleted(to, usdrOut);
    }

    // ---- Admin -----------------------------------------------------------

    function setSupportedToken(address token, bool supported) external onlyRole(DEFAULT_ADMIN_ROLE) {
        supportedTokens[token] = supported;
        emit SupportedTokenSet(token, supported);
    }

    function grantDepositor(address account) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _grantRole(DEPOSITOR_ROLE, account);
    }

    /// @notice Switch between V1 (auto-stake) and V2 (hold-liquid for ops)
    ///         postures. Governance-controlled, no time-lock at the contract
    ///         level — operate it through the multisig / TimelockController.
    function setAutoStakeEnabled(bool enabled) external onlyRole(DEFAULT_ADMIN_ROLE) {
        autoStakeEnabled = enabled;
        emit AutoStakeFlagSet(enabled);
    }
}
