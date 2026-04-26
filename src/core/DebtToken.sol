// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ILendingPool} from "../interfaces/ILendingPool.sol";
import {WadRayMath} from "../libs/WadRayMath.sol";

/// @title DebtToken
/// @notice Non-transferable, ERC20-compliant scaled debt token. Mirrors Aave
///         V2's VariableDebtToken pattern. Internal storage holds *scaled*
///         balances (debt normalized by the LendingPool's usage index at
///         mint/burn time); `balanceOf` returns the nominal debt by
///         multiplying by the pool's current normalized debt index.
/// @dev    transfer/transferFrom/approve all revert. Mint/burn restricted to
///         the LendingPool. The token implements IERC20Metadata so wallets
///         and explorers can render it like any other ERC20.
contract DebtToken is IERC20, IERC20Metadata {
    using WadRayMath for uint256;

    string private _name;
    string private _symbol;
    uint8 private immutable _decimals;

    /// @notice The LendingPool authorized to mint/burn.
    address public immutable POOL;

    /// @notice Underlying asset (e.g. MockUSDr).
    address public immutable UNDERLYING_ASSET;

    mapping(address => uint256) private _scaledBalances;
    uint256 private _scaledTotalSupply;

    event Mint(address indexed user, uint256 amount, uint256 index);
    event Burn(address indexed user, uint256 amount, uint256 index);

    error OnlyPool();
    error NonTransferable();
    error AmountZero();

    modifier onlyPool() {
        if (msg.sender != POOL) revert OnlyPool();
        _;
    }

    constructor(
        address pool,
        address underlying,
        string memory name_,
        string memory symbol_,
        uint8 decimals_
    ) {
        POOL = pool;
        UNDERLYING_ASSET = underlying;
        _name = name_;
        _symbol = symbol_;
        _decimals = decimals_;
    }

    // ---- IERC20Metadata ---------------------------------------------------

    function name() external view returns (string memory) {
        return _name;
    }

    function symbol() external view returns (string memory) {
        return _symbol;
    }

    function decimals() external view returns (uint8) {
        return _decimals;
    }

    // ---- IERC20 -----------------------------------------------------------

    function totalSupply() external view returns (uint256) {
        uint256 idx = ILendingPool(POOL).getNormalizedDebt();
        return _scaledTotalSupply.rayMul(idx);
    }

    function balanceOf(address user) external view returns (uint256) {
        uint256 idx = ILendingPool(POOL).getNormalizedDebt();
        return _scaledBalances[user].rayMul(idx);
    }

    /// @notice Always reverts: debt tokens are non-transferable.
    function transfer(address, uint256) external pure returns (bool) {
        revert NonTransferable();
    }

    /// @notice Always reverts: debt tokens are non-transferable.
    function transferFrom(address, address, uint256) external pure returns (bool) {
        revert NonTransferable();
    }

    /// @notice Always reverts: debt tokens are non-transferable.
    function approve(address, uint256) external pure returns (bool) {
        revert NonTransferable();
    }

    function allowance(address, address) external pure returns (uint256) {
        return 0;
    }

    // ---- Scaled views (Aave parity) --------------------------------------

    function scaledBalanceOf(address user) external view returns (uint256) {
        return _scaledBalances[user];
    }

    function scaledTotalSupply() external view returns (uint256) {
        return _scaledTotalSupply;
    }

    // ---- Pool-only mutators ----------------------------------------------

    /// @notice Mint `amount` of nominal debt to `user` at the current `index`.
    /// @dev    `amountScaled = amount.rayDiv(index)`. Half-up rounding is
    ///         applied via the WadRayMath library.
    /// @return amountScaled The scaled amount minted (for the caller's books).
    function mint(address user, uint256 amount, uint256 index)
        external
        onlyPool
        returns (uint256 amountScaled)
    {
        if (amount == 0) revert AmountZero();
        amountScaled = amount.rayDiv(index);
        _scaledBalances[user] += amountScaled;
        _scaledTotalSupply += amountScaled;
        emit Transfer(address(0), user, amount);
        emit Mint(user, amount, index);
    }

    /// @notice Burn `amount` of nominal debt from `user`.
    /// @dev    Caps at the user's full scaled balance to handle the "repay max"
    ///         pattern where `amount` may slightly exceed nominal due to rounding.
    function burn(address user, uint256 amount, uint256 index)
        external
        onlyPool
        returns (uint256 amountScaled)
    {
        if (amount == 0) revert AmountZero();
        uint256 userScaled = _scaledBalances[user];
        amountScaled = amount.rayDiv(index);
        if (amountScaled > userScaled) amountScaled = userScaled;
        unchecked {
            _scaledBalances[user] = userScaled - amountScaled;
            _scaledTotalSupply -= amountScaled;
        }
        emit Transfer(user, address(0), amount);
        emit Burn(user, amount, index);
    }
}
