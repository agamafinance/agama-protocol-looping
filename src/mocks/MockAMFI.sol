// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

/// @title MockAMFI
/// @notice Yield-bearing ERC20 mock for the AmFi senior tranche RWA token.
///         The yield is exposed via `pricePerShare()` which grows linearly at
///         a configurable APR (16% by default). The ERC20 balance is *static*
///         (denominated in shares) — only the USD/par value grows over time.
/// @dev    Adapters compute collateral value as
///             userBalance × pricePerShare × oracleSpot / 1e36
///         where oracleSpot is the USD-per-par price (BRL/USD FX × parity).
///         18 decimals.
contract MockAMFI is ERC20, AccessControl {
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant ACCRUAL_ADMIN_ROLE = keccak256("ACCRUAL_ADMIN_ROLE");

    uint256 public constant SHARE_PRICE_UNIT = 1e18;
    uint256 internal constant SECONDS_PER_YEAR = 365 days;
    uint256 internal constant RAY = 1e27;

    /// @dev Linear-accrual anchor. `pricePerShare()` reads from these and APR.
    uint256 public anchorPrice;
    uint256 public anchorTimestamp;
    /// @notice APR in RAY (e.g. 0.16e27 == 16%). Zero disables accrual.
    uint256 public aprRay;

    event AccrualSet(uint256 newAprRay, uint256 anchorPrice, uint256 anchorTimestamp);
    event PricePerShareSet(uint256 newPrice, uint256 anchorTimestamp);

    error InvalidPrice();

    constructor(address admin, uint256 initialAprRay) ERC20("Mock AmFi Senior", "mAMFI") {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(MINTER_ROLE, admin);
        _grantRole(ACCRUAL_ADMIN_ROLE, admin);
        anchorPrice = SHARE_PRICE_UNIT;
        anchorTimestamp = block.timestamp;
        aprRay = initialAprRay;
    }

    function decimals() public pure override returns (uint8) {
        return 18;
    }

    /// @notice Current price-per-share in 1e18-fixed (so 1.16e18 == 1.16 par).
    function pricePerShare() public view returns (uint256) {
        if (aprRay == 0) return anchorPrice;
        uint256 elapsed = block.timestamp - anchorTimestamp;
        uint256 increment = (anchorPrice * aprRay * elapsed) / (SECONDS_PER_YEAR * RAY);
        return anchorPrice + increment;
    }

    /// @notice Update the APR (re-anchors at current pricePerShare to avoid jumps).
    function setAccrual(uint256 newAprRay) external onlyRole(ACCRUAL_ADMIN_ROLE) {
        anchorPrice = pricePerShare();
        anchorTimestamp = block.timestamp;
        aprRay = newAprRay;
        emit AccrualSet(newAprRay, anchorPrice, anchorTimestamp);
    }

    /// @notice Owner-controlled jump to a specific price-per-share (demo cheat).
    function setPricePerShare(uint256 newPrice) external onlyRole(ACCRUAL_ADMIN_ROLE) {
        if (newPrice == 0) revert InvalidPrice();
        anchorPrice = newPrice;
        anchorTimestamp = block.timestamp;
        emit PricePerShareSet(newPrice, block.timestamp);
    }

    /// @notice Public unrestricted mint. Testnet mock only.
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }
}
