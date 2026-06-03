// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import {RescueVault} from "../src/RescueVault.sol";

contract RescueVaultTest is Test {
    error Unauthorized();
    error ZeroAddress();

    RescueVault vault;
    MockERC20 erc20;
    MockERC20 erc20b;
    MockERC721 erc721;
    MockERC1155 erc1155;

    address admin = makeAddr("admin");
    address recipient = makeAddr("recipient");
    address stranger = makeAddr("stranger");

    function setUp() public {
        vault = new RescueVault(admin);
        erc20 = new MockERC20();
        erc20b = new MockERC20();
        erc721 = new MockERC721();
        erc1155 = new MockERC1155();
    }

    function test_constructor_revertIf_zeroAdmin() public {
        vm.expectRevert(ZeroAddress.selector);
        new RescueVault(address(0));
    }

    function test_sweepETH() public {
        vm.deal(address(vault), 3 ether);

        vm.prank(admin);
        uint256 swept = vault.sweepETH(recipient);

        assertEq(swept, 3 ether);
        assertEq(address(vault).balance, 0);
        assertEq(recipient.balance, 3 ether);
    }

    function test_receiveAndFallback_acceptETH() public {
        vm.deal(stranger, 2 ether);

        vm.prank(stranger);
        (bool receiveOk,) = address(vault).call{value: 1 ether}("");
        assertTrue(receiveOk);

        vm.prank(stranger);
        (bool fallbackOk,) = address(vault).call{value: 1 ether}(hex"deadbeef");
        assertTrue(fallbackOk);

        assertEq(address(vault).balance, 2 ether);
    }

    function test_sweepERC20() public {
        erc20.mint(address(vault), 123);

        vm.prank(admin);
        uint256 swept = vault.sweepERC20(address(erc20), recipient);

        assertEq(swept, 123);
        assertEq(erc20.balanceOf(address(vault)), 0);
        assertEq(erc20.balanceOf(recipient), 123);
    }

    function test_sweepERC20s() public {
        erc20.mint(address(vault), 123);
        erc20b.mint(address(vault), 456);

        address[] memory tokens = new address[](2);
        tokens[0] = address(erc20);
        tokens[1] = address(erc20b);

        vm.prank(admin);
        uint256[] memory swept = vault.sweepERC20s(tokens, recipient);

        assertEq(swept[0], 123);
        assertEq(swept[1], 456);
        assertEq(erc20.balanceOf(recipient), 123);
        assertEq(erc20b.balanceOf(recipient), 456);
    }

    function test_sweepERC721() public {
        erc721.mint(admin, 7);

        vm.prank(admin);
        erc721.safeTransferFrom(admin, address(vault), 7);

        vm.prank(admin);
        vault.sweepERC721(address(erc721), 7, recipient);

        assertEq(erc721.ownerOf(7), recipient);
    }

    function test_sweepERC721s() public {
        erc721.mint(address(vault), 7);
        erc721.mint(address(vault), 8);

        uint256[] memory ids = new uint256[](2);
        ids[0] = 7;
        ids[1] = 8;

        vm.prank(admin);
        vault.sweepERC721s(address(erc721), ids, recipient);

        assertEq(erc721.ownerOf(7), recipient);
        assertEq(erc721.ownerOf(8), recipient);
    }

    function test_sweepERC1155() public {
        erc1155.mint(address(vault), 42, 9);

        vm.prank(admin);
        uint256 swept = vault.sweepERC1155(address(erc1155), 42, recipient);

        assertEq(swept, 9);
        assertEq(erc1155.balanceOf(address(vault), 42), 0);
        assertEq(erc1155.balanceOf(recipient, 42), 9);
    }

    function test_sweepERC1155Batch() public {
        erc1155.mint(address(vault), 42, 9);
        erc1155.mint(address(vault), 43, 10);

        uint256[] memory ids = new uint256[](2);
        ids[0] = 42;
        ids[1] = 43;

        vm.prank(admin);
        uint256[] memory swept = vault.sweepERC1155Batch(address(erc1155), ids, recipient);

        assertEq(swept[0], 9);
        assertEq(swept[1], 10);
        assertEq(erc1155.balanceOf(recipient, 42), 9);
        assertEq(erc1155.balanceOf(recipient, 43), 10);
    }

    function test_revertIf_notAdmin() public {
        vm.expectRevert(Unauthorized.selector);
        vm.prank(stranger);
        vault.sweepETH(recipient);
    }

    function test_revertIf_zeroRecipient() public {
        vm.expectRevert(ZeroAddress.selector);
        vm.prank(admin);
        vault.sweepETH(address(0));
    }

    function test_supportsReceiverInterfaces() public view {
        assertTrue(vault.supportsInterface(0x01ffc9a7));
        assertTrue(vault.supportsInterface(0x150b7a02));
        assertTrue(vault.supportsInterface(0x4e2312e0));
        assertFalse(vault.supportsInterface(0xffffffff));
    }
}

interface IERC721ReceiverLike {
    function onERC721Received(address operator, address from, uint256 tokenId, bytes calldata data)
        external
        returns (bytes4);
}

interface IERC1155ReceiverLike {
    function onERC1155Received(address operator, address from, uint256 id, uint256 amount, bytes calldata data)
        external
        returns (bytes4);

    function onERC1155BatchReceived(
        address operator,
        address from,
        uint256[] calldata ids,
        uint256[] calldata amounts,
        bytes calldata data
    ) external returns (bytes4);
}

contract MockERC20 {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "BALANCE");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract MockERC721 {
    mapping(uint256 => address) public ownerOf;

    function mint(address to, uint256 tokenId) external {
        ownerOf[tokenId] = to;
    }

    function safeTransferFrom(address from, address to, uint256 tokenId) external {
        require(ownerOf[tokenId] == from, "OWNER");
        require(msg.sender == from, "SENDER");
        ownerOf[tokenId] = to;
        if (to.code.length != 0) {
            require(
                IERC721ReceiverLike(to).onERC721Received(msg.sender, from, tokenId, "")
                    == IERC721ReceiverLike.onERC721Received.selector,
                "RECEIVER"
            );
        }
    }
}

contract MockERC1155 {
    mapping(address => mapping(uint256 => uint256)) public balanceOf;

    function mint(address to, uint256 id, uint256 amount) external {
        balanceOf[to][id] += amount;
    }

    function safeTransferFrom(address from, address to, uint256 id, uint256 amount, bytes calldata data) external {
        require(msg.sender == from, "SENDER");
        require(balanceOf[from][id] >= amount, "BALANCE");
        balanceOf[from][id] -= amount;
        balanceOf[to][id] += amount;
        if (to.code.length != 0) {
            require(
                IERC1155ReceiverLike(to).onERC1155Received(msg.sender, from, id, amount, data)
                    == IERC1155ReceiverLike.onERC1155Received.selector,
                "RECEIVER"
            );
        }
    }

    function safeBatchTransferFrom(
        address from,
        address to,
        uint256[] calldata ids,
        uint256[] calldata amounts,
        bytes calldata data
    ) external {
        require(msg.sender == from, "SENDER");
        require(ids.length == amounts.length, "LENGTH");
        for (uint256 i; i < ids.length; ++i) {
            require(balanceOf[from][ids[i]] >= amounts[i], "BALANCE");
            balanceOf[from][ids[i]] -= amounts[i];
            balanceOf[to][ids[i]] += amounts[i];
        }
        if (to.code.length != 0) {
            require(
                IERC1155ReceiverLike(to).onERC1155BatchReceived(msg.sender, from, ids, amounts, data)
                    == IERC1155ReceiverLike.onERC1155BatchReceived.selector,
                "RECEIVER"
            );
        }
    }
}
