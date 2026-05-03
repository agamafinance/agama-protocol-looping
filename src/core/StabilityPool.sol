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

interface ILendingPoolLiquidate {
    function supportedAdapter(address adapter) external view returns (bool);
    function liquidate(address adapter, address user, bytes calldata data)
        external
        returns (uint256 absorbedAssets, uint256 badDebt);
}

/// @title AgamaStabilityPool
/// @notice Liquidation backstop and secondary lender venue. ERC-4626 vault on
///         agYLD (the LendingPool itself); shares are sagYLD. Transferable
///         ERC-20 (NOT soulbound) — the cooldown lives in a per-user
///         pending-request queue, not in the token. ERC20Votes-enabled so
///         the SettlementVault's emergency in-kind distribution can snapshot
///         per-holder balances at queue time.
///
/// @dev    Cooldown semantics:
///           - `deposit/mint` mint sagYLD 1:1-at-baseline as before.
///           - `requestUnstake(amount)` queues a pending-request *without*
///             burning shares. Shares stay in the user's balance and continue
///             to absorb liquidations during the cooldown — this is the
///             load-bearing tanker property of the SP.
///           - `claim(requestId)` after `unlockAt` burns
///             `min(amount, balanceOf(user))` and transfers agYLD at the
///             *current* share price. If the user transferred their sagYLD
///             elsewhere, claim returns 0 and consumes the request.
///           - The standard ERC-4626 `withdraw`/`redeem` revert. They are
///             unreachable; exits go through the cooldown path only.
///         The request snapshots the SettlementVault's
///         `latestPendingSettlementCloseTime` so that an unstake initiated
///         while a batch is in-flight can't escape before the redemption
///         settles. Concretely, `unlockAt = max(requestedAt + cooldownDuration,
///         settlementExtensionUntil)`.
contract AgamaStabilityPool is ERC4626, ERC20Votes, AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant GOVERNOR_ROLE = keccak256("GOVERNOR_ROLE");
    bytes32 public constant MANAGER_ROLE = keccak256("MANAGER_ROLE");
    bytes32 public constant LIQUIDATION_PROXY_ROLE = keccak256("LIQUIDATION_PROXY_ROLE");

    /// @notice Address of the SettlementVault. Until set, `totalAssets`
    ///         only counts the raw agYLD balance.
    address public settlementVault;

    /// @notice Same-block flash-loan protection on `deposit`. (No `redeem`
    ///         to pair with, but kept for parity with the previous impl.)
    mapping(address => uint256) public depositBlock;

    // ---- Unstake queue ----------------------------------------------------

    /// @notice Per-request descriptor. `amount` is the sagYLD share count
    ///         the user committed at request time. `settlementExtensionUntil`
    ///         is snapshotted from the SVault at request time.
    struct UnstakeRequest {
        uint128 amount;
        uint64 requestedAt;
        uint64 settlementExtensionUntil;
        bool claimed;
    }

    /// @notice Per-user FIFO queue of pending unstakes. A user may have
    ///         multiple in flight; each is independently claimable after
    ///         its own `unlockAt`.
    mapping(address => UnstakeRequest[]) internal _pendingRequests;

    /// @notice Sum of unclaimed `amount` per user. Read by `requestUnstake`
    ///         to bound the total earmark by `balanceOf(user)` and prevent
    ///         double-spending the same shares across multiple requests.
    mapping(address => uint256) public earmarkedShares;

    /// @notice Standard cooldown duration. Default 7 days, governance-settable
    ///         within [1 day, 30 days].
    uint256 public cooldownDuration;

    // TEMP for testnet demo — production must restore MIN_COOLDOWN = 1 days.
    uint256 internal constant MIN_COOLDOWN = 60 seconds;
    uint256 internal constant MAX_COOLDOWN = 30 days;

    // ---- Events ----------------------------------------------------------

    event SettlementVaultSet(address indexed vault);
    event ManagerSet(address indexed account, bool enabled);
    event BorrowerLiquidated(
        address indexed user, address indexed rwaToken, bytes data, uint256 absorbedAssets, uint256 seized
    );
    event UnstakeRequested(
        address indexed user, uint256 indexed requestId, uint256 amount, uint64 unlockAt
    );
    event UnstakeClaimed(
        address indexed user, uint256 indexed requestId, uint256 sharesBurned, uint256 assetsOut
    );
    event CooldownDurationSet(uint256 secs);

    // ---- Errors ----------------------------------------------------------

    error AmountZero();
    error CannotDepositAndWithdrawSameBlock();
    error UnsupportedAdapterOnSP();
    error InvalidLiquidationData();
    error NoCollateralSeized();
    error SettlementVaultNotSet();
    error InsufficientUnearmarkedShares();
    error CooldownNotElapsed();
    error AlreadyClaimed();
    error UseCooldownPath();
    error InvalidCooldown();
    error UnknownRequest();

    constructor(IERC20 agYLD, address admin)
        ERC20("Staked agYLD", "sagYLD")
        EIP712("Staked agYLD", "1")
        ERC4626(agYLD)
    {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(GOVERNOR_ROLE, admin);
        cooldownDuration = 7 days;
    }

    // ---- ERC4626 surface --------------------------------------------------

    /// @notice Total assets backing sagYLD: SP's agYLD balance + USDr-equiv
    ///         of pending SettlementVault redemptions, expressed in agYLD units
    ///         via the LendingPool's current share price.
    function totalAssets() public view override returns (uint256) {
        uint256 raw = IERC20(asset()).balanceOf(address(this));
        address sv = settlementVault;
        if (sv == address(0)) return raw;
        uint256 pegGapUsdr = ISettlementVault(sv).pegGapPendingForSP();
        if (pegGapUsdr == 0) return raw;
        uint256 pegGapShares = IERC4626(asset()).convertToShares(pegGapUsdr);
        return raw + pegGapShares;
    }

    /// @dev Records `depositBlock[receiver]` for the same-block guard, and
    ///      auto-self-delegates so per-account historical votes are queryable
    ///      for the SettlementVault's emergencyDistributeInKind path.
    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override {
        if (assets == 0) revert AmountZero();
        super._deposit(caller, receiver, assets, shares);
        depositBlock[receiver] = block.number;
        if (delegates(receiver) == address(0)) _delegate(receiver, receiver);
    }

    /// @dev Standard ERC-4626 instant exits are disabled — the only path out
    ///      is `requestUnstake` then `claim` after the cooldown.
    function maxWithdraw(address) public pure override returns (uint256) {
        return 0;
    }

    function maxRedeem(address) public pure override returns (uint256) {
        return 0;
    }

    function withdraw(uint256, address, address) public pure override returns (uint256) {
        revert UseCooldownPath();
    }

    function redeem(uint256, address, address) public pure override returns (uint256) {
        revert UseCooldownPath();
    }

    // ---- Unstake cooldown -----------------------------------------------

    /// @notice Queue an unstake of `amount` sagYLD. Does NOT burn shares
    ///         immediately — they stay in the user's balance and absorb any
    ///         liquidations that hit the SP during the cooldown. The user
    ///         claims at `unlockAt` and is paid the prevailing share price
    ///         at that moment, capped at their then-balance.
    /// @return requestId Position in the user's pending queue.
    function requestUnstake(uint256 amount) external nonReentrant returns (uint256 requestId) {
        if (amount == 0) revert AmountZero();
        uint256 bal = balanceOf(msg.sender);
        uint256 ear = earmarkedShares[msg.sender];
        // Bound: total pending earmarks never exceed current balance — prevents
        // queueing more requests than the user could actually settle even if
        // no liquidations happened.
        if (bal <= ear || amount > bal - ear) revert InsufficientUnearmarkedShares();

        earmarkedShares[msg.sender] = ear + amount;

        uint64 reqAt = uint64(block.timestamp);
        uint64 ext = 0;
        address sv = settlementVault;
        if (sv != address(0)) {
            ext = ISettlementVault(sv).latestPendingSettlementCloseTime();
        }

        _pendingRequests[msg.sender].push(
            UnstakeRequest({
                amount: uint128(amount),
                requestedAt: reqAt,
                settlementExtensionUntil: ext,
                claimed: false
            })
        );
        requestId = _pendingRequests[msg.sender].length - 1;

        uint64 unlock = unlockAt(_pendingRequests[msg.sender][requestId]);
        emit UnstakeRequested(msg.sender, requestId, amount, unlock);
    }

    /// @notice Claim a previously-queued unstake after its `unlockAt`. Burns
    ///         `min(request.amount, balanceOf(caller))` from the caller and
    ///         transfers the equivalent agYLD at the *current* share price.
    ///         If the caller transferred away their sagYLD or saw their
    ///         balance burnt by liquidations during the cooldown, they only
    ///         claim what's still in their wallet.
    function claim(uint256 requestId) external nonReentrant returns (uint256 assetsOut) {
        if (requestId >= _pendingRequests[msg.sender].length) revert UnknownRequest();
        UnstakeRequest storage r = _pendingRequests[msg.sender][requestId];
        if (r.claimed) revert AlreadyClaimed();
        if (block.timestamp < unlockAt(r)) revert CooldownNotElapsed();

        r.claimed = true;
        uint256 amount = uint256(r.amount);

        // Free the earmark first so any partial-fill case doesn't leak
        // earmark capacity beyond what was actually burnt.
        earmarkedShares[msg.sender] -= amount;

        uint256 sharesToBurn = amount;
        uint256 bal = balanceOf(msg.sender);
        if (sharesToBurn > bal) sharesToBurn = bal;

        if (sharesToBurn == 0) {
            emit UnstakeClaimed(msg.sender, requestId, 0, 0);
            return 0;
        }

        assetsOut = convertToAssets(sharesToBurn);
        _burn(msg.sender, sharesToBurn);
        IERC20(asset()).safeTransfer(msg.sender, assetsOut);

        emit UnstakeClaimed(msg.sender, requestId, sharesToBurn, assetsOut);
    }

    /// @notice Effective unlock time for a request. The max of the standard
    ///         `requestedAt + cooldownDuration` and the snapshotted
    ///         `settlementExtensionUntil` — guarantees a stake initiated
    ///         while a batch is in-flight only exits after that batch's
    ///         expected close.
    function unlockAt(UnstakeRequest memory r) public view returns (uint64) {
        uint64 base = r.requestedAt + uint64(cooldownDuration);
        return base > r.settlementExtensionUntil ? base : r.settlementExtensionUntil;
    }

    /// @notice Convenience accessor for off-chain UIs.
    function getRequest(address user, uint256 requestId) external view returns (UnstakeRequest memory) {
        return _pendingRequests[user][requestId];
    }

    function pendingCount(address user) external view returns (uint256) {
        return _pendingRequests[user].length;
    }

    // ---- Liquidation entrypoint -----------------------------------------

    /// @notice Drives a liquidation when the borrower's HF is below 1. Pulls
    ///         debt absorption + RWA seizure via `LP.liquidate`, then routes
    ///         the seized RWA into the SettlementVault for off-chain
    ///         redemption. Caller is the LiquidationProxy (which holds the
    ///         MANAGER_ROLE on this contract).
    function liquidateBorrower(
        address poolAdapter,
        address vaultAdapter,
        address user,
        bytes calldata data,
        uint256 minSharesOut
    ) external nonReentrant onlyRole(MANAGER_ROLE) {
        ILendingPoolLiquidate lp = ILendingPoolLiquidate(asset());
        if (!lp.supportedAdapter(poolAdapter)) revert UnsupportedAdapterOnSP();
        if (!IAssetAdapter(poolAdapter).validateLiquidationData(user, data)) revert InvalidLiquidationData();

        IERC20 rwa = IERC20(IAssetAdapter(poolAdapter).getAssetToken());
        uint256 preBalance = rwa.balanceOf(address(this));

        (uint256 absorbedAssets,) = lp.liquidate(poolAdapter, user, data);

        uint256 seized = rwa.balanceOf(address(this)) - preBalance;
        if (seized == 0) revert NoCollateralSeized();

        address sv = settlementVault;
        if (sv == address(0)) revert SettlementVaultNotSet();
        rwa.safeTransfer(sv, seized);
        ISettlementVault(sv)
            .handleSeizure(address(rwa), vaultAdapter, data, seized, absorbedAssets, minSharesOut);

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
        emit ManagerSet(account, enabled);
    }

    /// @notice Tighten or extend the standard cooldown. Bounded
    ///         [1 day, 30 days]. The settlement-extension floor in
    ///         `unlockAt` is unaffected — it's snapshotted from the
    ///         SVault on each `requestUnstake`.
    function setCooldownDuration(uint256 secs) external onlyRole(GOVERNOR_ROLE) {
        if (secs < MIN_COOLDOWN || secs > MAX_COOLDOWN) revert InvalidCooldown();
        cooldownDuration = secs;
        emit CooldownDurationSet(secs);
    }

    // ---- Hooks resolver -------------------------------------------------

    /// @dev Standard ERC20Votes hook. Transfers freely; the cooldown lives
    ///      in the request queue, not in the token.
    function _update(address from, address to, uint256 value) internal override(ERC20, ERC20Votes) {
        super._update(from, to, value);
    }

    function nonces(address owner) public view override(Nonces) returns (uint256) {
        return super.nonces(owner);
    }

    /// @dev Decimals agree with the asset (= LendingPool, 24 decimals after
    ///      the 6-decimal offset on the LP).
    function decimals() public view override(ERC20, ERC4626) returns (uint8) {
        return ERC4626.decimals();
    }
}
