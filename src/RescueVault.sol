// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

interface IERC721Rescue {
    function safeTransferFrom(address from, address to, uint256 tokenId) external;
}

interface IERC1155Rescue {
    function balanceOf(address account, uint256 id) external view returns (uint256);

    function safeTransferFrom(address from, address to, uint256 id, uint256 amount, bytes calldata data) external;

    function safeBatchTransferFrom(
        address from,
        address to,
        uint256[] calldata ids,
        uint256[] calldata amounts,
        bytes calldata data
    ) external;
}

/// @title RescueVault
/// @notice Plain CREATE-deployed recovery contract for assets accidentally sent to a future contract address.
/// @dev The CREATE address depends only on deployer address and nonce, not constructor args.
contract RescueVault {
    address public immutable admin;

    error Unauthorized();
    error ZeroAddress();

    event SweepETH(address indexed to, uint256 amount);
    event SweepERC20(address indexed token, address indexed to, uint256 amount);
    event SweepERC721(address indexed token, address indexed to, uint256 indexed tokenId);
    event SweepERC1155(address indexed token, address indexed to, uint256 indexed id, uint256 amount);
    event SweepERC1155Batch(address indexed token, address indexed to, uint256[] ids, uint256[] amounts);

    constructor(address admin_) payable {
        if (admin_ == address(0)) revert ZeroAddress();
        admin = admin_;
    }

    receive() external payable {}

    fallback() external payable {}

    modifier onlyAdmin() {
        if (msg.sender != admin) revert Unauthorized();
        _;
    }

    function sweepETH(address to) external onlyAdmin returns (uint256 amount) {
        _checkTo(to);
        amount = address(this).balance;
        SafeTransferLib.safeTransferAllETH(to);
        emit SweepETH(to, amount);
    }

    function sweepERC20(address token, address to) external onlyAdmin returns (uint256 amount) {
        _checkTo(to);
        amount = SafeTransferLib.safeTransferAll(token, to);
        emit SweepERC20(token, to, amount);
    }

    function sweepERC20s(address[] calldata tokens, address to) external onlyAdmin returns (uint256[] memory amounts) {
        _checkTo(to);
        amounts = new uint256[](tokens.length);
        for (uint256 i; i < tokens.length; ++i) {
            amounts[i] = SafeTransferLib.safeTransferAll(tokens[i], to);
            emit SweepERC20(tokens[i], to, amounts[i]);
        }
    }

    function sweepERC721(address token, uint256 tokenId, address to) public onlyAdmin {
        _checkTo(to);
        IERC721Rescue(token).safeTransferFrom(address(this), to, tokenId);
        emit SweepERC721(token, to, tokenId);
    }

    function sweepERC721s(address token, uint256[] calldata tokenIds, address to) external onlyAdmin {
        for (uint256 i; i < tokenIds.length; ++i) {
            sweepERC721(token, tokenIds[i], to);
        }
    }

    function sweepERC1155(address token, uint256 id, address to) public onlyAdmin returns (uint256 amount) {
        _checkTo(to);
        amount = IERC1155Rescue(token).balanceOf(address(this), id);
        IERC1155Rescue(token).safeTransferFrom(address(this), to, id, amount, "");
        emit SweepERC1155(token, to, id, amount);
    }

    function sweepERC1155Batch(address token, uint256[] calldata ids, address to)
        external
        onlyAdmin
        returns (uint256[] memory amounts)
    {
        _checkTo(to);
        amounts = new uint256[](ids.length);
        for (uint256 i; i < ids.length; ++i) {
            amounts[i] = IERC1155Rescue(token).balanceOf(address(this), ids[i]);
        }
        IERC1155Rescue(token).safeBatchTransferFrom(address(this), to, ids, amounts, "");
        emit SweepERC1155Batch(token, to, ids, amounts);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }

    function onERC1155Received(address, address, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(address, address, uint256[] calldata, uint256[] calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return this.onERC1155BatchReceived.selector;
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == 0x01ffc9a7 // ERC165
            || interfaceId == this.onERC721Received.selector || interfaceId == 0x4e2312e0; // ERC1155Receiver
    }

    function _checkTo(address to) internal pure {
        if (to == address(0)) revert ZeroAddress();
    }
}
