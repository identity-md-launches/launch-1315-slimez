# Slimez (SLIMEZ)

A fixed supply ERC-20 built with Solidity 0.8.26 and vendored OpenZeppelin
Contracts v5.0.2. The complete supply is minted once, in the constructor, to
`msg.sender`.

| Deployment parameter | Value |
| --- | --- |
| Solidity contract | `src/Slimez.sol:Slimez` |
| Token name | `Slimez` |
| Token symbol | `SLIMEZ` |
| Decimals | `18` |
| Supply in whole tokens | `1,000,000,000` |
| Supply in base units | `1000000000000000000000000000` (`10^27`) |
| Constructor arguments | None (`[]`) |
| Constructor ETH value | `0` |
| Initial recipient | Constructor caller; the factory when factory-deployed |
| Intended launch chain | Ethereum, chain ID `1` |

## Build and test

Run from the repository root with Foundry and Solidity 0.8.26 installed:

```sh
forge build
forge test
forge fmt --check
```

Dependencies are ordinary source files under `lib/`; no installation, submodule,
RPC, wallet, environment configuration, or network access is needed once the
toolchain is present. `foundry.toml` pins the compiler, targets Cancun, enables
the optimizer with 200 runs, and sets `bytecode_hash = "none"`. FFI and filesystem
cheatcode access are disabled. Dependency versions and licenses are recorded in
`DEPENDENCIES.md`.

The tests exercise metadata, the single constructor mint, direct and CREATE2
factory deployment, exact transfers and allowances, events, zero amounts,
self-transfers, invalid recipients, insufficient balances/allowances, failure
atomicity, and the absence of mint/admin entry points. Fuzz tests cover amounts
and allowance bounds. Stateful invariant tests check conservation of all tokens
and an independent balance/allowance model across sequences of transfers,
approvals, and delegated transfers. Tests create their own state and do not read
or modify environment variables.

## Behavior and assumptions

- Standard ERC-20 transfers deliver exactly the requested base-unit amount.
  There are no taxes, transfer fees, rebases, supply changes, or address exemptions.
- Transfers to the zero address and approvals to the zero address revert. Zero
  amount transfers and self-transfers are allowed under normal balance and
  allowance rules. Failed operations revert all balance and allowance changes.
- `approve` replaces an allowance. Finite allowances decrease on `transferFrom`;
  `type(uint256).max` allowances remain unchanged. `transferFrom` requires an
  allowance even when the spender is also the holder. Holders should grant only
  the access they intend and revoke unused approvals. When changing a nonzero
  allowance, consider first setting it to zero in a separate confirmed transaction
  to mitigate the standard ERC-20 allowance replacement race.
- Minting and transfers emit `Transfer`; explicit approvals emit `Approval`.
  Allowance consumption does not emit `Approval` in this implementation; clients
  should query `allowance()` for its current value.
- There is no owner, mint/burn API, pause, blacklist, seizure, upgrade mechanism,
  permit, callback, or administrative recovery function. The deployer controls
  only the tokens it holds and the allowances other holders explicitly grant it.
- Transfers to nonzero contracts are allowed without a receiver callback. Tokens
  sent to a contract that cannot return them, including this token contract, can
  be permanently inaccessible. Ordinary ETH transfers are rejected; forcibly
  delivered ETH or unrelated tokens have no recovery path.

## Deployment and operational responsibilities

Use the compiled creation bytecode in `out/Slimez.sol/Slimez.json`, with no appended
constructor arguments and no ETH. No external contracts, addresses, or post-deploy
initialization are required. The constructor performs no external calls. A
factory deploying with CREATE or CREATE2 receives all `10^27` units, rather than
the account that called the factory. A direct deployment credits the deploying
account. Use the intended launch factory when its distribution workflow is needed.

The launch system is responsible for constructing its manifest, deploying the
token, distributing the supply, creating/funding the pool, and handling claims.
These are external operations, not token constructor logic. The token does not
reserve balances or special permissions for any participant. No launch manifest,
application contracts, live transactions, or wallet keys are part of this project.

After launch, the operator should verify the source and compiler settings on the
explorer and check the constructor's mint event, metadata, and total supply.
For a factory launch, also reconcile the factory's distribution events and ending
balances; the factory may distribute everything in the deployment transaction.
There are no owner settings or recurring privileged maintenance tasks. Holders
are responsible for their keys, recipient addresses, and approvals; integrations
must display balances using 18 decimals.

Local verification is not an independent security audit. Production deployment
and independent adversarial review remain the launch operator's responsibility.
See `SECURITY_REVIEW.md` for the scope and limits of the local review.
