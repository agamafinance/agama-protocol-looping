// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {ILendingPool} from "../interfaces/ILendingPool.sol";
import {IAssetAdapter} from "../adapters/IAssetAdapter.sol";
import {DebtToken} from "./DebtToken.sol";
import {ReserveLogic} from "../libs/ReserveLogic.sol";
import {InterestRateModel as IRM} from "../libs/InterestRateModel.sol";
import {WadRayMath} from "../libs/WadRayMath.sol";

interface IFeeCollector {
    function collectFee(address token, address from, uint256 amount, bytes32 feeType) external;
}

/// @title AgamaLendingPool
/// @notice The protocol's core. An ERC-4626 vault on USDr (its share token IS
///         agTOKEN) plus a borrow surface against adapter-managed RWA
///         collateral. Fees route to a settable `feeRecipient` (FeeCollector
///         in S5). Liquidation entrypoints are present but stubbed in S2;
///         full lifecycle wiring lands in S3.
/// @dev    Interest accrual lives in `ReserveLogic`. The pool reads cash on
///         hand from its own USDr balance and total debt from `DebtToken`.
contract AgamaLendingPool is ERC4626, ILendingPool, AccessControl, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using ReserveLogic for ReserveLogic.ReserveData;
    using WadRayMath for uint256;

    // ---- Roles -----------------------------------------------------------

    bytes32 public constant GOVERNOR_ROLE = keccak256("GOVERNOR_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    /// @notice Granted to actors authorized to drive the liquidation lifecycle:
    ///         the LiquidationProxy and the StabilityPool both hold this.
    bytes32 public constant LIQUIDATION_PROXY_ROLE = keccak256("LIQUIDATION_PROXY_ROLE");
    /// @notice Granted to the StabilityPool address. Authorizes `burnDonation`
    ///         and bypasses `withdrawalsPaused` so the SP can still pull USDr
    ///         during liquidation events.
    bytes32 public constant STABILITY_POOL_ROLE = keccak256("STABILITY_POOL_ROLE");
    /// @notice Granted to the SettlementVault. Authorizes `depositOnBehalf`,
    ///         the ERC-4626 deposit variant where the caller pays USDr but
    ///         the receiver (typically the SP itself) gets the shares.
    bytes32 public constant SETTLEMENT_VAULT_ROLE = keccak256("SETTLEMENT_VAULT_ROLE");

    /// @notice Fee-type tag for the origination fee deducted at borrow time.
    bytes32 public constant FEE_ORIGINATION = keccak256("FEE_ORIGINATION");

    // ---- Constants -------------------------------------------------------

    uint256 internal constant RAY = WadRayMath.RAY;
    uint256 internal constant BPS_DENOM = 10_000;
    /// @notice HF threshold below which a position is liquidatable. RAY = 1.0.
    uint256 public constant HF_LIQUIDATION_THRESHOLD = RAY;

    // ---- Immutables ------------------------------------------------------

    /// @notice The non-transferable scaled debt token. Lives next to the pool
    ///         and is owned by it (only this contract can mint/burn).
    DebtToken public immutable DEBT_TOKEN;

    /// @notice True only on testnet. When false, the cheat setters
    ///         (`setLiquidationGracePeriod`, `fastForwardInterest`, …)
    ///         all revert. Set at construction; never flips.
    bool public immutable isDemoMode;

    // ---- Reserve state ---------------------------------------------------

    ReserveLogic.ReserveData internal _reserve;
    IRM.Params internal _irmParams;

    // ---- Risk parameters (governance-controlled) -------------------------

    uint256 public reserveFactorBps;
    uint256 public originationFeeBps;
    uint256 public depositFeeBps;
    uint256 public vaultOpeningFee;
    uint256 public minBorrowAmount;
    uint256 public liquidationGracePeriod;
    uint256 public supplyCap;
    uint256 public borrowCap;
    bool public withdrawalsPaused;

    address public feeRecipient;
    /// @notice Address of the StabilityPool. Set once via `setStabilityPool`
    ///         which simultaneously grants both the STABILITY_POOL_ROLE and
    ///         LIQUIDATION_PROXY_ROLE.
    address public stabilityPool;
    /// @notice Address of the SettlementVault. Set via `setSettlementVault`,
    ///         which grants SETTLEMENT_VAULT_ROLE.
    address public settlementVault;

    // ---- User / position storage -----------------------------------------

    mapping(address user => bool) public vaultOpened;
    mapping(address adapter => bool) public supportedAdapter;

    struct Position {
        bool isUnderLiquidation;
        uint256 liquidationStartTime;
    }

    /// @dev adapter => user => positionKey (V1: constant per adapter)
    mapping(address => mapping(address => mapping(bytes32 => Position))) internal _positions;

    // ---- Bad-debt redistribution (Liquity O(1) accumulator) --------------

    /// @notice Cumulative ray-scaled debt-per-collateral attributed to active
    ///         borrowers when liquidations exceed the StabilityPool's
    ///         capacity. Each borrower owes their `collateral × (LDebt -
    ///         snap[user])` worth of extra USDr debt.
    uint256 public bdAccLDebt;

    /// @dev adapter => user => snapshot of `bdAccLDebt` at last interaction.
    mapping(address => mapping(address => uint256)) internal _userLDebtSnapshot;

    // ---- Events ----------------------------------------------------------

    event VaultOpened(address indexed user, uint256 feePaid);
    event AssetDeposited(address indexed user, address indexed adapter, bytes data);
    event AssetWithdrawn(address indexed user, address indexed adapter, bytes data);
    event Borrow(address indexed user, address indexed adapter, uint256 amount, uint256 originationFee);
    event Repay(address indexed payer, address indexed user, uint256 amount);
    event AdapterRegistered(address indexed adapter, bool supported);
    event FeeRecipientSet(address indexed recipient);
    event StabilityPoolSet(address indexed sp);
    event SettlementVaultSet(address indexed vault);
    event DonationBurned(address indexed from, uint256 shares);
    event DepositOnBehalf(address indexed caller, address indexed receiver, uint256 assets, uint256 shares);
    event RiskParamSet(bytes32 indexed key, uint256 value);
    event LiquidationInitiated(address indexed user, address indexed adapter);
    event LiquidationClosed(address indexed user, address indexed adapter);
    event LiquidationFinalized(
        address indexed sp,
        address indexed user,
        address indexed adapter,
        uint256 scaledDebt,
        uint256 absorbedAssets,
        uint256 badDebt
    );
    event BadDebtRedistributed(uint256 badDebtAssets, uint256 newLDebtAcc);
    event BadDebtStuck(uint256 badDebtAssets);
    event RedistributionMaterialized(address indexed adapter, address indexed user, uint256 extraDebt);

    // ---- Errors ----------------------------------------------------------

    error AmountZero();
    error WithdrawalsArePaused();
    error SupplyCapExceeded();
    error BorrowCapExceeded();
    error LiquidityShortfall();
    error OnlyDemoMode();
    error UnsupportedAdapter();
    error VaultPositionAlreadyOpened();
    error VaultPositionNotOpened();
    error CannotActUnderLiquidation();
    error HealthFactorTooLow();
    error AmountBelowMinimum();
    error InvalidFeeRecipient();
    error NotImplemented();
    error UserAlreadyUnderLiquidation();
    error NotUnderLiquidation();
    error GracePeriodExpired();
    error GracePeriodNotExpired();
    error DebtNotZero();
    error HealthFactorTooHigh();
    error StabilityPoolNotSet();

    // ---- Construction ----------------------------------------------------

    constructor(
        IERC20 usdr,
        address admin,
        string memory name_,
        string memory symbol_,
        IRM.Params memory irmParams_,
        bool _isDemoMode
    ) ERC20(name_, symbol_) ERC4626(usdr) {
        IRM.validate(irmParams_);
        _irmParams = irmParams_;
        _reserve.init();
        isDemoMode = _isDemoMode;

        // V1 production risk parameters — identical on testnet and mainnet.
        // Only timings (gracePeriod, withdrawTimelock) are demo-tunable below.
        reserveFactorBps = 1000; // 10%
        originationFeeBps = 50; // 50 bps
        depositFeeBps = 0;
        vaultOpeningFee = 0;
        minBorrowAmount = 100e18; // 100 USDr
        liquidationGracePeriod = 72 hours; // production timing
        supplyCap = type(uint256).max;
        borrowCap = type(uint256).max;

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(GOVERNOR_ROLE, admin);
        _grantRole(PAUSER_ROLE, admin);

        // Deploy the DebtToken paired to this pool
        DEBT_TOKEN = new DebtToken(
            address(this),
            address(usdr),
            string.concat("Agama Debt ", IERC20Metadata(address(usdr)).symbol()),
            string.concat("agDEBT-", IERC20Metadata(address(usdr)).symbol()),
            IERC20Metadata(address(usdr)).decimals()
        );
    }

    // ---- ILendingPool views ----------------------------------------------

    function asset() public view override(ERC4626, ILendingPool) returns (address) {
        return ERC4626.asset();
    }

    function getNormalizedIncome() external view returns (uint256) {
        return _reserve.getNormalizedIncome();
    }

    function getNormalizedDebt() external view returns (uint256) {
        return _reserve.getNormalizedDebt();
    }

    // ---- ERC4626 overrides -----------------------------------------------

    /// @notice Total assets backing agTOKEN: cash on hand + nominal debt outstanding.
    function totalAssets() public view override returns (uint256) {
        uint256 cash = IERC20(asset()).balanceOf(address(this));
        uint256 debt = DEBT_TOKEN.totalSupply();
        return cash + debt;
    }

    /// @dev ERC4626 hook called inside `deposit` / `mint`. Pulls assets from caller.
    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override {
        _reserve.updateState();
        if (assets == 0) revert AmountZero();
        super._deposit(caller, receiver, assets, shares);
        _afterMutation();
        if (totalSupply() > supplyCap) revert SupplyCapExceeded();
    }

    /// @dev ERC4626 hook called inside `withdraw` / `redeem`.
    function _withdraw(address caller, address receiver, address owner, uint256 assets, uint256 shares)
        internal
        override
    {
        _reserve.updateState();
        if (withdrawalsPaused && !hasRole(STABILITY_POOL_ROLE, caller)) {
            revert WithdrawalsArePaused();
        }
        if (IERC20(asset()).balanceOf(address(this)) < assets) revert LiquidityShortfall();
        super._withdraw(caller, receiver, owner, assets, shares);
        _afterMutation();
    }

    // ---- Vault position lifecycle ----------------------------------------

    /// @notice One-time vault opening; collects `vaultOpeningFee` (0 in V1).
    function openVaultPosition() external whenNotPaused {
        if (vaultOpened[msg.sender]) revert VaultPositionAlreadyOpened();
        vaultOpened[msg.sender] = true;
        if (vaultOpeningFee > 0) {
            _collectFee(msg.sender, vaultOpeningFee);
        }
        emit VaultOpened(msg.sender, vaultOpeningFee);
    }

    function depositAsset(address adapter, bytes calldata data)
        external
        nonReentrant
        whenNotPaused
        onlySupportedAdapter(adapter)
    {
        if (!vaultOpened[msg.sender]) revert VaultPositionNotOpened();
        bytes32 key = IAssetAdapter(adapter).getPositionKey(data);
        if (_positions[adapter][msg.sender][key].isUnderLiquidation) revert CannotActUnderLiquidation();
        _reserve.updateState();
        _materializeRedistribution(adapter, msg.sender);
        IAssetAdapter(adapter).deposit(msg.sender, data);
        emit AssetDeposited(msg.sender, adapter, data);
    }

    function withdrawAsset(address adapter, bytes calldata data)
        external
        nonReentrant
        whenNotPaused
        onlySupportedAdapter(adapter)
    {
        bytes32 key = IAssetAdapter(adapter).getPositionKey(data);
        if (_positions[adapter][msg.sender][key].isUnderLiquidation) revert CannotActUnderLiquidation();
        _reserve.updateState();
        _materializeRedistribution(adapter, msg.sender);

        // Health-factor preview: is the post-withdrawal position still healthy?
        uint256 debt = _userDebt(msg.sender);
        if (debt > 0) {
            uint256 totalCollateral = IAssetAdapter(adapter).getAssetValue(msg.sender, data);
            uint256 withdrawing = IAssetAdapter(adapter).getWithdrawValue(msg.sender, data);
            uint256 remaining = totalCollateral > withdrawing ? totalCollateral - withdrawing : 0;
            uint256 ltBps = IAssetAdapter(adapter).LIQUIDATION_THRESHOLD();
            uint256 hf = _hf(remaining, debt, ltBps);
            if (hf < HF_LIQUIDATION_THRESHOLD) revert HealthFactorTooLow();
        }

        IAssetAdapter(adapter).withdraw(msg.sender, data);
        emit AssetWithdrawn(msg.sender, adapter, data);
    }

    // ---- Borrow / repay --------------------------------------------------

    function borrow(address adapter, bytes calldata data, uint256 amount)
        external
        nonReentrant
        whenNotPaused
        onlySupportedAdapter(adapter)
    {
        if (amount == 0) revert AmountZero();
        if (!vaultOpened[msg.sender]) revert VaultPositionNotOpened();
        bytes32 key = IAssetAdapter(adapter).getPositionKey(data);
        if (_positions[adapter][msg.sender][key].isUnderLiquidation) revert CannotActUnderLiquidation();

        _reserve.updateState();
        _materializeRedistribution(adapter, msg.sender);

        // Borrow cap on nominal debt
        if (DEBT_TOKEN.totalSupply() + amount > borrowCap) revert BorrowCapExceeded();

        // Min-borrow check
        if (amount < minBorrowAmount) revert AmountBelowMinimum();

        // HF after borrow at adapter MAX_LTV
        uint256 collateralValue = IAssetAdapter(adapter).getAssetValue(msg.sender, data);
        uint256 newDebt = _userDebt(msg.sender) + amount;
        uint256 ltBps = IAssetAdapter(adapter).MAX_LTV();
        uint256 hf = _hf(collateralValue, newDebt, ltBps);
        if (hf < HF_LIQUIDATION_THRESHOLD) revert HealthFactorTooLow();

        // Liquidity check
        if (IERC20(asset()).balanceOf(address(this)) < amount) revert LiquidityShortfall();

        // === Origination fee — charged BEFORE the debt mint to prevent the
        //     fee from leaking value to existing lenders.
        //
        //     Why this order matters:
        //     A debt mint inflates `totalAssets()` (cash + debt) without
        //     adding shares, so the LP's share price spikes mid-tx. If the
        //     fee path runs AFTER the mint, the FeeCollector → Treasury
        //     auto-stake deposits at that inflated share price and acquires
        //     fewer agTOKEN per USDr, leaving a slice of the fee's value
        //     captured by pre-existing lenders pro-rata.
        //
        //     By charging the fee first, the LP cash dips before the debt
        //     mint, the share price briefly drops, and Treasury's auto-stake
        //     catches that dip — getting more shares per USDr. When the debt
        //     mint then pumps the price up, Treasury rides the appreciation
        //     pro-rata alongside Bob, neutralizing the leak. End result:
        //     ~100% of the fee value accrues to the SP via Treasury.
        uint256 fee = 0;
        if (feeRecipient != address(0)) {
            fee = (amount * originationFeeBps) / BPS_DENOM;
            if (fee > 0) {
                IERC20(asset()).approve(feeRecipient, fee);
                IFeeCollector(feeRecipient).collectFee(asset(), address(this), fee, FEE_ORIGINATION);
            }
        }

        // Mint debt at current usage index. Borrower owes `amount` total —
        // the fee was prepaid out of the cash they're about to receive.
        DEBT_TOKEN.mint(msg.sender, amount, _reserve.usageIndex);

        // Disburse net to the borrower.
        IERC20(asset()).safeTransfer(msg.sender, amount - fee);

        _afterMutation();
        emit Borrow(msg.sender, adapter, amount, fee);
    }

    function repay(address adapter, bytes calldata data, uint256 amount)
        external
        nonReentrant
        onlySupportedAdapter(adapter)
        returns (uint256 paid)
    {
        // Note: repay is allowed even when isUnderLiquidation == true so the
        // borrower can cure during the grace period (per V1 doc). Once debt
        // hits zero, the borrower must still call `closeLiquidation` to clear
        // the flag.
        IAssetAdapter(adapter).getPositionKey(data); // sanity decode
        _reserve.updateState();
        _materializeRedistribution(adapter, msg.sender);

        uint256 debt = _userDebt(msg.sender);
        paid = amount == type(uint256).max ? debt : amount;
        if (paid == 0) revert AmountZero();
        if (paid > debt) paid = debt;

        IERC20(asset()).safeTransferFrom(msg.sender, address(this), paid);
        DEBT_TOKEN.burn(msg.sender, paid, _reserve.usageIndex);

        _afterMutation();
        emit Repay(msg.sender, msg.sender, paid);
    }

    // ---- Liquidation entrypoints (stubs for S3) --------------------------

    function initiateLiquidation(address adapter, address user, bytes calldata data)
        external
        onlyRole(LIQUIDATION_PROXY_ROLE)
    {
        if (!supportedAdapter[adapter]) revert UnsupportedAdapter();
        bytes32 key = IAssetAdapter(adapter).getPositionKey(data);
        Position storage p = _positions[adapter][user][key];
        if (p.isUnderLiquidation) revert UserAlreadyUnderLiquidation();

        _reserve.updateState();
        _materializeRedistribution(adapter, user);

        uint256 debt = _userActualDebt(adapter, user);
        if (debt == 0) revert HealthFactorTooHigh();
        uint256 collateral = IAssetAdapter(adapter).getAssetValue(user, data);
        uint256 ltBps = IAssetAdapter(adapter).LIQUIDATION_THRESHOLD();
        uint256 hf = _hf(collateral, debt, ltBps);
        if (hf >= HF_LIQUIDATION_THRESHOLD) revert HealthFactorTooHigh();

        p.isUnderLiquidation = true;
        p.liquidationStartTime = block.timestamp;
        emit LiquidationInitiated(user, adapter);
    }

    function closeLiquidation(address adapter, bytes calldata data) external {
        bytes32 key = IAssetAdapter(adapter).getPositionKey(data);
        Position storage p = _positions[adapter][msg.sender][key];
        if (!p.isUnderLiquidation) revert NotUnderLiquidation();
        if (block.timestamp >= p.liquidationStartTime + liquidationGracePeriod) revert GracePeriodExpired();
        if (_userDebt(msg.sender) != 0) revert DebtNotZero();
        delete _positions[adapter][msg.sender][key];
        emit LiquidationClosed(msg.sender, adapter);
    }

    /// @notice Finalizes a liquidation post-grace-period. Gated by
    ///         LIQUIDATION_PROXY_ROLE — both the LiquidationProxy and the
    ///         StabilityPool hold this role at deploy time. Burns the user's
    ///         debt, transfers the seized RWA to `stabilityPool` via the
    ///         adapter, and burns SP shares (donation) to keep the LP's
    ///         share price flat. Any uncovered loss is redistributed pro-rata
    ///         across remaining active borrowers.
    function finalizeLiquidation(address adapter, address user, bytes calldata data)
        external
        nonReentrant
        onlyRole(LIQUIDATION_PROXY_ROLE)
        returns (uint256 absorbedAssets, uint256 badDebt)
    {
        if (!supportedAdapter[adapter]) revert UnsupportedAdapter();
        address sp = stabilityPool;
        if (sp == address(0)) revert StabilityPoolNotSet();

        bytes32 key = IAssetAdapter(adapter).getPositionKey(data);
        Position storage p = _positions[adapter][user][key];
        if (!p.isUnderLiquidation) revert NotUnderLiquidation();
        if (block.timestamp < p.liquidationStartTime + liquidationGracePeriod) {
            revert GracePeriodNotExpired();
        }

        _reserve.updateState();
        _materializeRedistribution(adapter, user);

        uint256 scaledDebt = DEBT_TOKEN.balanceOf(user);
        if (scaledDebt == 0) revert DebtNotZero();

        uint256 spShares = balanceOf(sp);
        uint256 spCapacityAssets = convertToAssets(spShares);
        absorbedAssets = scaledDebt < spCapacityAssets ? scaledDebt : spCapacityAssets;
        uint256 sharesToBurn = convertToShares(absorbedAssets);

        if (sharesToBurn > 0) {
            _burn(sp, sharesToBurn);
            emit DonationBurned(sp, sharesToBurn);
        }

        DEBT_TOKEN.burn(user, scaledDebt, _reserve.usageIndex);
        IAssetAdapter(adapter).transferAsset(user, data, sp);

        _userLDebtSnapshot[adapter][user] = bdAccLDebt;

        badDebt = scaledDebt - absorbedAssets;
        if (badDebt > 0) _redistributeBadDebt(adapter, badDebt);

        delete _positions[adapter][user][key];
        _afterMutation();
        emit LiquidationFinalized(sp, user, adapter, scaledDebt, absorbedAssets, badDebt);
    }

    // ---- Protocol-specific extensions (clearly non-standard) -------------

    /// @notice Burns `shares` from `from` without releasing any USDr. Used by
    ///         the StabilityPool during liquidation to absorb a `pegGap` worth
    ///         of debt that has just been wiped from a borrower. Pairs with a
    ///         simultaneous `DebtToken.burn` to preserve the totalAssets =
    ///         cash + debt invariant.
    /// @dev    NON-STANDARD ERC-4626 extension. Gated by STABILITY_POOL_ROLE.
    function burnDonation(address from, uint256 shares) external nonReentrant onlyRole(STABILITY_POOL_ROLE) {
        if (shares == 0) revert AmountZero();
        _burn(from, shares);
        emit DonationBurned(from, shares);
    }

    /// @notice ERC-4626 deposit variant where `msg.sender` pays the USDr but
    ///         `receiver` is credited the shares. Used by the SettlementVault
    ///         to redeposit redeemed USDr at the StabilityPool's address,
    ///         restoring the SP's `totalAssets` after a settlement batch.
    /// @dev    NON-STANDARD ERC-4626 extension. Gated by SETTLEMENT_VAULT_ROLE.
    function depositOnBehalf(uint256 assets, address receiver)
        external
        nonReentrant
        whenNotPaused
        onlyRole(SETTLEMENT_VAULT_ROLE)
        returns (uint256 shares)
    {
        if (assets == 0) revert AmountZero();
        // No deposit fee on this entrypoint — it's protocol-internal flow.
        _reserve.updateState();
        shares = previewDeposit(assets);
        _deposit(msg.sender, receiver, assets, shares);
        emit DepositOnBehalf(msg.sender, receiver, assets, shares);
    }

    // ---- Views -----------------------------------------------------------

    /// @notice HF for a user/adapter/positionKey, in RAY. `max` if debt is 0.
    /// @dev    Includes any pending bad-debt redistribution not yet materialized.
    function calculateHealthFactor(address adapter, address user, bytes calldata data)
        external
        view
        returns (uint256)
    {
        uint256 debt = _userActualDebt(adapter, user);
        if (debt == 0) return type(uint256).max;
        uint256 collateral = IAssetAdapter(adapter).getAssetValue(user, data);
        uint256 ltBps = IAssetAdapter(adapter).LIQUIDATION_THRESHOLD();
        return _hf(collateral, debt, ltBps);
    }

    function getPositionScaledDebt(address adapter, address user, bytes calldata)
        external
        view
        returns (uint256)
    {
        return _userActualDebt(adapter, user);
    }

    function getPosition(address adapter, address user, bytes calldata data)
        external
        view
        returns (Position memory)
    {
        bytes32 key = IAssetAdapter(adapter).getPositionKey(data);
        return _positions[adapter][user][key];
    }

    function getReserveState() external view returns (ReserveLogic.ReserveData memory) {
        return _reserve;
    }

    function getIRMParams() external view returns (IRM.Params memory) {
        return _irmParams;
    }

    // ---- Admin -----------------------------------------------------------

    function registerAdapter(address adapter, bool supported) external onlyRole(GOVERNOR_ROLE) {
        supportedAdapter[adapter] = supported;
        emit AdapterRegistered(adapter, supported);
    }

    function setFeeRecipient(address recipient) external onlyRole(GOVERNOR_ROLE) {
        feeRecipient = recipient;
        emit FeeRecipientSet(recipient);
    }

    /// @notice Set / re-set the StabilityPool. Grants both STABILITY_POOL_ROLE
    ///         and LIQUIDATION_PROXY_ROLE to the new SP, and revokes from the
    ///         old one if any.
    function setStabilityPool(address sp) external onlyRole(GOVERNOR_ROLE) {
        address old = stabilityPool;
        if (old != address(0)) {
            _revokeRole(STABILITY_POOL_ROLE, old);
            _revokeRole(LIQUIDATION_PROXY_ROLE, old);
        }
        stabilityPool = sp;
        if (sp != address(0)) {
            _grantRole(STABILITY_POOL_ROLE, sp);
            _grantRole(LIQUIDATION_PROXY_ROLE, sp);
        }
        emit StabilityPoolSet(sp);
    }

    /// @notice Set / re-set the SettlementVault. Grants SETTLEMENT_VAULT_ROLE.
    function setSettlementVault(address vault) external onlyRole(GOVERNOR_ROLE) {
        address old = settlementVault;
        if (old != address(0)) _revokeRole(SETTLEMENT_VAULT_ROLE, old);
        settlementVault = vault;
        if (vault != address(0)) _grantRole(SETTLEMENT_VAULT_ROLE, vault);
        emit SettlementVaultSet(vault);
    }

    function setReserveFactor(uint256 bps) external onlyRole(GOVERNOR_ROLE) {
        require(bps <= BPS_DENOM, "bps");
        reserveFactorBps = bps;
        emit RiskParamSet("reserveFactorBps", bps);
    }

    function setOriginationFee(uint256 bps) external onlyRole(GOVERNOR_ROLE) {
        require(bps <= BPS_DENOM, "bps");
        originationFeeBps = bps;
        emit RiskParamSet("originationFeeBps", bps);
    }

    function setMinBorrowAmount(uint256 v) external onlyRole(GOVERNOR_ROLE) {
        minBorrowAmount = v;
        emit RiskParamSet("minBorrowAmount", v);
    }

    function setSupplyCap(uint256 v) external onlyRole(GOVERNOR_ROLE) {
        supplyCap = v;
        emit RiskParamSet("supplyCap", v);
    }

    function setBorrowCap(uint256 v) external onlyRole(GOVERNOR_ROLE) {
        borrowCap = v;
        emit RiskParamSet("borrowCap", v);
    }

    /// @notice Demo-only override of the liquidation grace period. Reverts on
    ///         mainnet (where `isDemoMode == false`). Production value is the
    ///         constructor default (72h).
    function setLiquidationGracePeriod(uint256 secs) external onlyRole(GOVERNOR_ROLE) {
        if (!isDemoMode) revert OnlyDemoMode();
        liquidationGracePeriod = secs;
        emit RiskParamSet("liquidationGracePeriod", secs);
    }

    /// @notice Demo cheat: simulate `secondsToSimulate` of interest accrual
    ///         without waiting. Crystallizes any pending elapsed time first,
    ///         then advances the indices by the synthetic delta. Reverts on
    ///         mainnet.
    /// @dev    Useful in pitches to show agTOKEN appreciation and debt growth
    ///         on screen in seconds.
    function fastForwardInterest(uint256 secondsToSimulate) external onlyRole(GOVERNOR_ROLE) {
        if (!isDemoMode) revert OnlyDemoMode();
        _reserve.updateState();
        uint256 incrLiq = (_reserve.currentLiquidityRate * secondsToSimulate) / 365 days;
        uint256 incrDebt = (_reserve.currentBorrowRate * secondsToSimulate) / 365 days;
        _reserve.liquidityIndex = _reserve.liquidityIndex.rayMul(RAY + incrLiq);
        _reserve.usageIndex = _reserve.usageIndex.rayMul(RAY + incrDebt);
        emit RiskParamSet("fastForwardInterest", secondsToSimulate);
    }

    function setWithdrawalsPaused(bool paused) external onlyRole(PAUSER_ROLE) {
        withdrawalsPaused = paused;
    }

    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    function setIRMParams(IRM.Params memory p) external onlyRole(GOVERNOR_ROLE) {
        IRM.validate(p);
        _irmParams = p;
        // Re-update rates against the fresh params.
        _afterMutation();
    }

    // ---- Internals -------------------------------------------------------

    modifier onlySupportedAdapter(address adapter) {
        if (!supportedAdapter[adapter]) revert UnsupportedAdapter();
        _;
    }

    function _userDebt(address user) internal view returns (uint256) {
        return DEBT_TOKEN.balanceOf(user);
    }

    /// @dev Includes any unmaterialized bad-debt redistribution since the
    ///      user's last interaction. Use this for HF math; the actual
    ///      DebtToken balance only reflects materialized state.
    function _userActualDebt(address adapter, address user) internal view returns (uint256) {
        uint256 base = DEBT_TOKEN.balanceOf(user);
        uint256 snapL = _userLDebtSnapshot[adapter][user];
        if (bdAccLDebt <= snapL) return base;
        uint256 collat = IAssetAdapter(adapter).getInternalBalance(user, "");
        if (collat == 0) return base;
        unchecked {
            uint256 delta = bdAccLDebt - snapL;
            return base + (collat * delta) / RAY;
        }
    }

    /// @dev Mints any unmaterialized redistribution debt to the user, then
    ///      bumps their snapshot. Idempotent if accumulator hasn't moved.
    function _materializeRedistribution(address adapter, address user) internal {
        uint256 snapL = _userLDebtSnapshot[adapter][user];
        if (bdAccLDebt <= snapL) return;
        uint256 collat = IAssetAdapter(adapter).getInternalBalance(user, "");
        _userLDebtSnapshot[adapter][user] = bdAccLDebt;
        if (collat == 0) return;
        uint256 delta = bdAccLDebt - snapL;
        uint256 extra = (collat * delta) / RAY;
        if (extra > 0) {
            DEBT_TOKEN.mint(user, extra, _reserve.usageIndex);
            emit RedistributionMaterialized(adapter, user, extra);
        }
    }

    /// @dev Bumps the global `bdAccLDebt` accumulator by `badDebt × RAY /
    ///      totalActiveCollateral`. If no collateral remains anywhere, the
    ///      bad debt becomes "stuck" — emitted but not redistributed (corner
    ///      case where the only borrower was just liquidated).
    function _redistributeBadDebt(address adapter, uint256 badDebtAssets) internal {
        uint256 totalColl = IAssetAdapter(adapter).totalInternalBalance();
        if (totalColl == 0) {
            emit BadDebtStuck(badDebtAssets);
            return;
        }
        bdAccLDebt += (badDebtAssets * RAY) / totalColl;
        emit BadDebtRedistributed(badDebtAssets, bdAccLDebt);
    }

    function _hf(uint256 collateralValue, uint256 debt, uint256 ltBps) internal pure returns (uint256) {
        if (debt == 0) return type(uint256).max;
        // hf = collateral × ltBps × RAY / (debt × BPS_DENOM)
        return (collateralValue * ltBps * RAY) / (debt * BPS_DENOM);
    }

    function _afterMutation() internal {
        uint256 cash = IERC20(asset()).balanceOf(address(this));
        uint256 debt = DEBT_TOKEN.totalSupply();
        _reserve.updateInterestRates(_irmParams, cash, debt, reserveFactorBps);
    }

    function _collectFee(address from, uint256 amount) internal {
        if (feeRecipient == address(0)) {
            // Hold it on the LendingPool until the FeeCollector is wired (S5).
            IERC20(asset()).safeTransferFrom(from, address(this), amount);
        } else {
            IERC20(asset()).safeTransferFrom(from, feeRecipient, amount);
        }
    }
}
