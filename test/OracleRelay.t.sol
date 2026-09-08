// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import {LibClone} from "solady/utils/LibClone.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {OracleRelay} from "../src/OracleRelay.sol";
import {OracleQuoter} from "../src/OracleQuoter.sol";
import {IChainlinkAggregatorV3} from "../src/interfaces/IChainlinkAggregator.sol";
import {MockChainlinkAggregator} from "./mocks/MockChainlinkAggregator.sol";

contract OracleRelayTest is Test {
    error InvalidInitialization();

    OracleRelay public implementation;
    OracleRelay public relay;

    address owner = makeAddr("owner");
    address writer = makeAddr("writer");
    address stranger = makeAddr("stranger");
    address replacement = makeAddr("replacement");

    event Initialized(address indexed owner, address indexed writer, uint8 decimals, string description);
    event WriterUpdated(address indexed oldWriter, address indexed newWriter);
    event RoundDataUpdated(
        uint80 indexed roundId,
        int256 answer,
        uint256 startedAt,
        uint256 updatedAt,
        uint80 answeredInRound,
        uint64 relayedAt
    );
    event RoundDataInvalidated(uint80 indexed roundId, uint64 relayedAt);

    function setUp() public {
        vm.warp(1_700_000_000);
        implementation = new OracleRelay();
        relay = OracleRelay(LibClone.clone(address(implementation)));
        relay.initialize(owner, writer, 8, "KES / USD");
    }

    function _publish(uint80 roundId, int256 answer) internal {
        vm.prank(writer);
        relay.updateRoundData(roundId, answer, block.timestamp - 10, block.timestamp - 5, roundId);
    }

    function test_initialize_setsMetadataAndRoles() public view {
        assertEq(relay.owner(), owner);
        assertEq(relay.writer(), writer);
        assertEq(relay.decimals(), 8);
        assertEq(relay.description(), "KES / USD");
        assertEq(relay.version(), 1);
        assertEq(relay.relayedAt(), 0);
        assertFalse(relay.hasRoundData());
    }

    function test_initialize_emitsInitialized() public {
        OracleRelay instance = OracleRelay(LibClone.clone(address(implementation)));
        vm.expectEmit(true, true, false, true);
        emit Initialized(owner, writer, 6, "ZAR / USD");
        instance.initialize(owner, writer, 6, "ZAR / USD");
    }

    function test_initialize_allowsZeroDecimalsAndEmptyDescription() public {
        OracleRelay instance = OracleRelay(LibClone.clone(address(implementation)));
        instance.initialize(owner, writer, 0, "");
        assertEq(instance.decimals(), 0);
        assertEq(instance.description(), "");
    }

    function test_initialize_rejectsZeroOwner() public {
        OracleRelay instance = OracleRelay(LibClone.clone(address(implementation)));
        vm.expectRevert(Ownable.NewOwnerIsZeroAddress.selector);
        instance.initialize(address(0), writer, 8, "KES / USD");
    }

    function test_initialize_rejectsZeroWriter() public {
        OracleRelay instance = OracleRelay(LibClone.clone(address(implementation)));
        vm.expectRevert(OracleRelay.InvalidWriter.selector);
        instance.initialize(owner, address(0), 8, "KES / USD");
    }

    function test_initialize_rejectsSecondCall() public {
        vm.expectRevert(InvalidInitialization.selector);
        relay.initialize(owner, writer, 8, "KES / USD");
    }

    function test_implementation_initializerIsDisabled() public {
        vm.expectRevert(InvalidInitialization.selector);
        implementation.initialize(owner, writer, 8, "KES / USD");
    }

    function test_supportsInterface() public view {
        assertTrue(relay.supportsInterface(0x01ffc9a7));
        assertTrue(relay.supportsInterface(0x7f5828d0));
        assertTrue(relay.supportsInterface(0x73851258));
        assertFalse(relay.supportsInterface(0x9493f8b2));
        assertFalse(relay.supportsInterface(0xffffffff));
    }

    function test_aggregatorInterfaceId_matchesXorOfSelectors() public pure {
        bytes4 expected = IChainlinkAggregatorV3.decimals.selector ^ IChainlinkAggregatorV3.description.selector
            ^ IChainlinkAggregatorV3.version.selector ^ IChainlinkAggregatorV3.getRoundData.selector
            ^ IChainlinkAggregatorV3.latestRoundData.selector;
        assertEq(expected, bytes4(0x73851258));
    }

    function test_reads_revertBeforeFirstPublish() public {
        vm.expectRevert(OracleRelay.NoRoundData.selector);
        relay.latestRoundData();
        vm.expectRevert(OracleRelay.NoRoundData.selector);
        relay.getRoundData(0);
    }

    function test_updateRoundData_storesTupleVerbatim() public {
        uint256 startedAt = block.timestamp - 60;
        uint256 updatedAt = block.timestamp - 30;

        vm.expectEmit(true, false, false, true);
        emit RoundDataUpdated(42, 775_000, startedAt, updatedAt, 41, uint64(block.timestamp));
        vm.prank(writer);
        relay.updateRoundData(42, 775_000, startedAt, updatedAt, 41);

        (uint80 roundId, int256 answer, uint256 s, uint256 u, uint80 answeredInRound) = relay.latestRoundData();
        assertEq(roundId, 42);
        assertEq(answer, 775_000);
        assertEq(s, startedAt);
        assertEq(u, updatedAt);
        assertEq(answeredInRound, 41);
        assertTrue(relay.hasRoundData());
    }

    function test_updateRoundData_separatesUpdatedAtFromRelayedAt() public {
        uint256 sourceUpdatedAt = block.timestamp - 900;
        vm.prank(writer);
        relay.updateRoundData(1, 1e8, sourceUpdatedAt, sourceUpdatedAt, 1);

        (,,, uint256 updatedAt,) = relay.latestRoundData();
        assertEq(updatedAt, sourceUpdatedAt);
        assertEq(relay.relayedAt(), uint64(block.timestamp));
        assertTrue(relay.relayedAt() > updatedAt);
    }

    function test_updateRoundData_acceptsNegativeAndZeroAnswers() public {
        _publish(1, 0);
        (, int256 zero,,,) = relay.latestRoundData();
        assertEq(zero, 0);

        _publish(2, -5);
        (, int256 negative,,,) = relay.latestRoundData();
        assertEq(negative, -5);
    }

    function test_updateRoundData_acceptsCurrentTimestamp() public {
        vm.prank(writer);
        relay.updateRoundData(1, 1e8, block.timestamp, block.timestamp, 1);
        (,,, uint256 updatedAt,) = relay.latestRoundData();
        assertEq(updatedAt, block.timestamp);
    }

    function test_updateRoundData_rejectsFutureTimestamp() public {
        vm.expectRevert(OracleRelay.FutureTimestamp.selector);
        vm.prank(writer);
        relay.updateRoundData(1, 1e8, block.timestamp, block.timestamp + 1, 1);
    }

    function test_updateRoundData_rejectsNonWriter() public {
        vm.expectRevert(OracleRelay.Access.selector);
        vm.prank(stranger);
        relay.updateRoundData(1, 1e8, block.timestamp, block.timestamp, 1);
    }

    function test_updateRoundData_rejectsOwner() public {
        vm.expectRevert(OracleRelay.Access.selector);
        vm.prank(owner);
        relay.updateRoundData(1, 1e8, block.timestamp, block.timestamp, 1);
    }

    function test_updateRoundData_replacesPreviousRound() public {
        _publish(1, 100);
        uint64 firstRelayedAt = relay.relayedAt();

        vm.warp(block.timestamp + 1);
        _publish(2, 200);

        (uint80 roundId, int256 answer,,,) = relay.latestRoundData();
        assertEq(roundId, 2);
        assertEq(answer, 200);
        assertTrue(relay.relayedAt() > firstRelayedAt);

        vm.expectRevert(OracleRelay.NoRoundData.selector);
        relay.getRoundData(1);
    }

    function test_getRoundData_matchesCurrentRoundOnly() public {
        _publish(7, 123);

        (uint80 roundId, int256 answer,,,) = relay.getRoundData(7);
        assertEq(roundId, 7);
        assertEq(answer, 123);

        vm.expectRevert(OracleRelay.NoRoundData.selector);
        relay.getRoundData(6);
        vm.expectRevert(OracleRelay.NoRoundData.selector);
        relay.getRoundData(8);
    }

    function test_setWriter_rotatesAndEmits() public {
        vm.expectEmit(true, true, false, false);
        emit WriterUpdated(writer, replacement);
        vm.prank(owner);
        relay.setWriter(replacement);

        assertEq(relay.writer(), replacement);

        vm.expectRevert(OracleRelay.Access.selector);
        vm.prank(writer);
        relay.updateRoundData(1, 1e8, block.timestamp, block.timestamp, 1);
    }

    function test_setWriter_retainsLastRound() public {
        _publish(3, 300);
        vm.prank(owner);
        relay.setWriter(replacement);

        (uint80 roundId,,,,) = relay.latestRoundData();
        assertEq(roundId, 3);
        assertTrue(relay.hasRoundData());
    }

    function test_setWriter_rejectsZeroAddress() public {
        vm.expectRevert(OracleRelay.InvalidWriter.selector);
        vm.prank(owner);
        relay.setWriter(address(0));
    }

    function test_setWriter_rejectsNonOwner() public {
        vm.expectRevert(Ownable.Unauthorized.selector);
        vm.prank(writer);
        relay.setWriter(replacement);
    }

    function test_invalidate_failsClosedAndRotatesWriter() public {
        _publish(9, 900);
        uint64 lastRelayedAt = relay.relayedAt();

        vm.expectEmit(true, true, false, false);
        emit WriterUpdated(writer, replacement);
        vm.expectEmit(true, false, false, true);
        emit RoundDataInvalidated(9, lastRelayedAt);
        vm.prank(owner);
        relay.invalidate(replacement);

        assertEq(relay.writer(), replacement);
        assertFalse(relay.hasRoundData());

        vm.expectRevert(OracleRelay.NoRoundData.selector);
        relay.latestRoundData();
        vm.expectRevert(OracleRelay.NoRoundData.selector);
        relay.getRoundData(9);
    }

    function test_invalidate_allowsRepublishingTheSameTuple() public {
        uint256 startedAt = block.timestamp - 60;
        uint256 updatedAt = block.timestamp - 30;
        vm.prank(writer);
        relay.updateRoundData(9, 900, startedAt, updatedAt, 9);

        vm.prank(owner);
        relay.invalidate(replacement);

        vm.expectRevert(OracleRelay.Access.selector);
        vm.prank(writer);
        relay.updateRoundData(9, 900, startedAt, updatedAt, 9);

        vm.prank(replacement);
        relay.updateRoundData(9, 900, startedAt, updatedAt, 9);

        (uint80 roundId, int256 answer, uint256 s, uint256 u, uint80 answeredInRound) = relay.latestRoundData();
        assertEq(roundId, 9);
        assertEq(answer, 900);
        assertEq(s, startedAt);
        assertEq(u, updatedAt);
        assertEq(answeredInRound, 9);
        assertTrue(relay.hasRoundData());
    }

    function test_invalidate_rejectsZeroAddress() public {
        vm.expectRevert(OracleRelay.InvalidWriter.selector);
        vm.prank(owner);
        relay.invalidate(address(0));
    }

    function test_invalidate_rejectsNonOwner() public {
        vm.expectRevert(Ownable.Unauthorized.selector);
        vm.prank(writer);
        relay.invalidate(replacement);
    }

    function testFuzz_updateRoundData_storesTupleVerbatim(
        uint80 roundId,
        int256 answer,
        uint256 startedAt,
        uint256 updatedAt,
        uint80 answeredInRound
    ) public {
        updatedAt = bound(updatedAt, 0, block.timestamp);

        vm.prank(writer);
        relay.updateRoundData(roundId, answer, startedAt, updatedAt, answeredInRound);

        (uint80 r, int256 a, uint256 s, uint256 u, uint80 air) = relay.latestRoundData();
        assertEq(r, roundId);
        assertEq(a, answer);
        assertEq(s, startedAt);
        assertEq(u, updatedAt);
        assertEq(air, answeredInRound);
        assertEq(relay.relayedAt(), uint64(block.timestamp));
    }

    function testFuzz_updateRoundData_rejectsFutureTimestamp(uint256 skew) public {
        skew = bound(skew, 1, type(uint256).max - block.timestamp);
        vm.expectRevert(OracleRelay.FutureTimestamp.selector);
        vm.prank(writer);
        relay.updateRoundData(1, 1e8, 0, block.timestamp + skew, 1);
    }
}

contract OracleRelayQuoterCompatibilityTest is Test {
    OracleRelay public relay;
    OracleQuoter public quoter;
    MockChainlinkAggregator public usdFeed;
    RelayMockToken public tokenKES;
    RelayMockToken public tokenUSD;

    address owner = makeAddr("owner");
    address writer = makeAddr("writer");

    function setUp() public {
        vm.warp(1_700_000_000);

        relay = OracleRelay(LibClone.clone(address(new OracleRelay())));
        relay.initialize(owner, writer, 8, "KES / USD");

        // 0.00775 USD per KES at 8 decimals.
        vm.prank(writer);
        relay.updateRoundData(1, 775_000, block.timestamp - 60, block.timestamp - 30, 1);

        usdFeed = new MockChainlinkAggregator(8, "USD / USD", 100_000_000);

        tokenKES = new RelayMockToken(6);
        tokenUSD = new RelayMockToken(6);

        quoter = OracleQuoter(LibClone.clone(address(new OracleQuoter())));
        quoter.initialize(owner, address(tokenUSD));

        vm.startPrank(owner);
        quoter.setOracle(address(tokenKES), address(relay));
        quoter.setOracle(address(tokenUSD), address(usdFeed));
        vm.stopPrank();
    }

    function test_quoterConsumesRelayedFeed() public view {
        // 1000 KES at 0.00775 USD per KES is 7.75 USD.
        assertEq(quoter.valueFor(address(tokenUSD), address(tokenKES), 1000e6), 7_750_000);
    }

    function test_quoterReverseQuoteRoundTrips() public view {
        uint256 required = quoter.reverseValueFor(address(tokenUSD), address(tokenKES), 7_750_000);
        assertGe(quoter.valueFor(address(tokenUSD), address(tokenKES), required), 7_750_000);
    }

    function test_quoterRejectsRelayAfterInvalidation() public {
        vm.prank(owner);
        relay.invalidate(makeAddr("replacement"));

        vm.expectRevert(
            abi.encodeWithSelector(
                OracleQuoter.OracleCallFailed.selector, address(relay), "latestRoundData call failed"
            )
        );
        quoter.valueFor(address(tokenUSD), address(tokenKES), 1000e6);
    }

    function test_quoterRejectsStaleRelayedRound() public {
        vm.warp(block.timestamp + 2 days);
        vm.expectRevert(abi.encodeWithSelector(OracleQuoter.StaleOraclePrice.selector, address(relay)));
        quoter.valueFor(address(tokenUSD), address(tokenKES), 1000e6);
    }
}

contract RelayMockToken {
    uint8 private _decimals;

    constructor(uint8 decimals_) {
        _decimals = decimals_;
    }

    function decimals() external view returns (uint8) {
        return _decimals;
    }
}
