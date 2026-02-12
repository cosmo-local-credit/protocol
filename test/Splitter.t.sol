// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import {LibClone} from "solady/utils/LibClone.sol";
import {Splitter} from "../src/Splitter.sol";

contract SplitterTest is Test {
    Splitter splitter;
    Splitter implementation;

    address owner = makeAddr("owner");
    address r1 = address(0x1001);
    address r2 = address(0x1002);
    address r3 = address(0x1003);

    MockERC20 token;
    MockERC20 token6;
    MockERC20 token18;

    receive() external payable {}

    function setUp() public {
        implementation = new Splitter();
        address splitterAddress = LibClone.clone(address(implementation));
        splitter = Splitter(payable(splitterAddress));

        address[] memory accounts = new address[](2);
        accounts[0] = r1;
        accounts[1] = r2;
        uint32[] memory allocs = new uint32[](2);
        allocs[0] = 600_000;
        allocs[1] = 400_000;

        splitter.initialize(owner, accounts, allocs);

        token = new MockERC20("Mock", "MOCK", 18);
        token6 = new MockERC20("Mock6", "M6", 6);
        token18 = new MockERC20("Mock18", "M18", 18);
    }

    function test_initialize_setsHashAndOwner() public {
        address[] memory accounts = new address[](2);
        accounts[0] = r1;
        accounts[1] = r2;
        uint32[] memory allocs = new uint32[](2);
        allocs[0] = 600_000;
        allocs[1] = 400_000;

        bytes32 expected = keccak256(abi.encodePacked(accounts, allocs));
        assertEq(splitter.getHash(), expected);
        assertEq(splitter.owner(), owner);
    }

    function test_distributeETH_sendsToRecipients() public {
        address[] memory accounts = new address[](2);
        accounts[0] = r1;
        accounts[1] = r2;
        uint32[] memory allocs = new uint32[](2);
        allocs[0] = 600_000;
        allocs[1] = 400_000;

        vm.deal(address(this), 10 ether);
        (bool ok,) = address(splitter).call{value: 1 ether}("");
        assertTrue(ok);

        uint256 r1Before = r1.balance;
        uint256 r2Before = r2.balance;

        splitter.distributeETH(accounts, allocs);

        assertEq(r1.balance - r1Before, 0.6 ether);
        assertEq(r2.balance - r2Before, 0.4 ether);
        assertEq(address(splitter).balance, 0);
    }

    function test_distributeETH_remainderGoesToLastRecipient() public {
        address[] memory accounts = new address[](3);
        accounts[0] = r1;
        accounts[1] = r2;
        accounts[2] = r3;
        uint32[] memory allocs = new uint32[](3);
        allocs[0] = 333_333;
        allocs[1] = 333_333;
        allocs[2] = 333_334;

        vm.prank(owner);
        splitter.updateSplit(accounts, allocs);

        // 1 ether + 1 wei to force rounding.
        vm.deal(address(this), 10 ether);
        (bool ok,) = address(splitter).call{value: 1 ether + 1}("");
        assertTrue(ok);

        uint256 r1Before = r1.balance;
        uint256 r2Before = r2.balance;
        uint256 r3Before = r3.balance;

        splitter.distributeETH(accounts, allocs);

        uint256 amount = 1 ether + 1;
        uint256 s1 = (amount * 333_333) / 1_000_000;
        uint256 s2 = (amount * 333_333) / 1_000_000;
        uint256 s3 = amount - s1 - s2;

        assertEq(r1.balance - r1Before, s1);
        assertEq(r2.balance - r2Before, s2);
        assertEq(r3.balance - r3Before, s3);
        assertEq(address(splitter).balance, 0);
    }

    function test_distributeERC20_sendsToRecipients() public {
        address[] memory accounts = new address[](3);
        accounts[0] = r1;
        accounts[1] = r2;
        accounts[2] = r3;
        uint32[] memory allocs = new uint32[](3);
        allocs[0] = 500_000;
        allocs[1] = 300_000;
        allocs[2] = 200_000;

        vm.prank(owner);
        splitter.updateSplit(accounts, allocs);

        token.mint(address(splitter), 1_000_000);

        uint256 r1Before = token.balanceOf(r1);
        uint256 r2Before = token.balanceOf(r2);
        uint256 r3Before = token.balanceOf(r3);

        splitter.distributeERC20(address(token), accounts, allocs);

        assertEq(token.balanceOf(r1) - r1Before, 500_000);
        assertEq(token.balanceOf(r2) - r2Before, 300_000);
        assertEq(token.balanceOf(r3) - r3Before, 200_000);
        assertEq(token.balanceOf(address(splitter)), 0);
    }

    function test_distributeERC20_token6Decimals_exactSplit() public {
        address[] memory accounts = new address[](3);
        accounts[0] = r1;
        accounts[1] = r2;
        accounts[2] = r3;
        uint32[] memory allocs = new uint32[](3);
        allocs[0] = 500_000;
        allocs[1] = 300_000;
        allocs[2] = 200_000;

        vm.prank(owner);
        splitter.updateSplit(accounts, allocs);

        // 1.000000 token with 6 decimals.
        uint256 amount = 1_000_000;
        token6.mint(address(splitter), amount);

        uint256 r1Before = token6.balanceOf(r1);
        uint256 r2Before = token6.balanceOf(r2);
        uint256 r3Before = token6.balanceOf(r3);

        splitter.distributeERC20(address(token6), accounts, allocs);

        assertEq(token6.balanceOf(r1) - r1Before, 500_000);
        assertEq(token6.balanceOf(r2) - r2Before, 300_000);
        assertEq(token6.balanceOf(r3) - r3Before, 200_000);
        assertEq(token6.balanceOf(address(splitter)), 0);
    }

    function test_distributeERC20_token18Decimals_remainderGoesToLastRecipient() public {
        address[] memory accounts = new address[](3);
        accounts[0] = r1;
        accounts[1] = r2;
        accounts[2] = r3;
        uint32[] memory allocs = new uint32[](3);
        allocs[0] = 333_333;
        allocs[1] = 333_333;
        allocs[2] = 333_334;

        vm.prank(owner);
        splitter.updateSplit(accounts, allocs);

        // 1 ether + 1 wei in token units, to force rounding.
        uint256 amount = 1 ether + 1;
        token18.mint(address(splitter), amount);

        uint256 r1Before = token18.balanceOf(r1);
        uint256 r2Before = token18.balanceOf(r2);
        uint256 r3Before = token18.balanceOf(r3);

        splitter.distributeERC20(address(token18), accounts, allocs);

        uint256 s1 = (amount * 333_333) / 1_000_000;
        uint256 s2 = (amount * 333_333) / 1_000_000;
        uint256 s3 = amount - s1 - s2;

        assertEq(token18.balanceOf(r1) - r1Before, s1);
        assertEq(token18.balanceOf(r2) - r2Before, s2);
        assertEq(token18.balanceOf(r3) - r3Before, s3);
        assertEq(token18.balanceOf(address(splitter)), 0);
    }

    function test_updateSplit_revertIf_notOwner() public {
        address[] memory accounts = new address[](2);
        accounts[0] = r1;
        accounts[1] = r3;
        uint32[] memory allocs = new uint32[](2);
        allocs[0] = 700_000;
        allocs[1] = 300_000;

        vm.expectRevert();
        splitter.updateSplit(accounts, allocs);
    }

    function test_distributeETH_revertIf_invalidHash() public {
        address[] memory accounts = new address[](2);
        accounts[0] = r1;
        accounts[1] = r2;
        uint32[] memory allocs = new uint32[](2);
        allocs[0] = 700_000;
        allocs[1] = 300_000;

        vm.deal(address(splitter), 1 ether);
        vm.expectRevert(Splitter.InvalidHash.selector);
        splitter.distributeETH(accounts, allocs);
    }

    function test_distributeETH_revertIf_outOfOrder() public {
        address[] memory accounts = new address[](2);
        accounts[0] = r2;
        accounts[1] = r1;
        uint32[] memory allocs = new uint32[](2);
        allocs[0] = 600_000;
        allocs[1] = 400_000;

        vm.deal(address(splitter), 1 ether);
        vm.expectRevert(Splitter.AccountsOutOfOrder.selector);
        splitter.distributeETH(accounts, allocs);
    }
}

contract MockERC20 {
    string public name;
    string public symbol;
    uint8 public decimals;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory n, string memory s, uint8 d) {
        name = n;
        symbol = s;
        decimals = d;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}
