// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {IAssetAdapter} from "./IAssetAdapter.sol";
import {MockAMFI} from "../mocks/MockAMFI.sol";
import {MockOracle} from "../mocks/MockOracle.sol";

/// @title AmFiAdapter
/// @notice Custody + valuation adapter for AmFi senior tranche tokens. The
///         adapter holds the underlying RWA tokens; the LendingPool calls in
///         here for deposit/withdraw and reads collateral values for HF math.
///         V1: 1 user = 1 position per adapter (positionKey is a constant).
/// @dev    Valuation: `balance × pricePerShare × oraclePrice / 1e36`, all
///         components in 1e18-fixed → result is USD with 1e18 scaling.
contract AmFiAdapter is IAssetAdapter, Ownable {
    using SafeERC20 for IERC20;

    // ---- Constants -------------------------------------------------------

    /// @notice The constant position key used in V1. V2 may decode `data` to
    ///         allow multiple positions per (adapter, user).
    bytes32 public constant V1_POSITION_KEY = keccak256("AMFI_V1");

    uint256 internal constant SCALE = 1e18;

    // ---- Immutables ------------------------------------------------------

    /// @notice The LendingPool authorized to call lifecycle entrypoints.
    address public immutable POOL;

    /// @notice The underlying AmFi senior tranche ERC20 (yield-bearing via
    ///         `pricePerShare()`).
    MockAMFI public immutable AMFI;

    // ---- Risk parameters (immutable per V1) ------------------------------

    uint256 public immutable override MAX_LTV;
    uint256 public immutable override LIQUIDATION_THRESHOLD;
    uint256 public immutable override LIQUIDATION_BONUS;
    uint256 public override ORACLE_STALENESS_MAX;

    // ---- Mutable state ---------------------------------------------------

    MockOracle public oracle;

    /// @dev positionKey => user => internal balance in raw token units.
    mapping(bytes32 => mapping(address => uint256)) internal _balances;

    /// @notice Sum of internal balances across all active positions. Maintained
    ///         O(1) on deposit / withdraw / transferAsset.
    uint256 public override totalInternalBalance;

    // ---- Events ----------------------------------------------------------

    event Deposited(address indexed user, bytes32 indexed key, uint256 amount);
    event Withdrawn(address indexed user, bytes32 indexed key, uint256 amount);
    event Seized(address indexed from, bytes32 indexed key, address indexed to, uint256 amount);
    event OracleUpdated(address indexed newOracle);
    event StalenessUpdated(uint256 newSeconds);

    // ---- Errors ----------------------------------------------------------

    error OnlyPool();
    error AmountZero();
    error InsufficientPositionBalance();
    error OracleStale();
    error OracleZero();
    error InvalidData();

    // ---- Construction ----------------------------------------------------

    constructor(
        address pool,
        MockAMFI amfi,
        MockOracle oracle_,
        address admin,
        uint256 maxLtvBps,
        uint256 liquidationThresholdBps,
        uint256 liquidationBonusBps,
        uint256 oracleStalenessMax
    ) Ownable(admin) {
        POOL = pool;
        AMFI = amfi;
        oracle = oracle_;
        MAX_LTV = maxLtvBps;
        LIQUIDATION_THRESHOLD = liquidationThresholdBps;
        LIQUIDATION_BONUS = liquidationBonusBps;
        ORACLE_STALENESS_MAX = oracleStalenessMax;
    }

    modifier onlyPool() {
        if (msg.sender != POOL) revert OnlyPool();
        _;
    }

    // ---- Position lifecycle (pool-only) ----------------------------------

    function deposit(address user, bytes calldata data) external override onlyPool {
        uint256 amount = _decodeAmount(data);
        if (amount == 0) revert AmountZero();
        _balances[V1_POSITION_KEY][user] += amount;
        totalInternalBalance += amount;
        IERC20(address(AMFI)).safeTransferFrom(user, address(this), amount);
        emit Deposited(user, V1_POSITION_KEY, amount);
    }

    function withdraw(address user, bytes calldata data) external override onlyPool {
        uint256 amount = _decodeAmount(data);
        if (amount == 0) revert AmountZero();
        uint256 bal = _balances[V1_POSITION_KEY][user];
        if (amount > bal) revert InsufficientPositionBalance();
        unchecked {
            _balances[V1_POSITION_KEY][user] = bal - amount;
            totalInternalBalance -= amount;
        }
        IERC20(address(AMFI)).safeTransfer(user, amount);
        emit Withdrawn(user, V1_POSITION_KEY, amount);
    }

    function transferAsset(address from, bytes calldata, address to) external override onlyPool {
        uint256 bal = _balances[V1_POSITION_KEY][from];
        if (bal == 0) revert InsufficientPositionBalance();
        _balances[V1_POSITION_KEY][from] = 0;
        unchecked {
            totalInternalBalance -= bal;
        }
        IERC20(address(AMFI)).safeTransfer(to, bal);
        emit Seized(from, V1_POSITION_KEY, to, bal);
    }

    // ---- Valuation -------------------------------------------------------

    function getAssetValue(address user, bytes calldata) external view override returns (uint256) {
        return _valueOf(_balances[V1_POSITION_KEY][user]);
    }

    function getWithdrawValue(address user, bytes calldata data) external view override returns (uint256) {
        uint256 amount = _decodeAmount(data);
        uint256 bal = _balances[V1_POSITION_KEY][user];
        if (amount > bal) amount = bal;
        return _valueOf(amount);
    }

    function getTotalAssetValue(address user) external view override returns (uint256) {
        return _valueOf(_balances[V1_POSITION_KEY][user]);
    }

    // ---- Position identification ----------------------------------------

    function getPositionKey(bytes calldata) external pure override returns (bytes32) {
        return V1_POSITION_KEY;
    }

    function getPositionKeys(address user) external view override returns (bytes32[] memory keys) {
        if (_balances[V1_POSITION_KEY][user] == 0) {
            return new bytes32[](0);
        }
        keys = new bytes32[](1);
        keys[0] = V1_POSITION_KEY;
    }

    // ---- Validation ------------------------------------------------------

    function validate(address, bytes calldata data) external pure override {
        // Decode-or-revert; that's the only structural check on `data` in V1.
        _decodeAmount(data);
    }

    function validateLiquidationData(address user, bytes calldata) external view override returns (bool) {
        return _balances[V1_POSITION_KEY][user] > 0;
    }

    // ---- Asset metadata --------------------------------------------------

    function getAssetToken() external view override returns (address) {
        return address(AMFI);
    }

    function getAssetType() external pure override returns (string memory) {
        return "AmFi senior tranche";
    }

    function supportsPartialWithdraw() external pure override returns (bool) {
        return true;
    }

    // ---- Owner ops --------------------------------------------------------

    function setPriceOracle(address newOracle) external override onlyOwner {
        oracle = MockOracle(newOracle);
        emit OracleUpdated(newOracle);
    }

    function setOracleStalenessMax(uint256 secs) external onlyOwner {
        ORACLE_STALENESS_MAX = secs;
        emit StalenessUpdated(secs);
    }

    // ---- Public views ----------------------------------------------------

    /// @notice Internal collateral balance (raw token units) for a user.
    function balanceOf(address user) external view returns (uint256) {
        return _balances[V1_POSITION_KEY][user];
    }

    /// @inheritdoc IAssetAdapter
    function getInternalBalance(address user, bytes calldata) external view override returns (uint256) {
        return _balances[V1_POSITION_KEY][user];
    }

    // ---- Internals -------------------------------------------------------

    function _decodeAmount(bytes calldata data) internal pure returns (uint256 amount) {
        if (data.length != 32) revert InvalidData();
        amount = abi.decode(data, (uint256));
    }

    function _valueOf(uint256 amount) internal view returns (uint256) {
        if (amount == 0) return 0;
        uint256 spotUsd = oracle.getPrice();
        if (spotUsd == 0) revert OracleZero();
        if (block.timestamp - oracle.lastUpdate() > ORACLE_STALENESS_MAX) revert OracleStale();
        uint256 pps = AMFI.pricePerShare();
        // value = amount × pps × spotUsd / 1e36, all in 1e18 fixed
        return (amount * pps * spotUsd) / (SCALE * SCALE);
    }
}
