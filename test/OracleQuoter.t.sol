// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import {LibClone} from "solady/utils/LibClone.sol";
import "../src/OracleQuoter.sol";
import "../src/interfaces/IChainlinkAggregator.sol";
import "./mocks/MockChainlinkAggregator.sol";

contract OracleQuoterTest is Test {
    using LibClone for address;

    error InvalidInitialization();
    error TokenCallFailed();
    error OracleNotSet(address token);
    error OracleCallFailed(address oracle, string reason);
    error InvalidOraclePrice(address oracle);
    error InvalidBaseCurrency();
    error InvalidDecimals(uint8 decimals);

    OracleQuoter public quoter;
    OracleQuoter public implementation;

    MockToken public tokenSRF;
    MockToken public tokenMBAO;
    MockToken public tokenUSD;
    MockToken public tokenUSDC;
    MockToken public tokenKES;
    MockToken public tokenZAR;
    MockToken public tokenUnknown;

    MockChainlinkAggregator public oracleSRF;
    MockChainlinkAggregator public oracleMBAO;
    MockChainlinkAggregator public oracleUSD;
    MockChainlinkAggregator public oracleUSDC;
    MockChainlinkAggregator public oracleKES;
    MockChainlinkAggregator public oracleZAR;

    address owner = makeAddr("owner");

    event Initialized(address indexed owner, address indexed baseCurrency);
    event OracleUpdated(address indexed token, address indexed oracle);
    event OracleRemoved(address indexed token);

    function setUp() public {
        implementation = new OracleQuoter();

        address quoterAddress = LibClone.clone(address(implementation));
        quoter = OracleQuoter(quoterAddress);

        tokenSRF = new MockToken("Sarafu", "SRF", 6);
        tokenMBAO = new MockToken("Mbao", "MBAO", 6);
        tokenUSD = new MockToken("USD", "USD", 6);
        tokenUSDC = new MockToken("USD Coin", "USDC", 18);
        tokenKES = new MockToken("Kenyan Shilling", "KES", 6);
        tokenZAR = new MockToken("South African Rand", "ZAR", 6);
        tokenUnknown = new MockToken("Unknown Token", "UNK", 6);

        oracleSRF = new MockChainlinkAggregator(8, "SRF/USDC", 100000000);
        oracleMBAO = new MockChainlinkAggregator(8, "MBAO/USDC", 50000000);
        oracleUSD = new MockChainlinkAggregator(8, "USD/USDC", 100000000);
        oracleUSDC = new MockChainlinkAggregator(8, "USDC/USDC", 100000000);
        oracleKES = new MockChainlinkAggregator(18, "KES/USDC", 7_812_500_000_000_000);
        oracleZAR = new MockChainlinkAggregator(8, "ZAR/USDC", 5200000);

        quoter.initialize(owner, address(tokenUSDC));

        vm.startPrank(owner);
        quoter.setOracle(address(tokenSRF), address(oracleSRF));
        quoter.setOracle(address(tokenMBAO), address(oracleMBAO));
        quoter.setOracle(address(tokenUSD), address(oracleUSD));
        quoter.setOracle(address(tokenUSDC), address(oracleUSDC));
        quoter.setOracle(address(tokenKES), address(oracleKES));
        quoter.setOracle(address(tokenZAR), address(oracleZAR));
        vm.stopPrank();
    }

    function test_initialize() public view {
        assertEq(quoter.owner(), owner);
        assertEq(quoter.baseCurrency(), address(tokenUSDC));
    }

    function test_initialize_revertIf_already_initialized() public {
        vm.expectRevert(InvalidInitialization.selector);
        quoter.initialize(owner, address(tokenUSDC));
    }

    function test_initialize_revertIf_invalidBaseCurrency() public {
        address quoterAddress = LibClone.clone(address(implementation));
        OracleQuoter newQuoter = OracleQuoter(quoterAddress);
        vm.expectRevert(InvalidBaseCurrency.selector);
        newQuoter.initialize(owner, address(0));
    }

    function test_setOracle() public {
        address newToken = makeAddr("newToken");
        address newOracle = makeAddr("newOracle");

        vm.prank(owner);
        vm.expectEmit(true, true, false, true);
        emit OracleUpdated(newToken, newOracle);
        quoter.setOracle(newToken, newOracle);

        assertEq(quoter.oracles(newToken), newOracle);
    }

    function test_setOracle_updateExisting() public {
        address newOracle = makeAddr("newOracle");

        vm.prank(owner);
        quoter.setOracle(address(tokenSRF), newOracle);

        assertEq(quoter.oracles(address(tokenSRF)), newOracle);
    }

    function test_setOracle_revertIf_notOwner() public {
        vm.prank(makeAddr("notOwner"));
        vm.expectRevert(Ownable.Unauthorized.selector);
        quoter.setOracle(address(tokenSRF), makeAddr("newOracle"));
    }

    function test_setOracle_revertIf_zeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(InvalidBaseCurrency.selector);
        quoter.setOracle(address(0), makeAddr("newOracle"));
    }

    function test_removeOracle() public {
        vm.prank(owner);
        vm.expectEmit(true, false, false, true);
        emit OracleRemoved(address(tokenSRF));
        quoter.removeOracle(address(tokenSRF));

        assertEq(quoter.oracles(address(tokenSRF)), address(0));
    }

    function test_removeOracle_revertIf_notOwner() public {
        vm.prank(makeAddr("notOwner"));
        vm.expectRevert(Ownable.Unauthorized.selector);
        quoter.removeOracle(address(tokenSRF));
    }

    function test_valueFor_sameDecimals_SRF_to_MBAO() public {
        uint256 input = 1_000_000;
        uint256 expectedOut = 2_000_000;

        uint256 output = quoter.valueFor(address(tokenMBAO), address(tokenSRF), input);

        assertEq(output, expectedOut);
    }

    function test_valueFor_sameDecimals_MBAO_to_SRF() public {
        uint256 input = 1_000_000;
        uint256 expectedOut = 500_000;

        uint256 output = quoter.valueFor(address(tokenSRF), address(tokenMBAO), input);

        assertEq(output, expectedOut);
    }

    function test_valueFor_sameDecimals_USD_to_ZAR() public {
        uint256 input = 1_000_000;

        uint256 output = quoter.valueFor(address(tokenZAR), address(tokenUSD), input);

        assertApproxEqRel(output, 19_230_769, 100);
    }

    function test_valueFor_sameDecimals_KES_to_USD_mixedOracleDecimals() public {
        uint256 input = 128 * 10 ** 6;
        uint256 expectedOut = 1 * 10 ** 6;

        uint256 output = quoter.valueFor(address(tokenUSD), address(tokenKES), input);

        assertEq(output, expectedOut);
    }

    function test_valueFor_differentDecimals_KES_to_USDC_mixedOracleDecimals() public {
        uint256 input = 128 * 10 ** 6;
        uint256 expectedOut = 1 * 10 ** 18;

        uint256 output = quoter.valueFor(address(tokenUSDC), address(tokenKES), input);

        assertEq(output, expectedOut);
    }

    function test_valueFor_sameDecimals_BRL_to_KES_mixedOracleDecimals() public {
        oracleZAR.setAnswer(20_000_000); // 0.2 USD per BRL

        uint256 input = 1 * 10 ** 6;
        uint256 expectedOut = 25_600_000;

        uint256 output = quoter.valueFor(address(tokenKES), address(tokenZAR), input);

        assertEq(output, expectedOut);
    }

    function test_valueFor_USDC_to_SRF() public {
        uint256 input = 100 * 10 ** 18;
        uint256 expectedOut = 100 * 10 ** 6;

        uint256 output = quoter.valueFor(address(tokenSRF), address(tokenUSDC), input);

        assertEq(output, expectedOut);
    }

    function test_valueFor_SRF_to_USDC() public {
        uint256 input = 100 * 10 ** 6;
        uint256 expectedOut = 100 * 10 ** 18;

        uint256 output = quoter.valueFor(address(tokenUSDC), address(tokenSRF), input);

        assertEq(output, expectedOut);
    }

    function test_valueFor_USDC_to_MBAO() public {
        uint256 input = 100 * 10 ** 18;
        uint256 expectedOut = 200 * 10 ** 6;

        uint256 output = quoter.valueFor(address(tokenMBAO), address(tokenUSDC), input);

        assertEq(output, expectedOut);
    }

    function test_valueFor_revertIf_inOracleNotSet() public {
        uint256 input = 1_000_000;

        vm.expectRevert(abi.encodeWithSelector(OracleNotSet.selector, address(tokenUnknown)));
        quoter.valueFor(address(tokenSRF), address(tokenUnknown), input);
    }

    function test_valueFor_revertIf_outOracleNotSet() public {
        uint256 input = 1_000_000;

        vm.expectRevert(abi.encodeWithSelector(OracleNotSet.selector, address(tokenUnknown)));
        quoter.valueFor(address(tokenUnknown), address(tokenSRF), input);
    }

    function test_valueFor_revertIf_oracleReturnsZero() public {
        oracleSRF.setAnswer(0);
        uint256 input = 1_000_000;

        vm.expectRevert(abi.encodeWithSelector(InvalidOraclePrice.selector, address(oracleSRF)));
        quoter.valueFor(address(tokenMBAO), address(tokenSRF), input);
    }

    function test_valueFor_largeAmounts() public {
        uint256 input = 1_000_000 * 10 ** 18;
        uint256 expectedOut = 1_000_000 * 10 ** 6;

        uint256 output = quoter.valueFor(address(tokenSRF), address(tokenUSDC), input);

        assertEq(output, expectedOut);
    }

    function test_valueFor_smallAmounts() public {
        uint256 input = 1 * 10 ** 12;
        uint256 expectedOut = 1;

        uint256 output = quoter.valueFor(address(tokenSRF), address(tokenUSDC), input);

        assertEq(output, expectedOut);
    }

    function test_valueFor_differentDecimals_eightToEight() public {
        MockToken token8decimals1 = new MockToken("Token 8A", "T8A", 8);
        MockToken token8decimals2 = new MockToken("Token 8B", "T8B", 8);
        MockChainlinkAggregator oracle8a = new MockChainlinkAggregator(8, "T8A/USDC", 50000000);
        MockChainlinkAggregator oracle8b = new MockChainlinkAggregator(8, "T8B/USDC", 100000000);

        vm.startPrank(owner);
        quoter.setOracle(address(token8decimals1), address(oracle8a));
        quoter.setOracle(address(token8decimals2), address(oracle8b));
        vm.stopPrank();

        uint256 input = 100 * 10 ** 8;
        uint256 expectedOut = 50 * 10 ** 8;

        uint256 output = quoter.valueFor(address(token8decimals2), address(token8decimals1), input);

        assertEq(output, expectedOut);
    }

    function test_valueFor_differentDecimals_twelveToSix() public {
        MockToken token12decimals = new MockToken("Token 12", "T12", 12);
        MockChainlinkAggregator oracle12 = new MockChainlinkAggregator(8, "T12/USDC", 100000000);

        vm.prank(owner);
        quoter.setOracle(address(token12decimals), address(oracle12));

        uint256 input = 100 * 10 ** 12;
        uint256 expectedOut = 100 * 10 ** 6;

        uint256 output = quoter.valueFor(address(tokenSRF), address(token12decimals), input);

        assertEq(output, expectedOut);
    }

    function test_supportsInterface() public view {
        assertTrue(quoter.supportsInterface(0x01ffc9a7));
        assertTrue(quoter.supportsInterface(0x9493f8b2));
        assertTrue(quoter.supportsInterface(0xdbb21d40));
        assertFalse(quoter.supportsInterface(0x12345678));
    }
}

contract MockToken {
    string private _name;
    string private _symbol;
    uint8 private _decimals;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) {
        _name = name_;
        _symbol = symbol_;
        _decimals = decimals_;
    }

    function name() external view returns (string memory) {
        return _name;
    }

    function symbol() external view returns (string memory) {
        return _symbol;
    }

    function decimals() external view returns (uint8) {
        return _decimals;
    }
}
