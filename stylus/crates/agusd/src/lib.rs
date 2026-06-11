//! agUSD — the Agama synthetic dollar. ERC-20, 18 decimals.
//!
//! Minted 1:1 to lenders when they deposit USDC into the LendingPool, and minted
//! as accrued interest to the SagUSD staking contract. `mint`/`burn` are restricted
//! to the `pool` (set once by the deployer).
#![cfg_attr(not(any(test, feature = "export-abi")), no_main)]
extern crate alloc;

use alloc::{string::String, vec::Vec};
use stylus_sdk::{
    alloy_primitives::{Address, U256},
    alloy_sol_types::sol,
    prelude::*,
};

sol! {
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    error InsufficientBalance();
    error InsufficientAllowance();
    error NotPool();
    error AlreadyInitialized();
}

#[derive(SolidityError)]
pub enum AgusdError {
    InsufficientBalance(InsufficientBalance),
    InsufficientAllowance(InsufficientAllowance),
    NotPool(NotPool),
    AlreadyInitialized(AlreadyInitialized),
}

sol_storage! {
    #[entrypoint]
    pub struct Agusd {
        mapping(address => uint256) balances;
        mapping(address => mapping(address => uint256)) allowances;
        uint256 total_supply;
        address pool;
    }
}

#[public]
impl Agusd {
    /// One-time wiring of the controlling pool. Callable once.
    pub fn initialize(&mut self, pool: Address) -> Result<(), AgusdError> {
        if self.pool.get() != Address::ZERO {
            return Err(AgusdError::AlreadyInitialized(AlreadyInitialized {}));
        }
        self.pool.set(pool);
        Ok(())
    }

    pub fn name(&self) -> String {
        String::from("Agama USD")
    }
    pub fn symbol(&self) -> String {
        String::from("agUSD")
    }
    pub fn decimals(&self) -> u8 {
        18
    }
    pub fn pool(&self) -> Address {
        self.pool.get()
    }
    pub fn total_supply(&self) -> U256 {
        self.total_supply.get()
    }
    pub fn balance_of(&self, who: Address) -> U256 {
        self.balances.get(who)
    }
    pub fn allowance(&self, owner: Address, spender: Address) -> U256 {
        self.allowances.getter(owner).get(spender)
    }

    /// Pool-only mint.
    pub fn mint(&mut self, to: Address, amount: U256) -> Result<(), AgusdError> {
        self.only_pool()?;
        let new_bal = self.balances.get(to) + amount;
        self.balances.setter(to).set(new_bal);
        self.total_supply.set(self.total_supply.get() + amount);
        self.vm().log(Transfer { from: Address::ZERO, to, value: amount });
        Ok(())
    }

    /// Pool-only burn.
    pub fn burn(&mut self, from: Address, amount: U256) -> Result<(), AgusdError> {
        self.only_pool()?;
        let bal = self.balances.get(from);
        if bal < amount {
            return Err(AgusdError::InsufficientBalance(InsufficientBalance {}));
        }
        self.balances.setter(from).set(bal - amount);
        self.total_supply.set(self.total_supply.get() - amount);
        self.vm().log(Transfer { from, to: Address::ZERO, value: amount });
        Ok(())
    }

    pub fn approve(&mut self, spender: Address, amount: U256) -> bool {
        let owner = self.vm().msg_sender();
        self.allowances.setter(owner).insert(spender, amount);
        self.vm().log(Approval { owner, spender, value: amount });
        true
    }

    pub fn transfer(&mut self, to: Address, amount: U256) -> Result<bool, AgusdError> {
        let from = self.vm().msg_sender();
        self._transfer(from, to, amount)?;
        Ok(true)
    }

    pub fn transfer_from(&mut self, from: Address, to: Address, amount: U256) -> Result<bool, AgusdError> {
        let spender = self.vm().msg_sender();
        let cur = self.allowances.getter(from).get(spender);
        if cur < amount {
            return Err(AgusdError::InsufficientAllowance(InsufficientAllowance {}));
        }
        if cur != U256::MAX {
            self.allowances.setter(from).insert(spender, cur - amount);
        }
        self._transfer(from, to, amount)?;
        Ok(true)
    }
}

impl Agusd {
    fn only_pool(&self) -> Result<(), AgusdError> {
        if self.vm().msg_sender() != self.pool.get() {
            return Err(AgusdError::NotPool(NotPool {}));
        }
        Ok(())
    }

    fn _transfer(&mut self, from: Address, to: Address, amount: U256) -> Result<(), AgusdError> {
        let bal = self.balances.get(from);
        if bal < amount {
            return Err(AgusdError::InsufficientBalance(InsufficientBalance {}));
        }
        self.balances.setter(from).set(bal - amount);
        let to_bal = self.balances.get(to) + amount;
        self.balances.setter(to).set(to_bal);
        self.vm().log(Transfer { from, to, value: amount });
        Ok(())
    }
}

#[cfg(test)]
mod test {
    use super::*;
    use stylus_sdk::testing::*;

    #[test]
    fn mint_requires_pool() {
        let vm = TestVM::default();
        let mut t = Agusd::from(&vm);
        let pool = vm.msg_sender();
        assert!(t.initialize(pool).is_ok());
        // second init fails
        assert!(t.initialize(pool).is_err());
        let alice = Address::from([9u8; 20]);
        assert!(t.mint(alice, U256::from(1000u64)).is_ok());
        assert_eq!(t.balance_of(alice), U256::from(1000u64));
        assert!(t.burn(alice, U256::from(400u64)).is_ok());
        assert_eq!(t.balance_of(alice), U256::from(600u64));
    }
}
