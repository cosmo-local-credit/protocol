// Author: Mohamed Sohail <sohail@grassecon.org> 43CA77F641ADA031C12665CB47461C31B006BC0E
// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import {LibClone} from "solady/utils/LibClone.sol";
import "../src/RelativeQuoter.sol";

/*
Everything is relative to 10 KES.
Therefore:

1 SRF = 1
1 MBAO = 2 (1 MBAO = 20 KES)
1 USD = 14.5 (1 USD = 145 KES)
1 MUU = 1
1 TZS = 0.005 (1 KES = 20 TZS)
1 ZAR = 0.755 (1 ZAR = 7.55 KES)
1 USDC = 14.66 (1 USDC = 146.6 KES) (18 decimals)

These relative prices need to be represented in fixed point numbers.
We use PPM (1,000,000) as the base, so we multiply each by 1,000,000:

1 SRF = 1_000_000
1 MBAO = 2_000_000
1 USD = 14_500_000
1 MUU = 1_000_000
1 TZS = 5_000
1 ZAR = 755_000
1 USDC = 14_660_000

N.B:

* The default rate is always 1_000_000 (PPM) because we assume it is a standard token.
* Unless otherwise stated, all tokens above have a decimal precision of 6

*/
contract RelativeQuoterTest is Test {
    using LibClone for address;

    error InvalidInitialization();
    error TokenCallFailed();

    RelativeQuoter public quoter;
    RelativeQuoter public implementation;

    // Mock tokens
    MockToken public tokenSRF;
    MockToken public tokenMBAO;
    MockToken public tokenUSD;
    MockToken public tokenMUU;
    MockToken public tokenTZS;
    MockToken public tokenZAR;
    MockToken public tokenUSDC;
    MockToken public tokenABC;
    MockToken public tokenXYZ;

    address owner = makeAddr("owner");

    // Default values (PPM = 1,000,000)
    uint256 constant PPM = 1_000_000;
    uint256 defaultInExchangeRate = PPM;
    uint256 defaultOutExchangeRate = PPM;

    // Rates set (scaled to PPM)
    uint256 SRFRate = 1_000_000;
    uint256 MBAORate = 2_000_000;
    uint256 USDRate = 14_500_000;
    uint256 MUURate = 1_000_000;
    uint256 TZSRate = 5_000;
    uint256 ZARRate = 755_000;
    uint256 USDCRate = 14_660_000;

    event PriceIndexUpdated(address indexed tokenAddress, uint256 exchangeRate);

    function setUp() public {
        // Deploy implementation
        implementation = new RelativeQuoter();

        // Clone and initialize
        address quoterAddress = LibClone.clone(address(implementation));
        quoter = RelativeQuoter(quoterAddress);
        quoter.initialize(owner);

        // Deploy mock tokens
        tokenSRF = new MockToken("Sarafu", "SRF", 6);
        tokenMBAO = new MockToken("Mbao", "MBAO", 6);
        tokenUSD = new MockToken("USD", "USD", 6);
        tokenMUU = new MockToken("Muu", "MUU", 6);
        tokenTZS = new MockToken("Tanzanian Shilling", "TZS", 6);
        tokenZAR = new MockToken("South African Rand", "ZAR", 6);
        tokenUSDC = new MockToken("USD Coin", "USDC", 18);
        tokenABC = new MockToken("Token ABC", "ABC", 6);
        tokenXYZ = new MockToken("Token XYZ", "XYZ", 6);

        // Set rates
        vm.startPrank(owner);
        quoter.setPriceIndexValue(address(tokenSRF), SRFRate);
        quoter.setPriceIndexValue(address(tokenMBAO), MBAORate);
        quoter.setPriceIndexValue(address(tokenUSD), USDRate);
        quoter.setPriceIndexValue(address(tokenMUU), MUURate);
        quoter.setPriceIndexValue(address(tokenTZS), TZSRate);
        quoter.setPriceIndexValue(address(tokenZAR), ZARRate);
        quoter.setPriceIndexValue(address(tokenUSDC), USDCRate);
        vm.stopPrank();
    }

    function test_initialize() public view {
        assertEq(quoter.owner(), owner);
    }

    function test_initialize_revertIf_already_initialized() public {
        vm.expectRevert(InvalidInitialization.selector);
        quoter.initialize(owner);
    }

    function test_setPriceIndexValue() public {
        address newToken = makeAddr("newToken");
        uint256 rate = 5_000_000;

        vm.prank(owner);
        vm.expectEmit(true, false, false, true);
        emit PriceIndexUpdated(newToken, rate);

        uint256 returnedRate = quoter.setPriceIndexValue(newToken, rate);

        assertEq(returnedRate, rate);
        assertEq(quoter.priceIndex(newToken), rate);
    }

    function test_setPriceIndexValue_revertIf_not_owner() public {
        address newToken = makeAddr("newToken");

        vm.prank(makeAddr("notOwner"));
        vm.expectRevert(Ownable.Unauthorized.selector);
        quoter.setPriceIndexValue(newToken, 5_000_000);
    }

    function test_valueFor_similarDecimals_noRatesSet() public {
        /*      
        Rates not set  
        1 ABC in
        1 XYZ out
        */
        uint256 input = 1_000_000;
        uint256 expectedOut = 1_000_000;

        uint256 output = quoter.valueFor(
            address(tokenXYZ),
            address(tokenABC),
            input
        );

        assertEq(output, expectedOut);
    }

    function test_valueFor_similarDecimals_1() public {
        /*      
        1 MBAO in
        2 SRF out
        */
        uint256 input = 1_000_000;
        uint256 expectedOut = 2_000_000;

        uint256 output = quoter.valueFor(
            address(tokenSRF),
            address(tokenMBAO),
            input
        );

        assertEq(output, expectedOut);
    }

    function test_valueFor_similarDecimals_2() public {
        /*      
        1 SRF in
        0.5 MBAO out
        */
        uint256 input = 1_000_000;
        uint256 expectedOut = 500_000;

        uint256 output = quoter.valueFor(
            address(tokenMBAO),
            address(tokenSRF),
            input
        );

        assertEq(output, expectedOut);
    }

    function test_valueFor_similarDecimals_3() public {
        /*      
        1000 SRF in
        ~ 68.96 USD out
        */
        uint256 input = 1_000_000_000;
        uint256 expectedOut = 68_965_517;

        uint256 output = quoter.valueFor(
            address(tokenUSD),
            address(tokenSRF),
            input
        );

        assertEq(output, expectedOut);
    }

    function test_valueFor_similarDecimals_4() public {
        /*      
        1000 SRF in
        ~ 200,000 TZS out
        */
        uint256 input = 1_000_000_000;
        uint256 expectedOut = 200_000_000_000;

        uint256 output = quoter.valueFor(
            address(tokenTZS),
            address(tokenSRF),
            input
        );

        assertEq(output, expectedOut);
    }

    function test_valueFor_similarDecimals_5() public {
        /*      
        1000 ZAR in
        ~ 52.06 USD out
        */
        uint256 input = 1_000_000_000;
        uint256 expectedOut = 52_068_965;

        uint256 output = quoter.valueFor(
            address(tokenUSD),
            address(tokenZAR),
            input
        );

        assertEq(output, expectedOut);
    }

    function test_valueFor_similarDecimals_6() public {
        /*      
        100 TZS in
        ~ 0.034482 USD out
        */
        uint256 input = 100_000_000;
        uint256 expectedOut = 34_482;

        uint256 output = quoter.valueFor(
            address(tokenUSD),
            address(tokenTZS),
            input
        );

        assertEq(output, expectedOut);
    }

    function test_valueFor_USDCIn_SRFOut() public {
        /*      
        100 USDC in
        1466 SRF out
        */
        uint256 input = 100 * 10 ** 18;
        uint256 expectedOut = 1_466_000_000;

        uint256 output = quoter.valueFor(
            address(tokenSRF),
            address(tokenUSDC),
            input
        );

        assertEq(output, expectedOut);
    }

    function test_valueFor_SRFIn_USDCOut() public {
        /*      
        100 SRF in
        ~ 6.82 USDC out
        */
        uint256 input = 100_000_000;
        uint256 expectedOut = 6_821_282_401_091_405_184;

        uint256 output = quoter.valueFor(
            address(tokenUSDC),
            address(tokenSRF),
            input
        );

        assertEq(output, expectedOut);
    }

    function test_valueFor_differentDecimals_MBAOtoUSDC() public {
        /*      
        50 MBAO (6 decimals) in
        ~ 6.82 USDC (18 decimals) out
        */
        uint256 input = 50_000_000; // 50 MBAO with 6 decimals
        uint256 expectedOut = 6_821_282_401_091_405_184; // ~6.82 USDC with 18 decimals

        uint256 output = quoter.valueFor(
            address(tokenUSDC),
            address(tokenMBAO),
            input
        );

        assertEq(output, expectedOut);
    }

    function test_valueFor_differentDecimals_USDCtoMBAO() public {
        /*      
        100 USDC (18 decimals) in
        733 MBAO (6 decimals) out
        */
        uint256 input = 100 * 10 ** 18; // 100 USDC
        uint256 expectedOut = 733_000_000; // 733 MBAO

        uint256 output = quoter.valueFor(
            address(tokenMBAO),
            address(tokenUSDC),
            input
        );

        assertEq(output, expectedOut);
    }

    function test_valueFor_largeAmounts() public {
        /*      
        1,000,000 SRF in
        ~ 68,965 USD out
        */
        uint256 input = 1_000_000_000_000; // 1M SRF
        uint256 expectedOut = 68_965_517_241; // ~68,965 USD

        uint256 output = quoter.valueFor(
            address(tokenUSD),
            address(tokenSRF),
            input
        );

        assertEq(output, expectedOut);
    }

    function test_valueFor_smallAmounts() public {
        /*      
        0.01 TZS in
        ~ 0.000003 USD out (due to rounding with small amounts)
        */
        uint256 input = 10_000; // 0.01 TZS
        uint256 expectedOut = 3; // ~0.000003 USD (rounded down due to integer division)

        uint256 output = quoter.valueFor(
            address(tokenUSD),
            address(tokenTZS),
            input
        );

        assertEq(output, expectedOut);
    }

    function test_supportsInterface() public view {
        // ERC165
        assertTrue(quoter.supportsInterface(0x01ffc9a7));
        // ERC173 (Ownable)
        assertTrue(quoter.supportsInterface(0x9493f8b2));
        // TokenQuote
        assertTrue(quoter.supportsInterface(0xdbb21d40));
        // Invalid interface
        assertFalse(quoter.supportsInterface(0x12345678));
    }
}

// Mock token for testing
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
