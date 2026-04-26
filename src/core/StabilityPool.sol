// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Votes} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {Nonces} from "@openzeppelin/contracts/utils/Nonces.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {ISettlementVault} from "../interfaces/ISettlementVault.sol";
import {IAssetAdapter} from "../adapters/IAssetAdapter.sol";

interface ILendingPoolFinalize {
    function supportedAdapter(address adapter) external view returns (bool);
    function finalizeLiquidation(address adapter, address user, bytes calldata data)
        external
        returns (uint256 absorbedAssets, uint256 badDebt);
}

/// @title AgamaStabilityPool
/// @notice Liquidation backstop and secondary lender venue. ERC-4626 vault on
///         agTOKEN (the LendingPool itself); shares are agaSP. Soulbound: only
///         mint/burn move balances; transfers revert. ERC20Votes-enabled so
///         the SettlementVault's emergency in-kind distribution can snapshot
///         per-holder balances at queue time.
/// @dev    `totalAssets()` includes the SettlementVault's pending pegGap so
///         the agaSP share price stays smooth across the ~15-day redemption
///         window. Liquidation flow (`liquidateBorrower`) lands in S3 — for
///         now it is a hard stub, but the deposit / redeem / timelock surface
///         is fully wired.
contract AgamaStabilityPool is ERC4626, ERC20Votes, AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ---- Roles -----------------------------------------------------------

    bytes32 public constant GOVERNOR_ROLE = keccak256("GOVERNOR_ROLE");
    bytes32 public constant MANAGER_ROLE = keccak256("MANAGER_ROLE");
    bytes32 public constant LIQUIDATION_PROXY_ROLE = keccak256("LIQUIDATION_PROXY_ROLE");

    // ---- Immutables ------------------------------------------------------

    /// @notice True only on testnet. When false, all timing-cheat setters revert.
    bool public immutable isDemoMode;

    // ---- Timing parameters (production defaults; demo-tunable) ----------

    /// @notice Time the user must wait between `requestWithdraw` and `redeem`.
    uint256 public withdrawTimelockDuration; // production: 30 minutes
    /// @notice Window after `readyAt` during which `redeem` must be executed.
    uint256 public withdrawTimelockDelay;    // production: 2 days

    // ---- State -----------------------------------------------------------

    /// @notice Address of the SettlementVault (S5). Until set, `totalAssets`
    ///         only counts the raw agTOKEN balance.
    address public settlementVault;

    /// @dev Block number of the most-recent deposit per user. Used to block
    ///      same-block deposit/withdraw flash-loan-style griefing.
    mapping(address => uint256) public depositBlock;

    /// @param amount           agaSP shares queued for redemption.
    /// @param balanceAtRequest Holder's balance at request time (cap on cheat).
    /// @param readyAt          Earliest timestamp redeem may execute.
    /// @param expireAt         Latest timestamp redeem may execute.
    struct WithdrawTicket {
        uint256 amount;
        uint256 balanceAtRequest;
        uint256 readyAt;
        uint256 expireAt;
    }

    mapping(address => WithdrawTicket) public withdrawTimelock;

    // ---- Events ----------------------------------------------------------

    event WithdrawQueued(address indexed user, uint256 amount, uint256 readyAt);
    event WithdrawCancelled(address indexed user);
    event WithdrawExecuted(address indexed user, uint256 amount);
    event SettlementVaultSet(address indexed vault);
    event TimelockParamsSet(uint256 duration, uint256 delay);
    event BorrowerLiquidated(
        address indexed user, address indexed rwaToken, bytes data, uint256 absorbedAssets, uint256 seized
    );

    // ---- Errors ----------------------------------------------------------

    error NonTransferable();
    error AmountZero();
    error TimelockDisabled();
    error CannotDepositAndWithdrawSameBlock();
    error NoPendingWithdraw();
    error WithdrawTimelockNotReady();
    error WithdrawTimelockExpired();
    error WithdrawAmountMismatch();
    error WithdrawAmountTooHigh();
    error OnlyDemoMode();
    error UnsupportedAdapterOnSP();
    error InvalidLiquidationData();
    error NoCollateralSeized();
    error SettlementVaultNotSet();

    // ---- Construction ----------------------------------------------------

    constructor(IERC20 agToken, address admin, bool _isDemoMode)
        ERC20("Agama Stability Pool", "agaSP")
        EIP712("Agama Stability Pool", "1")
        ERC4626(agToken)
    {
        isDemoMode = _isDemoMode;
        // Production timing defaults — locked unless `isDemoMode == true`.
        withdrawTimelockDuration = 30 minutes;
        withdrawTimelockDelay = 2 days;

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(GOVERNOR_ROLE, admin);
    }

    // ---- ERC4626 surface --------------------------------------------------

    /// @notice Total assets backing agaSP: SP's agTOKEN balance + USDr-equivalent
    ///         of pending SettlementVault redemptions, expressed in agTOKEN units
    ///         via the LendingPool's current share price.
    function totalAssets() public view override returns (uint256) {
        uint256 raw = IERC20(asset()).balanceOf(address(this));
        address sv = settlementVault;
        if (sv == address(0)) return raw;
        uint256 pegGapUsdr = ISettlementVault(sv).pegGapPendingForSP();
        if (pegGapUsdr == 0) return raw;
        // The asset() IS the LendingPool — call convertToShares directly on it.
        uint256 pegGapShares = IERC4626(asset()).convertToShares(pegGapUsdr);
        return raw + pegGapShares;
    }

    /// @dev Records `depositBlock[receiver]` and clears any pending withdraw
    ///      ticket on every fresh deposit (per docs).
    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override {
        if (assets == 0) revert AmountZero();
        super._deposit(caller, receiver, assets, shares);
        depositBlock[receiver] = block.number;
        delete withdrawTimelock[receiver];
        // Auto-self-delegate so per-account historical votes are queryable
        // for the SettlementVault's emergencyDistributeInKind path.
        if (delegates(receiver) == address(0)) _delegate(receiver, receiver);
    }

    /// @dev Both `withdraw` and `redeem` route through this. The two-step
    ///      timelock lives here.
    function _withdraw(address caller, address receiver, address owner, uint256 assets, uint256 shares)
        internal
        override
    {
        if (depositBlock[owner] == block.number) revert CannotDepositAndWithdrawSameBlock();

        WithdrawTicket memory tl = withdrawTimelock[owner];
        if (tl.amount == 0) revert NoPendingWithdraw();
        if (block.timestamp < tl.readyAt) revert WithdrawTimelockNotReady();
        if (block.timestamp > tl.expireAt) revert WithdrawTimelockExpired();
        if (shares > tl.amount) revert WithdrawAmountTooHigh();

        // Cap share count by both ticket and current balance (handles upstream
        // share appreciation due to liquidation events post-request).
        uint256 ownerBal = balanceOf(owner);
        if (shares > ownerBal) revert WithdrawAmountTooHigh();
        // Also cap by the ticket's balance-at-request (paranoia).
        if (tl.balanceAtRequest != 0 && shares > tl.balanceAtRequest) revert WithdrawAmountTooHigh();

        delete withdrawTimelock[owner];
        super._withdraw(caller, receiver, owner, assets, shares);
        emit WithdrawExecuted(owner, shares);
    }

    // ---- Two-step withdraw ----------------------------------------------

    /// @notice Queue a redeem of `amount` agaSP. Pass 0 to cancel any pending
    ///         ticket. Records balance-at-request for the cap check.
    function requestWithdraw(uint256 amount) external {
        if (withdrawTimelockDuration == 0) revert TimelockDisabled();
        if (amount == 0) {
            delete withdrawTimelock[msg.sender];
            emit WithdrawCancelled(msg.sender);
            return;
        }
        WithdrawTicket memory tl = WithdrawTicket({
            amount: amount,
            balanceAtRequest: balanceOf(msg.sender),
            readyAt: block.timestamp + withdrawTimelockDuration,
            expireAt: block.timestamp + withdrawTimelockDuration + withdrawTimelockDelay
        });
        withdrawTimelock[msg.sender] = tl;
        emit WithdrawQueued(msg.sender, amount, tl.readyAt);
    }

    // ---- Liquidation entrypoint -----------------------------------------

    /// @notice Drives a liquidation post-grace-period. Pulls Alice's debt
    ///         absorption + RWA seizure via `LP.finalizeLiquidation`, then
    ///         routes the seized RWA into the SettlementVault for off-chain
    ///         redemption. Caller is the LiquidationProxy (which holds the
    ///         MANAGER_ROLE on this contract).
    function liquidateBorrower(
        address poolAdapter,
        address vaultAdapter,
        address user,
        bytes calldata data,
        uint256 minSharesOut
    ) external nonReentrant onlyRole(MANAGER_ROLE) {
        ILendingPoolFinalize lp = ILendingPoolFinalize(asset());
        if (!lp.supportedAdapter(poolAdapter)) revert UnsupportedAdapterOnSP();
        if (!IAssetAdapter(poolAdapter).validateLiquidationData(user, data)) revert InvalidLiquidationData();

        IERC20 rwa = IERC20(IAssetAdapter(poolAdapter).getAssetToken());
        uint256 preBalance = rwa.balanceOf(address(this));

        (uint256 absorbedAssets,) = lp.finalizeLiquidation(poolAdapter, user, data);

        uint256 seized = rwa.balanceOf(address(this)) - preBalance;
        if (seized == 0) revert NoCollateralSeized();

        address sv = settlementVault;
        if (sv == address(0)) revert SettlementVaultNotSet();
        rwa.safeTransfer(sv, seized);
        ISettlementVault(sv).handleSeizure(address(rwa), vaultAdapter, data, seized, absorbedAssets, minSharesOut);

        emit BorrowerLiquidated(user, address(rwa), data, absorbedAssets, seized);
    }

    // ---- Admin -----------------------------------------------------------

    function setSettlementVault(address vault) external onlyRole(GOVERNOR_ROLE) {
        settlementVault = vault;
        emit SettlementVaultSet(vault);
    }

    function setManager(address account, bool enabled) external onlyRole(GOVERNOR_ROLE) {
        if (enabled) _grantRole(MANAGER_ROLE, account);
        else _revokeRole(MANAGER_ROLE, account);
    }

    /// @notice Demo-only: shorten the timelock for live demos. Locked on mainnet.
    function setWithdrawTimelockDuration(uint256 secs) external onlyRole(GOVERNOR_ROLE) {
        if (!isDemoMode) revert OnlyDemoMode();
        withdrawTimelockDuration = secs;
        emit TimelockParamsSet(secs, withdrawTimelockDelay);
    }

    /// @notice Demo-only: shorten the redeem-execution window. Locked on mainnet.
    function setWithdrawTimelockDelay(uint256 secs) external onlyRole(GOVERNOR_ROLE) {
        if (!isDemoMode) revert OnlyDemoMode();
        withdrawTimelockDelay = secs;
        emit TimelockParamsSet(withdrawTimelockDuration, secs);
    }

    // ---- Soulbound enforcement (override _update) ------------------------

    /// @dev Any non-mint, non-burn movement reverts. Vote checkpoints still
    ///      get written via super._update (ERC20Votes hook).
    function _update(address from, address to, uint256 value) internal override(ERC20, ERC20Votes) {
        if (from != address(0) && to != address(0)) revert NonTransferable();
        super._update(from, to, value);
    }

    // ---- Nonces resolver -------------------------------------------------

    function nonces(address owner) public view override(Nonces) returns (uint256) {
        return super.nonces(owner);
    }

    /// @dev Decimals must agree with the asset (which is the LendingPool, also 18).
    function decimals() public view override(ERC20, ERC4626) returns (uint8) {
        return ERC4626.decimals();
    }
}
