// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/BeanstalkGovernanceMockV4.sol";
import "../src/BeanstalkTrapV4.sol";
import "../src/BeanstalkTypesV4.sol";
import "../src/BeanstalkVaultV4.sol";

contract TrapHarnessV4 is BeanstalkTrapV4 {
    address private immutable configuredTarget;

    constructor(address targetAddress) {
        configuredTarget = targetAddress;
    }

    function _target() internal view override returns (address) {
        return configuredTarget;
    }
}

contract BeanstalkMitigationV4Test is Test {
    BeanstalkGovernanceMockV4 internal protocol;
    TrapHarnessV4 internal trap;
    BeanstalkVaultV4 internal vault;

    address internal voterA = address(0xA11CE);
    address internal voterB = address(0xB0B);

    function setUp() public {
        protocol = new BeanstalkGovernanceMockV4();
        trap = new TrapHarnessV4(address(protocol));
        vault = new BeanstalkVaultV4(address(protocol), address(this), 33);
        protocol.setPauseGuardian(address(vault));
        protocol.createEmergencyProposal(1000);
    }

    function _vote(address who, uint256 amount) internal {
        vm.prank(who);
        protocol.supportProposal(amount);
    }

    function test_withoutResponse_DelayedExploitDrains() public {
        _vote(voterA, 400);
        _vote(voterB, 700);

        protocol.queueProposal();
        vm.roll(block.number + 1);
        protocol.executeProposal();

        assertEq(protocol.treasury(), 0);
    }

    function test_withResponse_DelayedExploitBlocked() public {
        _vote(voterA, 400);
        bytes memory prev = trap.collect();

        vm.roll(block.number + 1);
        _vote(voterB, 700);
        protocol.queueProposal();

        bytes memory curr = trap.collect();

        bytes[] memory window = new bytes[](2);
        window[0] = curr;
        window[1] = prev;

        (bool trigger, bytes memory response) = trap.shouldRespond(window);
        assertTrue(
            trigger,
            "V4 trap should fire on proposal threshold cross in timelock"
        );

        vault.executeResponse(response);
        assertTrue(protocol.paused(), "Protocol should be paused by response");

        vm.roll(block.number + 1);
        vm.expectRevert(bytes("BeanstalkGovernanceMockV4: protocol is paused"));
        protocol.executeProposal();

        assertEq(protocol.treasury(), protocol.INITIAL_TREASURY());
    }

    function test_reason_CoordinatedAttack_WhenMultipleSupporters() public {
        _vote(voterA, 400);
        bytes memory prev = trap.collect();

        vm.roll(block.number + 1);
        _vote(voterB, 700);
        protocol.queueProposal();
        bytes memory curr = trap.collect();

        bytes[] memory window = new bytes[](2);
        window[0] = curr;
        window[1] = prev;

        (bool trigger, bytes memory response) = trap.shouldRespond(window);
        assertTrue(trigger);

        BeanstalkTypesV4.Incident memory incident = abi.decode(
            response,
            (BeanstalkTypesV4.Incident)
        );

        assertEq(
            incident.reason,
            BeanstalkTypesV4.REASON_COORDINATED_MULTI_SUPPORTER
        );
    }

    function test_reason_SingleWhale_WhenTopSupporterCrossesThreshold() public {
        _vote(voterA, 200);
        bytes memory prev = trap.collect();

        vm.roll(block.number + 1);
        _vote(voterA, 900);
        protocol.queueProposal();
        bytes memory curr = trap.collect();

        bytes[] memory window = new bytes[](2);
        window[0] = curr;
        window[1] = prev;

        (bool trigger, bytes memory response) = trap.shouldRespond(window);
        assertTrue(trigger);

        BeanstalkTypesV4.Incident memory incident = abi.decode(
            response,
            (BeanstalkTypesV4.Incident)
        );

        assertEq(incident.reason, BeanstalkTypesV4.REASON_SINGLE_WHALE_SUPPORT);
    }

    function test_noTrigger_WhenAlreadyExecuted() public {
        _vote(voterA, 1000);
        protocol.queueProposal();
        vm.roll(block.number + 1);
        protocol.executeProposal();

        bytes memory prev = trap.collect();
        vm.roll(block.number + 1);
        bytes memory curr = trap.collect();

        bytes[] memory window = new bytes[](2);
        window[0] = curr;
        window[1] = prev;

        (bool trigger, ) = trap.shouldRespond(window);
        assertFalse(trigger);
    }

    function test_noTrigger_WhenCanceled() public {
        _vote(voterA, 400);
        bytes memory prev = trap.collect();

        vm.roll(block.number + 1);
        _vote(voterB, 700);
        protocol.queueProposal();
        protocol.cancelProposal();
        bytes memory curr = trap.collect();

        bytes[] memory window = new bytes[](2);
        window[0] = curr;
        window[1] = prev;

        (bool trigger, ) = trap.shouldRespond(window);
        assertFalse(trigger);
    }
}
