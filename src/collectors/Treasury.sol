// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

/// @notice Minimal LP / SP surfaces the Treasury needs for auto-staking and
///         orderly withdrawals.
interface IPoolForTreasury is IERC4626 {
    // marker — IERC4626 already has deposit/redeem/asset.
}

interface ISPForTreasury is IERC4626 {
    function requestWithdraw(uint256 amount) external;
}

/// @title AgamaTreasury
/// @notice Holds protocol-level reserves. In V1 testnet, every USDr inflow is
///         immediately deposited into the LendingPool and staked into the
///         StabilityPool — so the Treasury earns alongside other agaSP
///         holders pro-rata, increasing SP depth without paying out as
///         individual rewards. The auto-stake hook is gated by
///         `autoStakeEnabled`, which can be flipped (in demo mode) to a
///         "hold-liquid" V2 mainnet posture for paying ops/audits.
/// @dev    Withdrawals from the SP go through the standard SP timelock
///         (`requestWithdraw` → `redeem`).
contract AgamaTreasury is AccessControl {
    using SafeERC20 for IERC20;

    bytes32 public constant DEPOSITOR_ROLE = keccak256("DEPOSITOR_ROLE");
    bytes32 public constant MANAGER_ROLE = keccak256("MANAGER_ROLE");

    IPoolForTreasury public immutable LP;
    ISPForTreasury public immutable SP;
    IERC20 public immutable USDR;

    /// @notice Demo-mode immutable. When false (mainnet), `setAutoStakeEnabled`
    ///         reverts so the V1 posture is locked at deploy.
    bool public immutable isDemoMode;

    /// @notice When true, every `deposit(USDR, …)` triggers an
    ///         LP-deposit-then-SP-stake. V1 testnet default = true.
    bool public autoStakeEnabled;

    mapping(address token => bool) public supportedTokens;

    event Deposited(address indexed token, address indexed from, uint256 amount);
    event AutoStaked(uint256 usdrIn, uint256 agTokenMinted, uint256 agaSPMinted);
    event WithdrawRequestedFromSP(uint256 agaSPAmount);
    event WithdrawCompleted(address indexed to, uint256 usdrAmount);
    event StakeIdleProcessed(uint256 amount);
    event SupportedTokenSet(address indexed token, bool supported);
    event AutoStakeFlagSet(bool enabled);

    error TokenNotSupported();
    error AmountZero();
    error OnlyDemoMode();

    constructor(
        address admin,
        IPoolForTreasury lp,
        ISPForTreasury sp,
        IERC20 usdr,
        bool _isDemoMode
    ) {
        LP = lp;
        SP = sp;
        USDR = usdr;
        isDemoMode = _isDemoMode;
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
        USDR.approve(address(LP), amount);
        uint256 agShares = LP.deposit(amount, address(this));
        IERC20(address(LP)).approve(address(SP), agShares);
        uint256 agaSPShares = SP.deposit(agShares, address(this));
        emit AutoStaked(amount, agShares, agaSPShares);
    }

    // ---- Outflows --------------------------------------------------------

    /// @notice Manager queues a redeem ticket on the SP (subject to SP's own
    ///         30-min timelock + 2-day window).
    function requestWithdrawFromSP(uint256 agaSPAmount) external onlyRole(MANAGER_ROLE) {
        SP.requestWithdraw(agaSPAmount);
        emit WithdrawRequestedFromSP(agaSPAmount);
    }

    /// @notice Manager redeems agaSP → agTOKEN, then unwraps agTOKEN → USDr,
    ///         and forwards `amount` USDr to `to`. Subject to the SP timelock
    ///         queued via `requestWithdrawFromSP`.
    function withdrawToAddress(uint256 agaSPAmount, address to) external onlyRole(MANAGER_ROLE) {
        // SP.redeem returns agTOKEN amount; unwrap that into USDr via LP.redeem.
        uint256 agShares = SP.redeem(agaSPAmount, address(this), address(this));
        uint256 usdrOut = LP.redeem(agShares, to, address(this));
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
    ///         postures. Demo-mode-gated for V1; on mainnet the posture is
    ///         locked at constructor default.
    function setAutoStakeEnabled(bool enabled) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (!isDemoMode) revert OnlyDemoMode();
        autoStakeEnabled = enabled;
        emit AutoStakeFlagSet(enabled);
    }
}
