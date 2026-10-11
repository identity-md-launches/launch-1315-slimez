# Vendored dependencies

All listed sources are included as ordinary files, with upstream licenses.
The project requires no dependency downloads to build or test. No Git submodules
or package-manager installation steps are used.

| Dependency | Version | Included files | License |
| --- | --- | --- | --- |
| [OpenZeppelin Contracts](https://github.com/OpenZeppelin/openzeppelin-contracts/tree/v5.0.2) | `v5.0.2` | ERC20, IERC20, IERC20Metadata, Context, draft-IERC6093 | MIT (`lib/openzeppelin-contracts/LICENSE`) |
| [forge-std](https://github.com/foundry-rs/forge-std/tree/v1.9.7) | `v1.9.7` | Upstream `src/` (test support only) | MIT or Apache-2.0 (`lib/forge-std/LICENSE-*`) |

Sources and licenses are unmodified. Only the transitive OpenZeppelin files needed
by this token are included. `lib/SHA256SUMS` records every vendored file's hash;
run `sha256sum -c lib/SHA256SUMS` from the repository root to check them.

Source archive SHA-256 hashes:

```text
18c7b7e949b9a82dcd8cd394426c9c2636dfc263aa2317d4749dbfa0c7b3925a  https://codeload.github.com/OpenZeppelin/openzeppelin-contracts/tar.gz/refs/tags/v5.0.2
45157353ab49eab01d294565866731e599b32401757229689ee459aa26b7ee94  https://codeload.github.com/foundry-rs/forge-std/tar.gz/refs/tags/v1.9.7
```
