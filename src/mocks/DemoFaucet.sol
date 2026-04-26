// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {MockUSDr} from "./MockUSDr.sol";
import {MockAMFI} from "./MockAMFI.sol";

/// @title DemoFaucet
/// @notice Drips MockUSDr + MockAMFI to any caller, gated by a per-address
///         24h cooldown. The faucet must hold MINTER_ROLE on both mocks; mint
///         is delegated rather than transferred so the faucet has no tokens
///         to drain pre-funded.
/// @dev   Cooldown is intentionally on-chain (timestamp comparison) so the
///        front-end can read remaining time before showing the button.
contract DemoFaucet is Ownable {
    MockUSDr public immutable usdr;
    MockAMFI public immutable amfi;

    uint256 public usdrDripAmount;
    uint256 public amfiDripAmount;
    uint256 public cooldown;

    mapping(address => uint256) public lastDripAt;

    event Dripped(address indexed to, uint256 usdrAmount, uint256 amfiAmount, uint256 nextAvailableAt);
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

    /// @notice Mint the configured drip amounts to `msg.sender`. Subject to cooldown.
    function drip() external {
        uint256 last = lastDripAt[msg.sender];
        if (last != 0 && block.timestamp < last + cooldown) {
            revert CooldownActive(last + cooldown - block.timestamp);
        }
        lastDripAt[msg.sender] = block.timestamp;
        if (usdrDripAmount > 0) usdr.mint(msg.sender, usdrDripAmount);
        if (amfiDripAmount > 0) amfi.mint(msg.sender, amfiDripAmount);
        emit Dripped(msg.sender, usdrDripAmount, amfiDripAmount, block.timestamp + cooldown);
    }

    /// @notice Seconds remaining for `who` before the next drip is allowed; 0 if available now.
    function secondsUntilNextDrip(address who) external view returns (uint256) {
        uint256 last = lastDripAt[who];
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
