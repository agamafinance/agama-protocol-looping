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
///         agTOKEN (the LendingPool itself); shares are agaSP. Soulbound: only
///         mint/burn move balances; transfers revert. ERC20Votes-enabled so
///         the SettlementVault's emergency in-kind distribution can snapshot
///         per-holder balances at queue time.
/// @dev    `totalAssets()` includes the SettlementVault's pending pegGap so
///         the agaSP share price stays smooth across the redemption window.
///         V1: deposit / redeem are direct (no withdraw timelock). The only
///         exit guard is the same-block flash-loan protection via `depositBlock`.
contract AgamaStabilityPool is ERC4626, ERC20Votes, AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant GOVERNOR_ROLE = keccak256("GOVERNOR_ROLE");
    bytes32 public constant MANAGER_ROLE = keccak256("MANAGER_ROLE");
    bytes32 public constant LIQUIDATION_PROXY_ROLE = keccak256("LIQUIDATION_PROXY_ROLE");

    /// @notice Address of the SettlementVault. Until set, `totalAssets`
    ///         only counts the raw agTOKEN balance.
    address public settlementVault;

    /// @dev Block number of the most-recent deposit per user. Used to block
    ///      same-block deposit/withdraw flash-loan-style griefing.
    mapping(address => uint256) public depositBlock;

    event SettlementVaultSet(address indexed vault);
    event ManagerSet(address indexed account, bool enabled);
    event BorrowerLiquidated(
        address indexed user, address indexed rwaToken, bytes data, uint256 absorbedAssets, uint256 seized
    );

    error NonTransferable();
    error AmountZero();
    error CannotDepositAndWithdrawSameBlock();
    error UnsupportedAdapterOnSP();
    error InvalidLiquidationData();
    error NoCollateralSeized();
    error SettlementVaultNotSet();

    constructor(IERC20 agToken, address admin)
        ERC20("Agama Stability Pool", "agaSP")
        EIP712("Agama Stability Pool", "1")
        ERC4626(agToken)
    {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(GOVERNOR_ROLE, admin);
    }

    // ---- ERC4626 surface --------------------------------------------------

    /// @notice Total assets backing agaSP: SP's agTOKEN balance + USDr-equiv
    ///         of pending SettlementVault redemptions, expressed in agTOKEN units
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

    /// @dev Records `depositBlock[receiver]` so a same-block redeem reverts
    ///      (prevents flash-loan-style sandwich attacks). Auto-self-delegates
    ///      so per-account historical votes are queryable for the
    ///      SettlementVault's emergencyDistributeInKind path.
    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override {
        if (assets == 0) revert AmountZero();
        super._deposit(caller, receiver, assets, shares);
        depositBlock[receiver] = block.number;
        if (delegates(receiver) == address(0)) _delegate(receiver, receiver);
    }

    /// @dev V1: redeem is direct ERC-4626. The only guard is the same-block
    ///      check that prevents flash-loan deposit-then-withdraw within the
    ///      same transaction.
    function _withdraw(address caller, address receiver, address owner, uint256 assets, uint256 shares)
        internal
        override
    {
        if (depositBlock[owner] == block.number) revert CannotDepositAndWithdrawSameBlock();
        super._withdraw(caller, receiver, owner, assets, shares);
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

    /// @dev Decimals agree with the asset (= LendingPool, 18 decimals).
    function decimals() public view override(ERC20, ERC4626) returns (uint8) {
        return ERC4626.decimals();
    }
}
