# Local security review

Scope: `src/Slimez.sol`, the vendored OpenZeppelin ERC-20 implementation and its
dependencies, the compiled token ABI/runtime, and the delivered Foundry tests.
The supplied pinned security reference and protected custom-token checks were
read to identify applicable risks. This review was performed during
implementation and is not an independent audit.

## Findings and design checks

| Concern | Result |
| --- | --- |
| Supply and decimals | Exactly `10^27` base units, representing one billion tokens with 18 decimals. The constructor is the only call to `_mint`. There is no public burn or mint entry point. |
| Deployment recipient | The whole supply goes to `msg.sender`. Tests cover a direct account and a CREATE2 factory, including the predicted address and the constructor mint event. No `tx.origin` use or fixed recipient. |
| Administrative powers | The ABI has only the nine standard ERC-20/metadata functions. No owner, role, initializer, proxy, pause, blacklist, seizure, or upgrade entry point. Attempted admin/mint/burn calls revert for both deployer and stranger. |
| Balance and allowance arithmetic | Unmodified OpenZeppelin ERC20 checks balances and allowances before subtraction. Its unchecked arithmetic relies on supply conservation and those bounds. Independent model invariants test balances, finite/infinite allowances, and their conservation across operation sequences. |
| Failure atomicity | Rejected transfers preserve balances. Insufficient balance and invalid receiver failures in `transferFrom` also roll back allowance consumption. Unit tests verify these cases and exact custom errors. |
| Transfer compatibility | Transfers return `true` and deliver the exact amount without tax, burn, callbacks, or address restrictions. Local fixtures exercise factory distribution, a claim, and tokens moving into and out of a contract representing pool custody. |
| External calls and reentrancy | Neither construction nor token operations call external contracts. No receiver callbacks, oracle, randomness, external configuration, or reentrancy surface is introduced. |
| Bytecode | Runtime is 1,722 bytes; creation code is 2,607 bytes with the pinned settings. No unresolved library links. A test checks deployed-code size and scans opcodes, skipping PUSH data, for DELEGATECALL, CALLCODE, and SELFDESTRUCT. |
| Approval semantics | Explicit approvals replace prior values; infinite approvals persist. The standard approval replacement race remains a holder/integration responsibility, described in the README. |
| Asset recovery | There is no rescue function. Nonzero contract recipients may be unable to return tokens. Ordinary ETH sends revert, but forcibly sent assets are not recoverable. |

## Validation

- `forge build` and `forge test` with the pinned Solidity 0.8.26 compiler.
- A clean rebuild with `forge build --offline --force`, followed by
  `forge test --offline --threads 4`, both with an empty process environment
  except `PATH`: all 32 reported tests passed, with no failures or skips.
- 28 unit/fuzz tests and 3 deployment/launch-compatibility tests.
- Two stateful invariant properties over 128 runs at depth 64 (8,192 handler
  operations); unexpected handler reverts fail the suite. Expected invalid
  operations are checked with exact revert data.
- Four amount/allowance fuzz tests with 512 cases each.
- `forge fmt --check` and SHA-256 verification of all vendored dependency files.
- Inspection of the compiled ABI, constructor inputs, bytecode lengths, and
  library link references.

The local suite uses only local EVM state; it does not run a mainnet fork or the
supplied protected harness. That harness depends on external launch contracts,
Uniswap v4, and deployment-specific manifest values supplied by the admission
process. The custody fixture tests exact token movements, not actual AMM pricing,
liquidity seeding, or swaps. The network's protected integration checks remain the
authority for those flows.

Slither and Mythril were not run. No deployment, explorer verification, live
transaction, or independent adversarial review was performed. These are outside
this local implementation; the launch operator remains responsible for release
review, deployment, supply distribution, and explorer verification.
