// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Slimez} from "../src/Slimez.sol";

/// @dev Local fixture for factory deployment and exact token movements only.
///      It does not implement a live pool, pricing, swaps, or distribution proofs.
contract SlimezFactoryFixture {
    address private immutable controller = msg.sender;

    modifier onlyController() {
        require(msg.sender == controller, "fixture controller only");
        _;
    }

    function deploy(bytes32 salt) external onlyController returns (Slimez) {
        return new Slimez{salt: salt}();
    }

    function move(Slimez token, address to, uint256 amount) external onlyController returns (bool) {
        return token.transfer(to, amount);
    }
}

/// @dev Has no token receiver hook. Standard ERC-20 transfers must still work.
contract SlimezRecipientFixture {
    address private immutable controller = msg.sender;

    function move(Slimez token, address to, uint256 amount) external returns (bool) {
        require(msg.sender == controller, "fixture controller only");
        return token.transfer(to, amount);
    }
}

contract SlimezLaunchTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000 * 10 ** 18;
    SlimezFactoryFixture internal factory;
    Slimez internal token;

    function setUp() public {
        factory = new SlimezFactoryFixture();
        token = factory.deploy(keccak256("Slimez fixture salt"));
    }

    function test_Create2MintsToFactoryAndUsesOnlyCreationCode() public view {
        bytes32 predicted = keccak256(
            abi.encodePacked(
                bytes1(0xff), address(factory), keccak256("Slimez fixture salt"), keccak256(type(Slimez).creationCode)
            )
        );
        assertEq(address(token), address(uint160(uint256(predicted))));
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(address(factory)), SUPPLY);
        assertEq(token.balanceOf(address(this)), 0);
        assertEq(token.balanceOf(address(token)), 0);
    }

    function test_DistributionClaimsAndPoolCustodyMoveExactAmounts() public {
        SlimezRecipientFixture distributor = new SlimezRecipientFixture();
        SlimezRecipientFixture poolCustodian = new SlimezRecipientFixture();
        address remainderRecipient = makeAddr("remainder recipient");
        address claimant = makeAddr("claimant");
        address trader = makeAddr("trader");
        uint256 swarmShare = SUPPLY / 10;
        uint256 poolShare = SUPPLY * 8 / 10;
        uint256 remainder = SUPPLY - swarmShare - poolShare;

        assertTrue(factory.move(token, address(distributor), swarmShare));
        assertTrue(factory.move(token, address(poolCustodian), poolShare));
        assertTrue(factory.move(token, remainderRecipient, remainder));
        assertEq(token.balanceOf(address(factory)), 0);
        assertEq(token.balanceOf(address(distributor)), swarmShare);
        assertEq(token.balanceOf(address(poolCustodian)), poolShare);
        assertEq(token.balanceOf(remainderRecipient), remainder);

        assertTrue(distributor.move(token, claimant, swarmShare));
        assertEq(token.balanceOf(address(distributor)), 0);
        assertEq(token.balanceOf(claimant), swarmShare);

        uint256 traded = 100 ether;
        assertTrue(poolCustodian.move(token, trader, traded));
        assertEq(token.balanceOf(address(poolCustodian)), poolShare - traded);
        assertEq(token.balanceOf(trader), traded);
        vm.prank(trader);
        assertTrue(token.transfer(address(poolCustodian), traded));
        assertEq(token.balanceOf(trader), 0);
        assertEq(token.balanceOf(address(poolCustodian)), poolShare);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(
            token.balanceOf(claimant) + token.balanceOf(address(poolCustodian)) + token.balanceOf(remainderRecipient),
            SUPPLY
        );
    }

    function test_RuntimeFitsDeploymentLimitAndHasNoForbiddenOpcodes() public view {
        bytes memory runtime = address(token).code;
        assertGt(runtime.length, 0);
        assertLe(runtime.length, 24_576);
        assertLe(type(Slimez).creationCode.length, 49_152);
        for (uint256 i; i < runtime.length; ++i) {
            uint8 opcode = uint8(runtime[i]);
            if (opcode >= 0x60 && opcode <= 0x7f) {
                i += opcode - 0x5f;
                continue;
            }
            assertTrue(opcode != 0xf4, "DELEGATECALL");
            assertTrue(opcode != 0xf2, "CALLCODE");
            assertTrue(opcode != 0xff, "SELFDESTRUCT");
        }
    }
}
