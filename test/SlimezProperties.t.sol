// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {Slimez} from "../src/Slimez.sol";

/// @dev Deploys with plain CREATE (the existing launch test covers CREATE2) and relays transfers,
///      so the test can act as the factory the launch deploys through.
contract SlimezCreateFactory {
    address private immutable controller = msg.sender;

    modifier onlyController() {
        require(msg.sender == controller, "fixture controller only");
        _;
    }

    function deploy() external onlyController returns (Slimez) {
        return new Slimez();
    }

    function move(Slimez token, address to, uint256 amount) external onlyController returns (bool) {
        return token.transfer(to, amount);
    }
}

/// @dev A recipient whose every entry point reverts. If the token called a receiver hook on
///      transfer, sending to this contract would fail.
contract RevertingRecipient {
    fallback() external payable {
        revert("recipient rejects every call");
    }
}

/// @notice Edge-case and property tests that the base suite does not pin: arbitrary addresses,
///         the exact ABI surface, malformed calldata, allowance edges, round trips, and a local
///         replica of the admission floor's privileged-call probes. Nothing here changes the
///         implementation's expected behaviour; where a behaviour is a documented ERC-20
///         limitation rather than a defect, the test says so.
/// forge-config: default.fuzz.runs = 1000
contract SlimezPropertiesTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000 * 10 ** 18;

    Slimez internal token;
    address internal alice;
    address internal bob;
    address internal spender;

    function setUp() public {
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        spender = makeAddr("spender");
        token = new Slimez();
    }

    // ---------------------------------------------------------------------------------------
    // Deployment edges
    // ---------------------------------------------------------------------------------------

    function testFuzz_WhoeverRunsTheConstructorReceivesTheWholeSupply(address deployer) public {
        deployer = _nonZero(deployer);
        vm.prank(deployer);
        Slimez fresh = new Slimez();
        assertEq(fresh.totalSupply(), SUPPLY);
        assertEq(fresh.balanceOf(deployer), SUPPLY);
        assertEq(fresh.balanceOf(address(this)), 0);
        assertEq(fresh.decimals(), 18);
        assertEq(fresh.name(), "Slimez");
        assertEq(fresh.symbol(), "SLIMEZ");
    }

    /// @dev The mint target is msg.sender and OpenZeppelin refuses to mint to the zero address, so a
    ///      constructor call whose sender is zero cannot complete. Pinned so the failure is explicit.
    function test_RevertConstructorWhenSenderIsZeroAddress() public {
        vm.prank(address(0));
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        new Slimez();
    }

    function test_CreateFactoryReceivesSupplyNotItsCaller() public {
        SlimezCreateFactory factory = new SlimezCreateFactory();
        vm.recordLogs();
        Slimez launched = factory.deploy();
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(logs.length, 1, "exactly one mint event");
        assertEq(logs[0].emitter, address(launched));
        assertEq(logs[0].topics[1], bytes32(0));
        assertEq(logs[0].topics[2], bytes32(uint256(uint160(address(factory)))));
        assertEq(abi.decode(logs[0].data, (uint256)), SUPPLY);
        assertEq(launched.balanceOf(address(factory)), SUPPLY);
        assertEq(launched.balanceOf(address(this)), 0);
        assertEq(launched.balanceOf(tx.origin), 0);
        assertEq(launched.totalSupply(), SUPPLY);
    }

    function test_TwoDeploymentsDoNotShareState() public {
        vm.prank(alice);
        Slimez other = new Slimez();
        token.transfer(bob, 1 ether);
        token.approve(spender, 2 ether);

        assertEq(other.balanceOf(bob), 0);
        assertEq(other.balanceOf(address(this)), 0);
        assertEq(other.balanceOf(alice), SUPPLY);
        assertEq(other.allowance(address(this), spender), 0);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.totalSupply() + other.totalSupply(), 2 * SUPPLY);
    }

    function test_ConstructorIgnoresAppendedArgumentsAndValueIsRejected() public {
        bytes memory withArgs = abi.encodePacked(type(Slimez).creationCode, abi.encode(alice, uint256(1)));
        address deployed;
        assembly ("memory-safe") {
            deployed := create(0, add(withArgs, 32), mload(withArgs))
        }
        assertTrue(deployed != address(0), "deployment with stray arguments failed");
        assertEq(Slimez(deployed).balanceOf(address(this)), SUPPLY, "stray arguments changed the recipient");
        assertEq(Slimez(deployed).balanceOf(alice), 0);

        bytes memory code = type(Slimez).creationCode;
        vm.deal(address(this), 1 ether);
        address funded;
        assembly ("memory-safe") {
            funded := create(1, add(code, 32), mload(code))
        }
        assertEq(funded, address(0), "a non-payable constructor accepted ETH");
    }

    // ---------------------------------------------------------------------------------------
    // Transfers to arbitrary addresses
    // ---------------------------------------------------------------------------------------

    function testFuzz_TransferToAnyNonZeroAddressDeliversExactly(address to, uint256 amount) public {
        to = _nonZero(to);
        amount = bound(amount, 0, SUPPLY);
        uint256 toBefore = token.balanceOf(to);
        uint256 selfBefore = token.balanceOf(address(this));

        vm.expectEmit(true, true, false, true, address(token));
        emit IERC20.Transfer(address(this), to, amount);
        assertTrue(token.transfer(to, amount));

        if (to == address(this)) {
            assertEq(token.balanceOf(to), selfBefore);
        } else {
            assertEq(token.balanceOf(to), toBefore + amount);
            assertEq(token.balanceOf(address(this)), selfBefore - amount);
        }
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_TwoTransfersEqualOneTransfer(uint256 first, uint256 second) public {
        first = bound(first, 0, SUPPLY);
        second = bound(second, 0, SUPPLY - first);
        token.transfer(alice, first);
        token.transfer(alice, second);
        assertEq(token.balanceOf(alice), first + second, "split transfers lost or gained units");
        assertEq(token.balanceOf(address(this)), SUPPLY - first - second);
    }

    function testFuzz_RoundTripRestoresEveryBalance(uint256 seedA, uint256 seedB, uint256 amount) public {
        address a = _derived("round trip a", seedA);
        address b = _derived("round trip b", seedB);
        amount = bound(amount, 0, SUPPLY);

        token.transfer(a, amount);
        vm.prank(a);
        token.transfer(b, amount);
        assertEq(token.balanceOf(b), amount);
        assertEq(token.balanceOf(a), a == b ? amount : 0);
        vm.prank(b);
        token.transfer(a, amount);
        assertEq(token.balanceOf(a), amount);
        vm.prank(a);
        token.transfer(address(this), amount);

        assertEq(token.balanceOf(address(this)), SUPPLY, "round trip did not return the full amount");
        assertEq(token.balanceOf(a), 0);
        assertEq(token.balanceOf(b), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_EmptyAccountCannotSendAnything(address from, uint256 amount) public {
        from = _nonZero(from);
        if (from == address(this)) from = alice;
        amount = bound(amount, 1, type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, from, 0, amount));
        vm.prank(from);
        token.transfer(bob, amount);
        assertEq(token.balanceOf(bob), 0);
    }

    function test_TransferToContractWithoutHookSucceeds() public {
        RevertingRecipient recipient = new RevertingRecipient();
        assertTrue(token.transfer(address(recipient), 1 ether));
        assertEq(token.balanceOf(address(recipient)), 1 ether);
    }

    /// @dev Standard ERC-20 behaviour, stated in the README: the token contract is an ordinary
    ///      recipient, and because there is no rescue function anything sent to it stays there.
    ///      This is a documented limitation of a fixed-supply token with no owner, not a defect.
    function test_TokensSentToTheContractItselfAreStranded() public {
        assertTrue(token.transfer(address(token), 1 ether));
        assertEq(token.balanceOf(address(token)), 1 ether);

        bytes[] memory attempts = new bytes[](4);
        attempts[0] = abi.encodeWithSignature("rescue(address,address,uint256)", address(token), alice, 1 ether);
        attempts[1] = abi.encodeWithSignature("recoverERC20(address,uint256)", address(token), 1 ether);
        attempts[2] = abi.encodeWithSignature("withdraw(uint256)", 1 ether);
        attempts[3] = abi.encodeWithSignature("sweep(address)", alice);
        for (uint256 i; i < attempts.length; ++i) {
            (bool ok,) = address(token).call(attempts[i]);
            assertFalse(ok);
        }
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(this), 0, 1));
        token.transferFrom(address(token), alice, 1);
        assertEq(token.balanceOf(address(token)), 1 ether);
        assertEq(token.totalSupply(), SUPPLY);
    }

    // ---------------------------------------------------------------------------------------
    // Allowance edges
    // ---------------------------------------------------------------------------------------

    function testFuzz_ApproveAlwaysReplacesAndIsIdempotent(uint256 first, uint256 second) public {
        token.approve(spender, first);
        assertEq(token.allowance(address(this), spender), first);
        token.approve(spender, first);
        assertEq(token.allowance(address(this), spender), first, "re-approving the same value changed it");
        token.approve(spender, second);
        assertEq(token.allowance(address(this), spender), second, "approve did not replace");
        assertEq(token.allowance(spender, address(this)), 0, "allowance leaked in the reverse direction");
        assertEq(token.balanceOf(address(this)), SUPPLY);
    }

    function testFuzz_ApprovalAboveBalanceIsAcceptedButSpendIsBoundedByBalance(uint256 allowed, uint256 amount) public {
        allowed = bound(allowed, SUPPLY + 1, type(uint256).max - 1);
        amount = bound(amount, SUPPLY + 1, allowed);
        token.approve(spender, allowed);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, address(this), SUPPLY, amount)
        );
        vm.prank(spender);
        token.transferFrom(address(this), alice, amount);
        assertEq(token.allowance(address(this), spender), allowed, "a failed spend consumed allowance");
        assertEq(token.balanceOf(alice), 0);
    }

    function testFuzz_UnlimitedAllowanceSurvivesRepeatedSpends(uint256 amount, uint8 rounds) public {
        rounds = uint8(bound(rounds, 1, 16));
        amount = bound(amount, 0, SUPPLY / rounds);
        token.approve(spender, type(uint256).max);
        for (uint256 i; i < rounds; ++i) {
            vm.recordLogs();
            vm.prank(spender);
            assertTrue(token.transferFrom(address(this), alice, amount));
            assertEq(vm.getRecordedLogs().length, 1, "an unlimited spend must emit only Transfer");
            assertEq(token.allowance(address(this), spender), type(uint256).max);
        }
        assertEq(token.balanceOf(alice), amount * rounds);
    }

    /// @dev One below the sentinel is an ordinary finite allowance and must be consumed.
    function testFuzz_OneBelowMaxAllowanceIsFinite(uint256 amount) public {
        amount = bound(amount, 1, SUPPLY);
        uint256 nearMax = type(uint256).max - 1;
        token.approve(spender, nearMax);
        vm.prank(spender);
        assertTrue(token.transferFrom(address(this), alice, amount));
        assertEq(token.allowance(address(this), spender), nearMax - amount, "near-max allowance treated as unlimited");
    }

    function testFuzz_SpendingExactAllowanceLeavesZeroAndBlocksTheNextUnit(uint256 amount) public {
        amount = bound(amount, 1, SUPPLY);
        token.approve(spender, amount);
        vm.prank(spender);
        assertTrue(token.transferFrom(address(this), alice, amount));
        assertEq(token.allowance(address(this), spender), 0);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 0, 1));
        vm.prank(spender);
        token.transferFrom(address(this), alice, 1);
        assertEq(token.balanceOf(alice), amount);
    }

    function testFuzz_AllowanceIsPerSpenderAndPerOwner(address other, uint256 amount) public {
        other = _nonZero(other);
        if (other == spender || other == address(this)) other = alice;
        amount = bound(amount, 1, SUPPLY);
        token.approve(spender, amount);
        assertEq(token.allowance(address(this), other), 0);
        assertEq(token.allowance(spender, address(this)), 0);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, other, 0, amount));
        vm.prank(other);
        token.transferFrom(address(this), other, amount);
        assertEq(token.balanceOf(other), 0);
    }

    function testFuzz_StrangerCannotSpendAHoldersTokens(address stranger, uint256 amount) public {
        stranger = _nonZero(stranger);
        if (stranger == address(this)) stranger = alice;
        amount = bound(amount, 1, SUPPLY);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, stranger, 0, amount));
        vm.prank(stranger);
        token.transferFrom(address(this), stranger, amount);
        assertEq(token.balanceOf(stranger), 0);
        assertEq(token.balanceOf(address(this)), SUPPLY);
    }

    /// @dev The classic ERC-20 approval race. It is inherent to approve/transferFrom, the README
    ///      tells holders to zero an allowance before changing it, and the floor does not forbid it,
    ///      so this pins the behaviour as a known limitation rather than asserting it is desirable.
    function test_ApprovalReplacementRaceIsStandardERC20Behaviour() public {
        token.approve(spender, 100 ether);
        vm.prank(spender);
        token.transferFrom(address(this), alice, 100 ether);
        token.approve(spender, 50 ether);
        vm.prank(spender);
        token.transferFrom(address(this), alice, 50 ether);
        assertEq(token.balanceOf(alice), 150 ether, "the spender obtained old plus new allowance");

        token.approve(spender, 0);
        token.approve(spender, 50 ether);
        vm.prank(spender);
        token.transferFrom(address(this), alice, 50 ether);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 0, 1));
        vm.prank(spender);
        token.transferFrom(address(this), alice, 1);
    }

    // ---------------------------------------------------------------------------------------
    // ABI surface and calldata hygiene
    // ---------------------------------------------------------------------------------------

    function testFuzz_UnknownSelectorsRevertWithoutData(bytes4 selector, bytes memory args) public {
        while (_isStandardSelector(selector)) {
            selector = bytes4(keccak256(abi.encode(selector)));
        }
        (bool ok, bytes memory ret) = address(token).call(abi.encodePacked(selector, args));
        assertFalse(ok, "an unknown selector was dispatched");
        assertEq(ret.length, 0, "an unknown selector reached a fallback that returned data");
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(address(this)), SUPPLY);
    }

    function test_OnlyTheNineStandardSelectorsAreDispatched() public {
        string[14] memory absent = [
            "increaseAllowance(address,uint256)",
            "decreaseAllowance(address,uint256)",
            "permit(address,address,uint256,uint256,uint8,bytes32,bytes32)",
            "nonces(address)",
            "DOMAIN_SEPARATOR()",
            "owner()",
            "paused()",
            "burn(uint256)",
            "mint(address,uint256)",
            "cap()",
            "renounceOwnership()",
            "supportsInterface(bytes4)",
            "distributorOf(uint64)",
            "exempt(address)"
        ];
        for (uint256 i; i < absent.length; ++i) {
            (bool ok, bytes memory ret) = address(token).call(abi.encodeWithSignature(absent[i], spender, 1));
            assertFalse(ok, absent[i]);
            assertEq(ret.length, 0, absent[i]);
        }

        assertEq(token.name(), "Slimez");
        assertEq(token.symbol(), "SLIMEZ");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.allowance(address(this), spender), 0);
        assertTrue(token.approve(spender, 1));
        assertTrue(token.transfer(alice, 1));
        vm.prank(spender);
        assertTrue(token.transferFrom(address(this), alice, 1));
    }

    function test_MalformedCalldataIsRejectedAtomically() public {
        bytes[] memory calls = new bytes[](6);
        calls[0] = abi.encodeWithSelector(token.transfer.selector, alice);
        calls[1] = abi.encodeWithSelector(token.transfer.selector);
        calls[2] = abi.encodeWithSelector(token.approve.selector, spender);
        calls[3] = abi.encodeWithSelector(token.transferFrom.selector, address(this), alice);
        calls[4] = hex"a9";
        calls[5] = "";
        for (uint256 i; i < calls.length; ++i) {
            (bool ok, bytes memory ret) = address(token).call(calls[i]);
            assertFalse(ok, "short calldata was accepted");
            assertEq(ret.length, 0);
        }
        bytes memory dirtyAddress =
            abi.encodeWithSelector(token.transfer.selector, bytes32(type(uint256).max), uint256(1));
        (bool dirty,) = address(token).call(dirtyAddress);
        assertFalse(dirty, "an address word with dirty upper bits was accepted");
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.allowance(address(this), spender), 0);
    }

    function test_ExtraCalldataAfterArgumentsIsTolerated() public {
        bytes memory padded =
            abi.encodePacked(abi.encodeWithSelector(token.transfer.selector, alice, uint256(5)), hex"deadbeef");
        (bool ok, bytes memory ret) = address(token).call(padded);
        assertTrue(ok);
        assertTrue(abi.decode(ret, (bool)));
        assertEq(token.balanceOf(alice), 5);
    }

    function test_ViewFunctionsAreSideEffectFreeForAnyCaller() public {
        vm.prank(alice);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        vm.prank(address(0));
        assertEq(token.totalSupply(), SUPPLY);
        vm.prank(address(0));
        assertEq(token.allowance(address(this), address(0)), 0);
        assertEq(token.balanceOf(address(this)), SUPPLY);
    }

    // ---------------------------------------------------------------------------------------
    // Local replica of the admission floor's privileged-call probes
    // ---------------------------------------------------------------------------------------

    /// @dev Mirrors the protected harness: every listed call is tried by a stranger and by the
    ///      factory that deployed the token, and the supply may not grow for either.
    function test_FloorNoCommonAdminCallIncreasesSupply() public {
        SlimezCreateFactory factory = new SlimezCreateFactory();
        Slimez launched = factory.deploy();
        address attacker = address(0xBEEF);
        string[10] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "mint()",
            "issue(uint256)",
            "setOwner(address)",
            "transferOwnership(address)",
            "upgradeTo(address)",
            "initialize(address)",
            "unpause()",
            "setMinter(address)"
        ];
        for (uint256 i; i < signatures.length; ++i) {
            bytes memory data = abi.encodeWithSignature(signatures[i], attacker, type(uint128).max);
            vm.prank(attacker);
            (bool ok,) = address(launched).call(data);
            assertFalse(ok, signatures[i]);
            assertEq(launched.totalSupply(), SUPPLY, signatures[i]);
            assertEq(launched.balanceOf(attacker), 0, signatures[i]);
            vm.prank(address(factory));
            (ok,) = address(launched).call(data);
            assertFalse(ok, signatures[i]);
            assertEq(launched.totalSupply(), SUPPLY, signatures[i]);
            assertEq(launched.balanceOf(address(factory)), SUPPLY, signatures[i]);
        }
    }

    /// @dev Mirrors the protected harness: after the factory tries every freeze, blocklist, lock and
    ///      seize call it can think of, a holder still holds what it held and can still transfer.
    function test_FloorNoPrivilegedHandMovesOrFreezesAHolder() public {
        SlimezCreateFactory factory = new SlimezCreateFactory();
        Slimez launched = factory.deploy();
        address holder = address(0x401D);
        address other = address(0x07E5);
        assertTrue(factory.move(launched, holder, SUPPLY / 1_000));
        uint256 held = launched.balanceOf(holder);
        assertEq(held, SUPPLY / 1_000);

        string[12] memory signatures = [
            "pause()",
            "blacklist(address)",
            "blocklist(address)",
            "freeze(address)",
            "freezeAccount(address)",
            "setBlacklist(address,bool)",
            "setBlocked(address,bool)",
            "lock(address)",
            "disableTransfers()",
            "setTransfersEnabled(bool)",
            "burnFrom(address,uint256)",
            "seize(address)"
        ];
        for (uint256 i; i < signatures.length; ++i) {
            vm.prank(address(factory));
            (bool ok,) = address(launched).call(abi.encodeWithSignature(signatures[i], holder, true));
            assertFalse(ok, signatures[i]);
        }
        vm.prank(address(factory));
        (bool moved,) =
            address(launched).call(abi.encodeWithSelector(launched.transferFrom.selector, holder, address(factory), 1));
        assertFalse(moved, "the factory moved a holder's balance without allowance");
        assertEq(launched.balanceOf(holder), held);
        vm.prank(holder);
        assertTrue(launched.transfer(other, held / 2));
        assertEq(launched.balanceOf(other), held / 2);
        assertEq(launched.balanceOf(holder), held - held / 2);
        assertEq(launched.totalSupply(), SUPPLY);
    }

    /// @dev The swarm share and a claim, computed exactly as the floor computes them.
    function test_FloorSwarmShareArrivesWholeAndIsClaimableWhole() public {
        SlimezCreateFactory factory = new SlimezCreateFactory();
        Slimez launched = factory.deploy();
        address distributor = address(0xD157);
        address claimant = address(0xC1A1);
        uint256 swarm = (SUPPLY * 1_000) / 10_000;

        assertTrue(factory.move(launched, distributor, swarm));
        assertEq(launched.balanceOf(distributor), swarm);
        vm.prank(distributor);
        assertTrue(launched.transfer(claimant, swarm));
        assertEq(launched.balanceOf(claimant), swarm);
        assertEq(launched.balanceOf(distributor), 0);
        assertEq(launched.totalSupply(), SUPPLY);
        assertEq(launched.balanceOf(address(factory)), SUPPLY - swarm);
    }

    function testFuzz_FactoryDistributionOfAnySplitIsExact(uint256 poolBps, uint256 seed) public {
        poolBps = bound(poolBps, 0, 9_000);
        SlimezCreateFactory factory = new SlimezCreateFactory();
        Slimez launched = factory.deploy();
        address distributor = _derived("distributor", seed);
        address pool = _derived("pool", seed);
        address remainderTo = _derived("remainder", seed);

        uint256 swarm = (SUPPLY * 1_000) / 10_000;
        uint256 poolShare = (SUPPLY * poolBps) / 10_000;
        uint256 remainder = SUPPLY - swarm - poolShare;
        assertTrue(factory.move(launched, distributor, swarm));
        assertTrue(factory.move(launched, pool, poolShare));
        assertTrue(factory.move(launched, remainderTo, remainder));

        assertEq(launched.balanceOf(address(factory)), 0, "the factory kept something back");
        assertEq(launched.balanceOf(distributor), swarm);
        assertEq(launched.balanceOf(pool), poolShare);
        assertEq(launched.balanceOf(remainderTo), remainder);
        assertEq(launched.balanceOf(distributor) + launched.balanceOf(pool) + launched.balanceOf(remainderTo), SUPPLY);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, address(factory), 0, 1));
        factory.move(launched, remainderTo, 1);
    }

    // ---------------------------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------------------------

    function _nonZero(address candidate) internal pure returns (address) {
        return address(uint160(bound(uint256(uint160(candidate)), 1, type(uint160).max)));
    }

    function _derived(string memory label, uint256 seed) internal pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encode(label, seed)))));
    }

    function _isStandardSelector(bytes4 selector) internal pure returns (bool) {
        return selector == IERC20.transfer.selector || selector == IERC20.approve.selector
            || selector == IERC20.transferFrom.selector || selector == IERC20.balanceOf.selector
            || selector == IERC20.allowance.selector || selector == IERC20.totalSupply.selector
            || selector == bytes4(keccak256("name()")) || selector == bytes4(keccak256("symbol()"))
            || selector == bytes4(keccak256("decimals()"));
    }
}
