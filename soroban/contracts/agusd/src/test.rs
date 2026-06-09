#![cfg(test)]
use super::*;
use mock_usdc::{MockUsdc, MockUsdcClient};
use soroban_sdk::{testutils::Address as _, Address, Env, String};

struct Fix {
    e: Env,
    usdc: MockUsdcClient<'static>,
    ag: AgUsdClient<'static>,
    treasury: Address,
}

fn setup() -> Fix {
    let e = Env::default();
    e.mock_all_auths();
    let admin = Address::generate(&e);
    let treasury = Address::generate(&e);

    let usdc_id = e.register(MockUsdc, ());
    let usdc = MockUsdcClient::new(&e, &usdc_id);
    usdc.initialize(
        &admin,
        &7u32,
        &String::from_str(&e, "USD Coin"),
        &String::from_str(&e, "USDC"),
    );

    let ag_id = e.register(AgUsd, ());
    let ag = AgUsdClient::new(&e, &ag_id);
    ag.initialize(
        &admin,
        &usdc_id,
        &treasury,
        &7u32,
        &String::from_str(&e, "Agama USD"),
        &String::from_str(&e, "agUSD"),
    );
    Fix { e, usdc, ag, treasury }
}

#[test]
fn deposit_mints_one_to_one() {
    let f = setup();
    let user = Address::generate(&f.e);
    f.usdc.faucet(&user, &1_000_0000000);

    f.ag.deposit(&user, &600_0000000);
    assert_eq!(f.ag.balance(&user), 600_0000000); // 1:1
    assert_eq!(f.usdc.balance(&user), 400_0000000);
    assert_eq!(f.ag.reserve(), 600_0000000);
}

#[test]
fn redeem_returns_usdc_one_to_one() {
    let f = setup();
    let user = Address::generate(&f.e);
    f.usdc.faucet(&user, &1_000_0000000);
    f.ag.deposit(&user, &600_0000000);

    f.ag.redeem(&user, &250_0000000);
    assert_eq!(f.ag.balance(&user), 350_0000000);
    assert_eq!(f.usdc.balance(&user), 650_0000000);
    assert_eq!(f.ag.reserve(), 350_0000000);
}

#[test]
fn sweep_moves_reserve_to_treasury() {
    let f = setup();
    let user = Address::generate(&f.e);
    f.usdc.faucet(&user, &1_000_0000000);
    f.ag.deposit(&user, &1_000_0000000);

    f.ag.sweep(&900_0000000); // keep 100 buffer
    assert_eq!(f.ag.reserve(), 100_0000000);
    assert_eq!(f.usdc.balance(&f.treasury), 900_0000000);

    // treasury can refund the reserve so redemptions clear
    f.ag.refund_reserve(&f.treasury, &900_0000000);
    assert_eq!(f.ag.reserve(), 1_000_0000000);
}
