//! NavOracle — on-chain NAV accrual for the RWA vaults.
//!
//! For each vault we store `(nav0, rate_per_second, t0)` and compute the live
//! NAV-per-share as `nav0 + rate_per_second * (now - t0)` (WAD, 1e18 == $1.00).
//! Because accrual is purely a function of `block.timestamp`, the NAV keeps rising
//! with no keeper or cron: **the protocol prices itself even if nobody pokes it.**
//! The authorized `updater` only steps in to change a rate or to simulate a credit
//! event via `crash`, which drops a vault's NAV and is what triggers liquidations.
#![cfg_attr(not(any(test, feature = "export-abi")), no_main)]
extern crate alloc;

use alloc::vec::Vec;
use stylus_sdk::{
    alloy_primitives::{Address, U256},
    alloy_sol_types::sol,
    prelude::*,
};

sol! {
    event VaultConfigured(address indexed vault, uint256 nav0, uint256 ratePerSecond);
    event NavCrashed(address indexed vault, uint256 oldNav, uint256 newNav);

    error NotOwner();
    error NotUpdater();
}

#[derive(SolidityError)]
pub enum OracleError {
    NotOwner(NotOwner),
    NotUpdater(NotUpdater),
}

sol_storage! {
    #[entrypoint]
    pub struct NavOracle {
        address owner;
        mapping(address => bool) updaters;
        mapping(address => uint256) nav0;
        mapping(address => uint256) rate_per_second;
        mapping(address => uint256) t0;
    }
}

#[public]
impl NavOracle {
    pub fn initialize(&mut self) {
        if self.owner.get() == Address::ZERO {
            let s = self.vm().msg_sender();
            self.owner.set(s);
            self.updaters.setter(s).set(true);
        }
    }

    pub fn owner(&self) -> Address {
        self.owner.get()
    }

    pub fn set_updater(&mut self, who: Address, allowed: bool) -> Result<(), OracleError> {
        self.only_owner()?;
        self.updaters.setter(who).set(allowed);
        Ok(())
    }

    /// Configure (or reconfigure) a vault's NAV curve. `nav0` is the NAV-per-share
    /// at `now` (WAD); `rate_per_second` is the absolute WAD added to NAV each second.
    pub fn set_vault(&mut self, vault: Address, nav0: U256, rate_per_second: U256) -> Result<(), OracleError> {
        self.only_updater()?;
        let now = U256::from(self.vm().block_timestamp());
        self.nav0.setter(vault).set(nav0);
        self.rate_per_second.setter(vault).set(rate_per_second);
        self.t0.setter(vault).set(now);
        self.vm().log(VaultConfigured { vault, nav0, ratePerSecond: rate_per_second });
        Ok(())
    }

    /// Simulate a credit event: snap NAV down to `new_nav` and re-anchor `t0`.
    /// The rate is preserved so the vault keeps accruing from the lower base.
    pub fn crash(&mut self, vault: Address, new_nav: U256) -> Result<(), OracleError> {
        self.only_updater()?;
        let old = self.nav_of(vault);
        let now = U256::from(self.vm().block_timestamp());
        self.nav0.setter(vault).set(new_nav);
        self.t0.setter(vault).set(now);
        self.vm().log(NavCrashed { vault, oldNav: old, newNav: new_nav });
        Ok(())
    }

    /// Live NAV-per-share for a vault (WAD). Pure function of block.timestamp.
    pub fn nav_of(&self, vault: Address) -> U256 {
        let base = self.nav0.get(vault);
        if base.is_zero() {
            return U256::ZERO;
        }
        let t0 = self.t0.get(vault);
        let now = U256::from(self.vm().block_timestamp());
        let dt = now.saturating_sub(t0);
        base + self.rate_per_second.get(vault).saturating_mul(dt)
    }

    pub fn rate_of(&self, vault: Address) -> U256 {
        self.rate_per_second.get(vault)
    }
}

impl NavOracle {
    fn only_owner(&self) -> Result<(), OracleError> {
        if self.vm().msg_sender() != self.owner.get() {
            return Err(OracleError::NotOwner(NotOwner {}));
        }
        Ok(())
    }
    fn only_updater(&self) -> Result<(), OracleError> {
        if !self.updaters.get(self.vm().msg_sender()) {
            return Err(OracleError::NotUpdater(NotUpdater {}));
        }
        Ok(())
    }
}

#[cfg(test)]
mod test {
    use super::*;
    const WAD: u128 = 1_000_000_000_000_000_000;
    use stylus_sdk::testing::*;

    #[test]
    fn accrues_and_crashes() {
        let vm = TestVM::default();
        let mut o = NavOracle::from(&vm);
        o.initialize();
        let vault = Address::from([3u8; 20]);
        // nav0 = 1.00, +1e9 wad/sec
        vm.set_block_timestamp(1000);
        assert!(o.set_vault(vault, U256::from(WAD), U256::from(1_000_000_000u64)).is_ok());
        assert_eq!(o.nav_of(vault), U256::from(WAD));
        vm.set_block_timestamp(1100); // +100s
        assert_eq!(o.nav_of(vault), U256::from(WAD) + U256::from(100_000_000_000u64));
        // crash to 0.5
        assert!(o.crash(vault, U256::from(WAD / 2)).is_ok());
        assert_eq!(o.nav_of(vault), U256::from(WAD / 2));
    }
}
