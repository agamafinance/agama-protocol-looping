// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {MockUSDr} from "./MockUSDr.sol";
import {MockAMFI} from "./MockAMFI.sol";

/// @title SplitFaucet
/// @notice Drip-style faucet with **separate** entrypoints for USDr and AMFI.
///         Holds MINTER_ROLE on both mocks and mints directly to msg.sender.
///         Each token has its own per-user cooldown, so users can top up one
///         side without resetting the other.
/// @dev    For demo simplicity: anyone can call, no allowance needed.
contract SplitFaucet is Ownable {
    MockUSDr public immutable usdr;
    MockAMFI public immutable amfi;

    uint256 public usdrDripAmount;
    uint256 public amfiDripAmount;
    uint256 public cooldown;

    mapping(address => uint256) public lastUsdrDripAt;
    mapping(address => uint256) public lastAmfiDripAt;

    event DrippedUSDr(address indexed to, uint256 amount, uint256 nextAvailableAt);
    event DrippedAMFI(address indexed to, uint256 amount, uint256 nextAvailableAt);
    event DripAmountsSet(uint256 usdrAmount, uint256 amfiAmount);
    event CooldownSet(uint256 newCooldown);

    error CooldownActive(uint256 secondsRemaining);

    constructor(
        address admin,
        MockUSDr _usdr,
        MockAMFI _amfi,
        uint256 _usdrDrip,
        uint256 _amfiDrip,
        uint256 _cooldown
    ) Ownable(admin) {
        usdr = _usdr;
        amfi = _amfi;
        usdrDripAmount = _usdrDrip;
        amfiDripAmount = _amfiDrip;
        cooldown = _cooldown;
    }

    function dripUSDr() external {
        uint256 last = lastUsdrDripAt[msg.sender];
        if (last != 0 && block.timestamp < last + cooldown) {
            revert CooldownActive(last + cooldown - block.timestamp);
        }
        lastUsdrDripAt[msg.sender] = block.timestamp;
        usdr.mint(msg.sender, usdrDripAmount);
        emit DrippedUSDr(msg.sender, usdrDripAmount, block.timestamp + cooldown);
    }

    function dripAMFI() external {
        uint256 last = lastAmfiDripAt[msg.sender];
        if (last != 0 && block.timestamp < last + cooldown) {
            revert CooldownActive(last + cooldown - block.timestamp);
        }
        lastAmfiDripAt[msg.sender] = block.timestamp;
        amfi.mint(msg.sender, amfiDripAmount);
        emit DrippedAMFI(msg.sender, amfiDripAmount, block.timestamp + cooldown);
    }

    /// @notice Convenience: drip both in a single tx, sharing the cooldown windows.
    function dripBoth() external {
        // Reuse the per-token guards so the call composes cleanly.
        uint256 lastU = lastUsdrDripAt[msg.sender];
        if (lastU != 0 && block.timestamp < lastU + cooldown) {
            revert CooldownActive(lastU + cooldown - block.timestamp);
        }
        uint256 lastA = lastAmfiDripAt[msg.sender];
        if (lastA != 0 && block.timestamp < lastA + cooldown) {
            revert CooldownActive(lastA + cooldown - block.timestamp);
        }
        lastUsdrDripAt[msg.sender] = block.timestamp;
        lastAmfiDripAt[msg.sender] = block.timestamp;
        usdr.mint(msg.sender, usdrDripAmount);
        amfi.mint(msg.sender, amfiDripAmount);
        emit DrippedUSDr(msg.sender, usdrDripAmount, block.timestamp + cooldown);
        emit DrippedAMFI(msg.sender, amfiDripAmount, block.timestamp + cooldown);
    }

    function secondsUntilNextUsdr(address who) external view returns (uint256) {
        uint256 last = lastUsdrDripAt[who];
        if (last == 0) return 0;
        uint256 nextAt = last + cooldown;
        if (block.timestamp >= nextAt) return 0;
        return nextAt - block.timestamp;
    }

    function secondsUntilNextAmfi(address who) external view returns (uint256) {
        uint256 last = lastAmfiDripAt[who];
        if (last == 0) return 0;
        uint256 nextAt = last + cooldown;
        if (block.timestamp >= nextAt) return 0;
        return nextAt - block.timestamp;
    }

    function setDripAmounts(uint256 _usdr, uint256 _amfi) external onlyOwner {
        usdrDripAmount = _usdr;
        amfiDripAmount = _amfi;
        emit DripAmountsSet(_usdr, _amfi);
    }

    function setCooldown(uint256 _cooldown) external onlyOwner {
        cooldown = _cooldown;
        emit CooldownSet(_cooldown);
    }
}
