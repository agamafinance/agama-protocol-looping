// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {ISettlementVault} from "../interfaces/ISettlementVault.sol";
import {IAgamaPool, IAgamaSP, ITreasuryDeposit} from "../interfaces/IAgamaCollectors.sol";

/// @title AgamaSettlementVault
/// @notice The protocol-specific bridge that turns seized RWA into restored
///         agaSP value. Holds 100% of seized RWA per batch, queues an
///         off-chain redemption, then redeposits the recovered USDr into
///         the LendingPool on the StabilityPool's behalf.
///
/// @dev    DEVIATION from the doc: the V1 doc applies LiquidationSplit on the
///         seized RWA at `handleSeizure`. Here, the split is applied on the
///         **USDr proceeds at `settleRedemption`**. Same economic outcome,
///         simpler flow:
///           - Treasury never holds RWA tokens (clean auto-stake of USDr)
///           - Single Manager off-chain redemption per batch
///           - emergencyDistributeInKind distributes the entire batch
///         The split parameters (LiquidationSplit) keep the same names and
///         meanings — they just gate USDr flows now.
contract AgamaSettlementVault is ISettlementVault, AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant GOVERNOR_ROLE = keccak256("GOVERNOR_ROLE");
    bytes32 public constant MANAGER_ROLE = keccak256("MANAGER_ROLE");

    enum Status {
        Queued,
        Settled,
        EmergencyDistributed
    }

    /// @param treasuryBps  Share of `usdrReceived` routed to Treasury (basis points).
    /// @param redeemBps    Share of `usdrReceived` routed to SP (must be 10_000 - treasuryBps in V1).
    struct LiquidationSplit {
        uint16 treasuryBps;
        uint16 redeemBps;
    }

    struct Batch {
        uint256 id;
        address rwaToken;
        uint256 rwaAmount; // total seized RWA held by this contract
        uint256 pegGap; // USDr the SP is owed back (= absorbedAssets at finalize)
        Status status;
        uint64 queuedAt;
        uint64 snapshotBlock; // block.number at handleSeizure — used by emergency path
        uint64 settledAt;
    }

    /// @notice The StabilityPool — only authorized caller of `handleSeizure`.
    address public immutable SP;
    /// @notice The LendingPool — depositOnBehalf target on settle.
    IAgamaPool public immutable LP;
    /// @notice The Treasury — recipient of `treasuryBps` USDr on settle.
    ITreasuryDeposit public immutable TREASURY;
    /// @notice The USDr ERC20 — Manager pre-funds this vault, vault forwards.
    IERC20 public immutable USDR;

    LiquidationSplit public split;

    /// @notice Time after `queuedAt` past which `emergencyDistributeInKind`
    ///         becomes callable. Production = 60 days.
    uint256 public staleBatchPeriod;

    /// @notice Expected window from `queuedAt` until the manager normally
    ///         settles a batch off-chain (production ~15 days). Used by the
    ///         StabilityPool's unstake cooldown: a `requestUnstake` issued
    ///         while a batch is still within its expected window is held
    ///         in cooldown until the batch is expected to close, ensuring
    ///         the stake actually absorbs the liquidation it was nominally
    ///         backing. Bounded [1 day, 30 days].
    uint256 public standardSettlementWindow;

    uint256 public nextBatchId;
    mapping(uint256 id => Batch) public batches;

    /// @notice Tracks per-(batch, holder) emergency claims so each holder
    ///         can claim at most once.
    mapping(uint256 batchId => mapping(address holder => bool)) public emergencyClaimed;

    /// @notice Lifetime sum of pegGap for all `Queued` batches. The SP reads
    ///         this in its `totalAssets()` so the agaSP share price stays
    ///         smooth across the redemption window.
    uint256 public override pegGapPendingForSP;

    event BatchQueued(
        uint256 indexed id, address rwaToken, uint256 rwaAmount, uint256 pegGap, uint256 snapshotBlock
    );
    event BatchSettled(uint256 indexed id, uint256 usdrReceived, uint256 toTreasury, uint256 toSP);
    event EmergencyClaim(uint256 indexed id, address indexed holder, uint256 rwaAmount);
    event EmergencyBatchDistributed(uint256 indexed id);
    event SplitUpdated(uint16 treasuryBps, uint16 redeemBps);
    event StaleBatchPeriodUpdated(uint256 secs);
    event StandardSettlementWindowUpdated(uint256 secs);
    event ManagerReplaced(address indexed oldManager, address indexed newManager);
    event DustSwept(address indexed token, address indexed to, uint256 amount);

    error UnknownBatch();
    error AlreadyResolved();
    error NotStaleYet();
    error AlreadyClaimed();
    error NoSnapshot();
    error InvalidSplit();
    error OnlySP();
    error AmountZero();
    error InvalidManager();
    error InvalidPeriod();
    error SeizedAmountMismatch();

    modifier onlySP() {
        if (msg.sender != SP) revert OnlySP();
        _;
    }

    constructor(address admin, address sp, IAgamaPool lp, ITreasuryDeposit treasury, IERC20 usdr) {
        SP = sp;
        LP = lp;
        TREASURY = treasury;
        USDR = usdr;

        // V1 production split: 200 bps Treasury, 9800 bps SP.
        split = LiquidationSplit({treasuryBps: 200, redeemBps: 9800});
        staleBatchPeriod = 60 days;
        standardSettlementWindow = 15 days;

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(GOVERNOR_ROLE, admin);
    }

    // ---- Seizure & settlement -------------------------------------------

    /// @inheritdoc ISettlementVault
    function handleSeizure(
        address rwaToken,
        address, /* vaultAdapter — V1 unused */
        bytes calldata, /* data — V1 unused */
        uint256 seizedAmount,
        uint256 pegGap,
        uint256 /* minSharesOut — V1 unused */
    ) external override nonReentrant onlySP returns (uint256 batchId) {
        if (seizedAmount == 0) revert AmountZero();
        // Defense-in-depth: vault must hold at least `seizedAmount` of the
        // RWA token. SP transfers before calling, so this catches a
        // catastrophic mismatch (SP bug, miscomputed seized). Note this is
        // not a strict delta check — if a previous batch left dust, that
        // dust is counted. For V1 (vanilla ERC20 collateral, settle sweeps
        // to 0xdead) this is sufficient. Add fee-on-transfer adapters only
        // with a stricter pre-balance snapshot pattern.
        uint256 actualReceived = IERC20(rwaToken).balanceOf(address(this));
        if (actualReceived < seizedAmount) revert SeizedAmountMismatch();
        batchId = ++nextBatchId;
        batches[batchId] = Batch({
            id: batchId,
            rwaToken: rwaToken,
            rwaAmount: seizedAmount,
            pegGap: pegGap,
            status: Status.Queued,
            queuedAt: uint64(block.timestamp),
            snapshotBlock: uint64(block.number),
            settledAt: 0
        });
        pegGapPendingForSP += pegGap;
        emit BatchQueued(batchId, rwaToken, seizedAmount, pegGap, block.number);
    }

    /// @notice Manager calls after off-chain redemption. Manager has
    ///         pre-approved this vault for `usdrReceived` USDr. The vault
    ///         pulls it, then routes `treasuryBps` to Treasury and the rest
    ///         to the SP via `LP.depositOnBehalf`.
    function settleRedemption(uint256 batchId, uint256 usdrReceived)
        external
        nonReentrant
        onlyRole(MANAGER_ROLE)
    {
        Batch storage b = batches[batchId];
        if (b.id == 0) revert UnknownBatch();
        if (b.status != Status.Queued) revert AlreadyResolved();

        b.status = Status.Settled;
        b.settledAt = uint64(block.timestamp);
        pegGapPendingForSP -= b.pegGap;

        if (usdrReceived == 0) {
            emit BatchSettled(batchId, 0, 0, 0);
            return;
        }

        // Pull USDr from the manager's wallet (approved beforehand).
        USDR.safeTransferFrom(msg.sender, address(this), usdrReceived);

        uint256 toTreasury = (usdrReceived * split.treasuryBps) / 10_000;
        uint256 toSP = usdrReceived - toTreasury;

        if (toTreasury > 0) {
            SafeERC20.forceApprove(USDR, address(TREASURY), toTreasury);
            TREASURY.deposit(address(USDR), toTreasury);
        }
        if (toSP > 0) {
            SafeERC20.forceApprove(USDR, address(LP), toSP);
            LP.depositOnBehalf(toSP, SP);
        }

        // The seized RWA is no longer needed on-chain — Manager has off-chain
        // redeemed it. We sweep it to a dead address so the contract's
        // `rwaToken` balance doesn't carry stale dust between batches.
        if (b.rwaAmount > 0) {
            IERC20(b.rwaToken).safeTransfer(address(0xdead), b.rwaAmount);
        }

        emit BatchSettled(batchId, usdrReceived, toTreasury, toSP);
    }

    // ---- Emergency in-kind distribution ----------------------------------

    /// @notice Last-resort path. If the Manager fails to call
    ///         `settleRedemption` within `staleBatchPeriod`, agaSP holders
    ///         can claim their pro-rata share of the batch's RWA in-kind,
    ///         using a snapshot of agaSP balances at `b.snapshotBlock`.
    /// @dev    Each holder claims independently. The batch flips to
    ///         `EmergencyDistributed` once the cumulative claimed amount
    ///         covers the full `rwaAmount` (or close enough — small dust
    ///         from rounding stays in the vault and can be swept by gov).
    /// @param batchId The batch in question.
    /// @param holder  agaSP holder claiming. Anyone can trigger on behalf of
    ///                the holder; the funds always go to `holder`.
    function emergencyDistributeInKind(uint256 batchId, address holder)
        external
        nonReentrant
        returns (uint256 share)
    {
        Batch storage b = batches[batchId];
        if (b.id == 0) revert UnknownBatch();
        // Settled batches cannot be claimed in-kind (USDr already distributed
        // through depositOnBehalf at settle time).
        if (b.status == Status.Settled) revert AlreadyResolved();
        // Allow claims either after the stale window OR if governance has
        // already flipped the batch to EmergencyDistributed via
        // `forceEmergencySettlement`.
        if (b.status != Status.EmergencyDistributed && block.timestamp <= b.queuedAt + staleBatchPeriod) {
            revert NotStaleYet();
        }
        if (emergencyClaimed[batchId][holder]) revert AlreadyClaimed();

        IAgamaSP spv = IAgamaSP(SP);
        uint256 totalSupplyAtSnap = spv.getPastTotalSupply(b.snapshotBlock);
        if (totalSupplyAtSnap == 0) revert NoSnapshot();

        uint256 holderVotes = spv.getPastVotes(holder, b.snapshotBlock);
        if (holderVotes == 0) {
            emergencyClaimed[batchId][holder] = true;
            return 0;
        }

        share = (b.rwaAmount * holderVotes) / totalSupplyAtSnap;
        emergencyClaimed[batchId][holder] = true;

        if (share > 0) {
            IERC20(b.rwaToken).safeTransfer(holder, share);
        }
        emit EmergencyClaim(batchId, holder, share);
    }

    // ---- Admin -----------------------------------------------------------

    /// @notice Update the settlement split. `treasuryBps + redeemBps` must
    ///         equal 10_000. SP must keep at least 50% of every settle to
    ///         preserve the protocol's primary economic incentive (without
    ///         this floor, governance could redirect the entire RWA premium
    ///         to Treasury, starving SP stakers).
    function setSplit(LiquidationSplit calldata newSplit) external onlyRole(GOVERNOR_ROLE) {
        if (uint256(newSplit.treasuryBps) + uint256(newSplit.redeemBps) != 10_000) revert InvalidSplit();
        if (newSplit.redeemBps < 5_000) revert InvalidSplit();
        split = newSplit;
        emit SplitUpdated(newSplit.treasuryBps, newSplit.redeemBps);
    }

    /// @notice Governance-controlled adjustment of the emergency-claim window.
    ///         Default at deploy is 60 days; tighten or extend via governance
    ///         vote. Bounded to [1 day, 365 days] to prevent foot-guns
    ///         (zero would race the manager, infinity would DOS emergency
    ///         claims).
    function setStaleBatchPeriod(uint256 secs) external onlyRole(GOVERNOR_ROLE) {
        if (secs < 1 days || secs > 365 days) revert InvalidPeriod();
        staleBatchPeriod = secs;
        emit StaleBatchPeriodUpdated(secs);
    }

    /// @notice Update the expected settlement window read by the SP cooldown
    ///         logic. Bounded [1 day, 30 days] — zero would defeat the
    ///         absorption-window snapshot, anything > 30 days would stretch
    ///         the unstake cooldown into mainnet-pathological territory.
    function setStandardSettlementWindow(uint256 secs) external onlyRole(GOVERNOR_ROLE) {
        if (secs < 1 days || secs > 30 days) revert InvalidPeriod();
        standardSettlementWindow = secs;
        emit StandardSettlementWindowUpdated(secs);
    }

    /// @notice Latest expected close time across all currently-Queued batches.
    ///         Returns 0 if no batch is Queued. Read by `StabilityPool.requestUnstake`
    ///         to fix the cooldown extension *at request time* — guarantees that
    ///         a stake exits only after every absorption window it touched has
    ///         expected to close.
    /// @dev    O(nextBatchId). On testnet that's tiny; for mainnet at scale a
    ///         maintained max can be added (push on handleSeizure, recompute
    ///         on the boundary case where the closing batch was the max).
    function latestPendingSettlementCloseTime() external view returns (uint64) {
        uint64 maxClose = 0;
        uint64 window = uint64(standardSettlementWindow);
        uint256 last = nextBatchId;
        for (uint256 i = 1; i <= last; ++i) {
            Batch storage b = batches[i];
            if (b.status == Status.Queued) {
                uint64 close = b.queuedAt + window;
                if (close > maxClose) maxClose = close;
            }
        }
        return maxClose;
    }

    /// @notice Governance hot-swap of a manager. Use when a keeper is
    ///         compromised, inactive, or when rotating ops staff. Strictly
    ///         atomic — old loses MANAGER_ROLE the same tx the new gains it.
    function replaceManager(address oldManager, address newManager) external onlyRole(GOVERNOR_ROLE) {
        if (oldManager == address(0) || newManager == address(0)) revert InvalidManager();
        if (oldManager == newManager) revert InvalidManager();
        if (!hasRole(MANAGER_ROLE, oldManager)) revert InvalidManager();
        _revokeRole(MANAGER_ROLE, oldManager);
        _grantRole(MANAGER_ROLE, newManager);
        emit ManagerReplaced(oldManager, newManager);
    }

    /// @notice Governance escape hatch — bypass the staleBatchPeriod and
    ///         flip a Queued batch directly to EmergencyDistributed,
    ///         enabling per-holder `emergencyDistributeInKind` claims.
    ///         Use when the manager is unreachable but governance can act
    ///         faster than waiting out the staleness window.
    function forceEmergencySettlement(uint256 batchId) external onlyRole(GOVERNOR_ROLE) {
        Batch storage b = batches[batchId];
        if (b.id == 0) revert UnknownBatch();
        if (b.status != Status.Queued) revert AlreadyResolved();
        b.status = Status.EmergencyDistributed;
        pegGapPendingForSP -= b.pegGap;
        emit EmergencyBatchDistributed(batchId);
    }

    /// @notice Bootstrap-only grant of MANAGER_ROLE. Use for the *initial*
    ///         keeper at deploy time. Subsequent rotations MUST go through
    ///         `replaceManager` to preserve the atomic-swap discipline (no
    ///         two-managers-active gap).
    function grantManager(address account) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _grantRole(MANAGER_ROLE, account);
    }

    /// @notice Sweep any residual ERC20 balance held by this vault to a
    ///         recipient. Fulfils the docstring promise on
    ///         `emergencyDistributeInKind` that small per-holder rounding
    ///         dust can be collected by governance after all claims are
    ///         processed. Also handy for recovering stuck tokens sent
    ///         here in error.
    /// @dev    Governance discipline: only call after all batch claims have
    ///         been processed for the relevant RWA, otherwise legitimate
    ///         claims may revert with InsufficientBalance.
    function sweepDust(IERC20 token, address to) external onlyRole(GOVERNOR_ROLE) returns (uint256 amount) {
        amount = token.balanceOf(address(this));
        if (amount > 0) {
            token.safeTransfer(to, amount);
            emit DustSwept(address(token), to, amount);
        }
    }
}
