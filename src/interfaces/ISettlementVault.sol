// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title ISettlementVault
/// @notice Minimal surface used by the StabilityPool to query the redemption
///         queue. The vault's full surface (handleSeizure, settleRedemption,
///         emergencyDistributeInKind) lives on the implementation in S5.
interface ISettlementVault {
    /// @notice Sum of `pegGap` (USDr) across all batches in `Queued` status.
    ///         The StabilityPool counts this in its own `totalAssets()` so the
    ///         agaSP share price is smooth across the redemption window.
    function pegGapPendingForSP() external view returns (uint256 usdr);

    /// @notice Latest `queuedAt + standardSettlementWindow` across all
    ///         currently-Queued batches. Returns 0 when no batch is Queued.
    ///         The StabilityPool snapshots this at `requestUnstake` so the
    ///         user's cooldown extends to the close of every batch they were
    ///         nominally backing — preventing a request issued just after a
    ///         seizure from exiting before the redemption settles.
    function latestPendingSettlementCloseTime() external view returns (uint64);

    /// @notice Hook called by the StabilityPool right after seizing collateral.
    ///         The vault records a redemption batch and bumps `pegGapPendingForSP`.
    /// @param rwaToken     ERC20 of the seized collateral (already transferred in).
    /// @param vaultAdapter Optional adapter pointer for V2 multi-asset vaults; ignored in V1.
    /// @param data         Opaque adapter-encoded data; reserved.
    /// @param seizedAmount Total RWA tokens just transferred to the vault.
    /// @param pegGap       USDr the SP is owed back (= absorbedAssets at finalize).
    /// @param minSharesOut Slippage guard for downstream LP.depositOnBehalf in V2; ignored in V1.
    function handleSeizure(
        address rwaToken,
        address vaultAdapter,
        bytes calldata data,
        uint256 seizedAmount,
        uint256 pegGap,
        uint256 minSharesOut
    ) external returns (uint256 batchId);
}
