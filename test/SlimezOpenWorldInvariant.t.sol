// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {Slimez} from "../src/Slimez.sol";

/// @notice Drives the token with an open set of actors: six named holders plus any address the
///         fuzzer produces, which then joins the actor set. Ghost variables record what every
///         touched address should hold, how much flowed in and out of it, and every approval,
///         so the invariants compare the token against independent accounting rather than
///         against itself. Rejected operations are exercised with exact revert data so the
///         failure paths are covered by the same random sequences.
contract SlimezOpenWorldHandler is Test {
    uint256 internal constant SUPPLY = 1_000_000_000 * 10 ** 18;
    uint256 internal constant MAX_ACTORS = 24;

    Slimez public immutable token;
    address public immutable initialHolder;
    address public immutable harness = msg.sender;

    address[] public actors;
    address[] public touched;
    mapping(address => bool) public isTouched;
    mapping(address => uint256) public ghostBalance;
    mapping(address => uint256) public ghostIn;
    mapping(address => uint256) public ghostOut;

    struct Pair {
        address owner;
        address spender;
    }

    Pair[] public approvedPairs;
    mapping(address => mapping(address => bool)) public pairRecorded;
    mapping(address => mapping(address => uint256)) public ghostAllowance;

    uint256 public ghostVolume;
    uint256 public acceptedCalls;
    uint256 public rejectedCalls;

    constructor(Slimez token_, address initialHolder_) {
        token = token_;
        initialHolder = initialHolder_;
        _touch(initialHolder_, true);
        ghostBalance[initialHolder_] = SUPPLY;
        ghostIn[initialHolder_] = SUPPLY;

        string[5] memory names = ["ow bob", "ow carol", "ow dave", "ow erin", "ow frank"];
        for (uint256 i; i < names.length; ++i) {
            _touch(makeAddr(names[i]), true);
        }
    }

    // ----------------------------------------------------------------- accepted operations

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        amount = bound(amount, 0, ghostBalance[from]);
        _transfer(from, to, amount);
    }

    function transferAll(uint256 fromSeed, uint256 toSeed) external {
        address from = _actor(fromSeed);
        _transfer(from, _actor(toSeed), ghostBalance[from]);
    }

    function selfTransfer(uint256 seed, uint256 amount) external {
        address who = _actor(seed);
        amount = bound(amount, 0, ghostBalance[who]);
        _transfer(who, who, amount);
    }

    /// @dev A fresh address from the fuzzer receives tokens and becomes an actor.
    function transferToStranger(uint256 fromSeed, address stranger, uint256 amount) external {
        stranger = _plausibleStranger(stranger);
        address from = _actor(fromSeed);
        amount = bound(amount, 0, ghostBalance[from]);
        _touch(stranger, true);
        _transfer(from, stranger, amount);
    }

    /// @dev The token contract is an ordinary recipient with no way to send; whatever arrives stays.
    ///      It is tracked but never acts, since the contract never calls itself.
    function transferToTokenContract(uint256 fromSeed, uint256 amount) external {
        address from = _actor(fromSeed);
        uint256 cap = ghostBalance[from] / 1_000;
        amount = bound(amount, 0, cap);
        _touch(address(token), false);
        _transfer(from, address(token), amount);
    }

    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 amount, uint8 mode) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        mode = uint8(bound(mode, 0, 3));
        if (mode == 0) amount = bound(amount, 0, SUPPLY);
        else if (mode == 1) amount = bound(amount, SUPPLY + 1, type(uint256).max - 1);
        else if (mode == 2) amount = type(uint256).max;
        else amount = 0;

        vm.prank(owner);
        assertTrue(token.approve(spender, amount), "approve returned false");
        ghostAllowance[owner][spender] = amount;
        _recordPair(owner, spender);
        acceptedCalls++;
    }

    function transferFrom(uint256 fromSeed, uint256 toSeed, uint256 spenderSeed, uint256 amount) external {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        address spender = _actor(spenderSeed);
        uint256 allowed = ghostAllowance[from][spender];
        uint256 cap = ghostBalance[from] < allowed ? ghostBalance[from] : allowed;
        amount = bound(amount, 0, cap);

        vm.prank(spender);
        assertTrue(token.transferFrom(from, to, amount), "transferFrom returned false");
        _book(from, to, amount);
        if (allowed != type(uint256).max) ghostAllowance[from][spender] = allowed - amount;
        acceptedCalls++;
    }

    /// @dev Forward then reverse within one call must leave every balance exactly where it began.
    function roundTrip(uint256 aSeed, uint256 bSeed, uint256 amount) external {
        address a = _actor(aSeed);
        address b = _actor(bSeed);
        amount = bound(amount, 0, ghostBalance[a]);
        uint256 aBefore = token.balanceOf(a);
        uint256 bBefore = token.balanceOf(b);

        _transfer(a, b, amount);
        _transfer(b, a, amount);

        assertEq(token.balanceOf(a), aBefore, "round trip changed the sender's balance");
        assertEq(token.balanceOf(b), bBefore, "round trip changed the receiver's balance");
    }

    // ----------------------------------------------------------------- rejected operations

    function overdraw(uint256 fromSeed, uint256 toSeed, uint256 excess) external {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        uint256 balance = ghostBalance[from];
        uint256 amount = balance + bound(excess, 1, SUPPLY);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, from, balance, amount));
        vm.prank(from);
        token.transfer(to, amount);
        rejectedCalls++;
    }

    function overspend(uint256 fromSeed, uint256 toSeed, uint256 spenderSeed, uint256 excess) external {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        address spender = _actor(spenderSeed);
        uint256 allowed = ghostAllowance[from][spender];
        if (allowed == type(uint256).max) {
            // Unlimited allowance: the only remaining limit is the balance.
            uint256 balance = ghostBalance[from];
            uint256 amount = balance + bound(excess, 1, SUPPLY);
            vm.expectRevert(
                abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, from, balance, amount)
            );
            vm.prank(spender);
            token.transferFrom(from, to, amount);
            rejectedCalls++;
            return;
        }
        uint256 headroom = type(uint256).max - allowed;
        uint256 over = allowed + bound(excess, 1, headroom < SUPPLY ? headroom : SUPPLY);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, allowed, over)
        );
        vm.prank(spender);
        token.transferFrom(from, to, over);
        rejectedCalls++;
    }

    function strangerSpendsWithoutAllowance(uint256 seed, uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address spender = address(uint160(uint256(keccak256(abi.encode("never approved", seed)))));
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        if (ghostAllowance[from][spender] != 0) return;
        amount = bound(amount, 1, SUPPLY);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 0, amount));
        vm.prank(spender);
        token.transferFrom(from, to, amount);
        rejectedCalls++;
    }

    function transferToZero(uint256 fromSeed, uint256 amount) external {
        address from = _actor(fromSeed);
        amount = bound(amount, 0, ghostBalance[from]);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(from);
        token.transfer(address(0), amount);
        rejectedCalls++;
    }

    function transferFromToZero(uint256 fromSeed, uint256 spenderSeed, uint256 amount) external {
        address from = _actor(fromSeed);
        address spender = _actor(spenderSeed);
        uint256 allowed = ghostAllowance[from][spender];
        uint256 cap = ghostBalance[from] < allowed ? ghostBalance[from] : allowed;
        amount = bound(amount, 0, cap);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(spender);
        token.transferFrom(from, address(0), amount);
        rejectedCalls++;
    }

    function approveZeroSpender(uint256 ownerSeed, uint256 amount) external {
        address owner = _actor(ownerSeed);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        vm.prank(owner);
        token.approve(address(0), amount);
        rejectedCalls++;
    }

    function privilegedCall(uint256 callerSeed, uint256 which, uint256 amount) external {
        string[12] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "burn(uint256)",
            "burnFrom(address,uint256)",
            "pause()",
            "blacklist(address)",
            "freeze(address)",
            "seize(address)",
            "transferOwnership(address)",
            "upgradeTo(address)",
            "initialize(address)",
            "setMinter(address)"
        ];
        address caller = _actor(callerSeed);
        address target = _actor(which);
        bytes memory data = abi.encodeWithSignature(signatures[which % signatures.length], target, amount);
        vm.prank(caller);
        (bool ok, bytes memory ret) = address(token).call(data);
        assertFalse(ok, "a privileged selector was dispatched");
        assertEq(ret.length, 0, "a privileged selector returned data");
        rejectedCalls++;
    }

    function sendEther(uint256 seed, uint256 amount) external {
        address from = _actor(seed);
        amount = bound(amount, 0, 1 ether);
        vm.deal(from, amount);
        vm.prank(from);
        (bool ok,) = address(token).call{value: amount}("");
        assertFalse(ok, "the token accepted ETH");
        rejectedCalls++;
    }

    // ----------------------------------------------------------------- views for invariants

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function touchedCount() external view returns (uint256) {
        return touched.length;
    }

    function approvedPairCount() external view returns (uint256) {
        return approvedPairs.length;
    }

    // ----------------------------------------------------------------- internals

    function _transfer(address from, address to, uint256 amount) internal {
        vm.prank(from);
        assertTrue(token.transfer(to, amount), "transfer returned false");
        _book(from, to, amount);
        acceptedCalls++;
    }

    function _book(address from, address to, uint256 amount) internal {
        ghostBalance[from] -= amount;
        ghostBalance[to] += amount;
        ghostOut[from] += amount;
        ghostIn[to] += amount;
        ghostVolume += amount;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function _touch(address who, bool mayAct) internal {
        if (isTouched[who]) return;
        isTouched[who] = true;
        touched.push(who);
        if (mayAct && actors.length < MAX_ACTORS) actors.push(who);
    }

    /// @dev Any address the fuzzer produces, except the zero address and the handful of addresses
    ///      that are part of the harness rather than the world: those are remapped deterministically
    ///      so the fuzzer still steers the choice but never impersonates the test machinery.
    function _plausibleStranger(address candidate) internal view returns (address) {
        address stranger = address(uint160(bound(uint256(uint160(candidate)), 1, type(uint160).max)));
        while (
            stranger == address(token) || stranger == address(this) || stranger == harness || stranger == VM_ADDRESS
                || stranger == CONSOLE
        ) {
            stranger = address(uint160(uint256(keccak256(abi.encode(stranger)))));
        }
        return stranger;
    }

    function _recordPair(address owner, address spender) internal {
        if (pairRecorded[owner][spender]) return;
        pairRecorded[owner][spender] = true;
        approvedPairs.push(Pair(owner, spender));
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract SlimezOpenWorldInvariantTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000 * 10 ** 18;

    Slimez internal token;
    SlimezOpenWorldHandler internal handler;
    bytes32 internal codeHashAtDeployment;

    function setUp() public {
        token = new Slimez();
        codeHashAtDeployment = address(token).codehash;
        address initialHolder = makeAddr("ow alice");
        handler = new SlimezOpenWorldHandler(token, initialHolder);
        token.transfer(initialHolder, SUPPLY);

        bytes4[] memory selectors = new bytes4[](16);
        selectors[0] = handler.transfer.selector;
        selectors[1] = handler.transferAll.selector;
        selectors[2] = handler.selfTransfer.selector;
        selectors[3] = handler.transferToStranger.selector;
        selectors[4] = handler.transferToTokenContract.selector;
        selectors[5] = handler.approve.selector;
        selectors[6] = handler.transferFrom.selector;
        selectors[7] = handler.roundTrip.selector;
        selectors[8] = handler.overdraw.selector;
        selectors[9] = handler.overspend.selector;
        selectors[10] = handler.strangerSpendsWithoutAllowance.selector;
        selectors[11] = handler.transferToZero.selector;
        selectors[12] = handler.transferFromToZero.selector;
        selectors[13] = handler.approveZeroSpender.selector;
        selectors[14] = handler.privilegedCall.selector;
        selectors[15] = handler.sendEther.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /// @dev The fixed supply never changes, and no address outside the touched set ever holds any.
    function invariant_SupplyIsFixedForever() public view {
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.balanceOf(address(handler)), 0);
        assertEq(token.balanceOf(address(this)), 0);
    }

    /// @dev Conservation: the sum over every address that ever received tokens is exactly the
    ///      supply, and each balance equals the ghost model and equals inflow minus outflow.
    function invariant_TouchedBalancesSumToSupplyAndMatchGhost() public view {
        uint256 count = handler.touchedCount();
        uint256 sum;
        for (uint256 i; i < count; ++i) {
            address who = handler.touched(i);
            uint256 balance = token.balanceOf(who);
            assertEq(balance, handler.ghostBalance(who), "balance diverged from the model");
            assertEq(balance, handler.ghostIn(who) - handler.ghostOut(who), "balance is not inflow minus outflow");
            assertLe(balance, SUPPLY, "a balance exceeds the supply");
            sum += balance;
        }
        assertEq(sum, SUPPLY, "tokens were created or destroyed");
    }

    /// @dev Every approval ever recorded reads back as the model says, including the unlimited
    ///      sentinel surviving spends, and no pair that was never approved has an allowance.
    function invariant_AllowancesMatchGhost() public view {
        uint256 pairs = handler.approvedPairCount();
        for (uint256 i; i < pairs; ++i) {
            (address owner, address spender) = handler.approvedPairs(i);
            assertEq(token.allowance(owner, spender), handler.ghostAllowance(owner, spender), "allowance diverged");
        }
        uint256 count = handler.actorCount();
        for (uint256 i; i < count && i < 6; ++i) {
            address owner = handler.actors(i);
            for (uint256 j; j < count && j < 6; ++j) {
                address spender = handler.actors(j);
                if (handler.pairRecorded(owner, spender)) continue;
                assertEq(token.allowance(owner, spender), 0, "an allowance appeared without an approval");
            }
        }
    }

    /// @dev Nothing but tokens ever moves: the contract holds no ETH and its code never changes.
    function invariant_ContractHoldsNoEtherAndCodeIsImmutable() public view {
        assertEq(address(token).balance, 0);
        assertEq(address(token).codehash, codeHashAtDeployment);
    }

    /// @dev Whatever reached the token contract itself is stranded: it never leaves.
    function invariant_TokensAtTheContractOnlyAccumulate() public view {
        assertEq(handler.ghostOut(address(token)), 0);
        assertEq(token.balanceOf(address(token)), handler.ghostIn(address(token)));
    }
}
