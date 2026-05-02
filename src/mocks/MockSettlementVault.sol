// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {ISettlementVault} from "../interfaces/ISettlementVault.sol";

interface IDepositOnBehalf {
    function depositOnBehalf(uint256 assets, address receiver) external returns (uint256);
}

/// @title MockSettlementVault
/// @notice Stand-in for the real `AgamaSettlementVault` (S5). Records every
///         seizure as a Queued batch, lets the manager settle by minting
///         USDr and routing it back to the StabilityPool via the LendingPool's
///         `depositOnBehalf`. Enough surface to exercise the full S3 E2E
///         liquidation flow without pulling in real off-chain redemption.
contract MockSettlementVault is ISettlementVault, Ownable {
    using SafeERC20 for IERC20;

    enum Status {
        Queued,
        Settled
    }

    struct Batch {
        uint256 id;
        address rwaToken;
        uint256 rwaAmount;
        uint256 pegGap; // USDr the SP is owed back
        Status status;
        uint256 queuedAt;
    }

    /// @notice The LendingPool, used for `depositOnBehalf` when settling.
    address public immutable LP;
    /// @notice The StabilityPool — receiver of redeposits at settle time.
    address public immutable SP;
    /// @notice The USDr (mock) — recipient of redeemed funds.
    IERC20 public immutable USDR;

    uint256 public nextBatchId;
    mapping(uint256 id => Batch) public batches;
    /// @notice Sum of pegGap (in USDr) across all batches still in `Queued`.
    uint256 public override pegGapPendingForSP;

    event BatchQueued(uint256 indexed id, address rwaToken, uint256 amount, uint256 pegGap);
    event BatchSettled(uint256 indexed id, uint256 usdrReceived);

    error UnknownBatch();
    error AlreadySettled();
    error NotAuthorized();

    constructor(address lp, address sp, IERC20 usdr, address admin) Ownable(admin) {
        LP = lp;
        SP = sp;
        USDR = usdr;
    }

    /// @inheritdoc ISettlementVault
    function handleSeizure(
        address rwaToken,
        address, /* vaultAdapter */
        bytes calldata, /* data */
        uint256 seizedAmount,
        uint256 pegGap,
        uint256 /* minSharesOut */
    ) external override returns (uint256 id) {
        if (msg.sender != SP) revert NotAuthorized();
        id = ++nextBatchId;
        batches[id] = Batch({
            id: id,
            rwaToken: rwaToken,
            rwaAmount: seizedAmount,
            pegGap: pegGap,
            status: Status.Queued,
            queuedAt: block.timestamp
        });
        pegGapPendingForSP += pegGap;
        emit BatchQueued(id, rwaToken, seizedAmount, pegGap);
    }

    /// @notice Stub used by SP cooldown extension snapshot. The mock returns 0
    ///         so unit tests that don't care about settlement extension see a
    ///         vanilla `requestedAt + cooldownDuration` unlock.
    function latestPendingSettlementCloseTime() external pure override returns (uint64) {
        return 0;
    }

    /// @notice Manager simulates the off-chain redemption: USDr is delivered
    ///         to the vault (e.g. minted in the test) and we redeposit it
    ///         into the LendingPool on the StabilityPool's behalf, restoring
    ///         the SP's `totalAssets`.
    /// @dev    `usdrReceived` may exceed pegGap (bonus) or fall short
    ///         (shortfall absorbed by SP share-price drop in V1 tests).
    function settleRedemption(uint256 batchId, uint256 usdrReceived) external onlyOwner {
        Batch storage b = batches[batchId];
        if (b.id == 0) revert UnknownBatch();
        if (b.status != Status.Queued) revert AlreadySettled();

        b.status = Status.Settled;
        pegGapPendingForSP -= b.pegGap;

        if (usdrReceived > 0) {
            USDR.approve(LP, usdrReceived);
            IDepositOnBehalf(LP).depositOnBehalf(usdrReceived, SP);
        }

        emit BatchSettled(batchId, usdrReceived);
    }
}
