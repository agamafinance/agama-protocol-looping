// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

import {IAgamaPool, IAgamaSP} from "../interfaces/IAgamaCollectors.sol";

/// @title AgamaReserveFund
/// @notice Bad-debt buffer staked in the Stability Pool. In V1 the RF is
///         seeded with 100k USDr from a Rayls grant at TGE, immediately
///         deposits into the LendingPool, and stakes the resulting agTOKEN
///         into the SP. Thereafter the RF holds agaSP and earns pro-rata
///         share appreciation alongside every other staker — bonus stream
///         on liquidations, supply yield on lender APY.
/// @dev    The RF deliberately does NOT hold a liquid USDr buffer. There is
///         no `coverShortfall` function: when the SP runs out of capacity
///         the LP redistributes bad debt across active borrowers (Liquity
///         O(1)) — the RF, as the largest single staker, naturally absorbs
///         a large share of any SP dilution before redistribution kicks in.
contract AgamaReserveFund is AccessControl {
    using SafeERC20 for IERC20;

    bytes32 public constant DEPOSITOR_ROLE = keccak256("DEPOSITOR_ROLE");
    bytes32 public constant GOVERNOR_ROLE = keccak256("GOVERNOR_ROLE");

    IAgamaPool public immutable LP;
    IAgamaSP public immutable SP;
    IERC20 public immutable USDR;

    /// @dev Tripped on the first successful `seed`. Subsequent calls revert.
    bool public seeded;

    event Seeded(uint256 usdrIn, uint256 agTokenMinted, uint256 agaSPMinted);
    event Deposited(address indexed from, uint256 amount);
    event AutoStaked(uint256 usdrIn, uint256 agTokenMinted, uint256 agaSPMinted);
    event WithdrawnFromSP(address indexed to, uint256 agaSPBurned, uint256 agSharesOut);
    event WithdrawCompleted(address indexed to, uint256 usdrAmount);

    error AmountZero();
    error AlreadySeeded();

    constructor(address admin, IAgamaPool lp, IAgamaSP sp, IERC20 usdr) {
        LP = lp;
        SP = sp;
        USDR = usdr;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(GOVERNOR_ROLE, admin);
    }

    /// @notice One-shot seed at TGE. Callable by admin exactly once. Pulls
    ///         `amount` USDr from msg.sender (admin's wallet, funded by the
    ///         Rayls grant) and stakes it directly into the SP. Subsequent
    ///         top-ups must use `deposit` (DEPOSITOR_ROLE).
    function seed(uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (seeded) revert AlreadySeeded();
        if (amount == 0) revert AmountZero();
        seeded = true;
        uint256 before = USDR.balanceOf(address(this));
        USDR.safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = USDR.balanceOf(address(this)) - before;
        (uint256 agShares, uint256 agaSP) = _stakeUSDr(received);
        emit Seeded(received, agShares, agaSP);
    }

    /// @notice Push entrypoint for ongoing inflows (governance top-ups,
    ///         excess settlement proceeds in V2 if reconfigured). Always
    ///         auto-stakes — there is no liquid-hold mode.
    function deposit(address token, uint256 amount) external onlyRole(DEPOSITOR_ROLE) {
        require(token == address(USDR), "RF accepts USDr only");
        if (amount == 0) revert AmountZero();
        uint256 before = USDR.balanceOf(address(this));
        USDR.safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = USDR.balanceOf(address(this)) - before;
        emit Deposited(msg.sender, received);
        (uint256 agShares, uint256 agaSP) = _stakeUSDr(received);
        emit AutoStaked(received, agShares, agaSP);
    }

    function _stakeUSDr(uint256 amount) internal returns (uint256 agShares, uint256 agaSP) {
        USDR.approve(address(LP), amount);
        agShares = LP.deposit(amount, address(this));
        IERC20(address(LP)).approve(address(SP), agShares);
        agaSP = SP.deposit(agShares, address(this));
    }

    // ---- Governance withdrawals -----------------------------------------

    /// @notice Burns RF agaSP, sends the resulting agTOKEN directly to
    ///         `recipient`. Direct ERC-4626 redeem — no timelock (D2).
    /// @dev    Recipient handles any further conversion (LP.redeem to USDr).
    function withdrawFromSP(uint256 agaSPAmount, address recipient)
        external
        onlyRole(GOVERNOR_ROLE)
        returns (uint256 agSharesOut)
    {
        agSharesOut = SP.redeem(agaSPAmount, recipient, address(this));
        emit WithdrawnFromSP(recipient, agaSPAmount, agSharesOut);
    }

    /// @notice Full exit: burns RF agaSP, then burns the resulting agTOKEN
    ///         on the LP, sending USDr to `to`.
    function withdrawToAddress(uint256 agaSPAmount, address to) external onlyRole(GOVERNOR_ROLE) {
        uint256 agShares = SP.redeem(agaSPAmount, address(this), address(this));
        uint256 usdrOut = LP.redeem(agShares, to, address(this));
        emit WithdrawCompleted(to, usdrOut);
    }

    // ---- Admin -----------------------------------------------------------

    function grantDepositor(address account) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _grantRole(DEPOSITOR_ROLE, account);
    }

    // ---- Public coverage view -------------------------------------------

    /// @notice The RF's current agaSP balance — equivalently, its slice of
    ///         the SP. Off-chain dashboards divide this by `LP.totalSupply()
    ///         × LP.convertToAssets(1e18)` (loan book) for the coverage ratio.
    function coverageBalance() external view returns (uint256) {
        return IERC20(address(SP)).balanceOf(address(this));
    }
}
