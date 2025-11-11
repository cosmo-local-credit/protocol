// Author:	Mohamed Sohail <sohail@grassecon.org> 43CA77F641ADA031C12665CB47461C31B006BC0E
// Author:	Louis Holbrook <dev@holbrook.no> 0826EDA1702D1E87C6E2875121D2E7BB88C2A746
// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import {ILimiter} from "./interfaces/ILimiter.sol";
import "solady/auth/Ownable.sol";
import "solady/utils/Initializable.sol";

contract Limiter is ILimiter, Ownable, Initializable {
    error InvalidHolder();

    mapping(address => mapping(address => uint256)) private limits;
    mapping(address => bool) public writers;

    event LimitSet(address indexed token, address indexed holder, uint256 value);
    event WriterAdded(address indexed writer);
    event WriterRemoved(address indexed writer);

    modifier onlyWriter() {
        if (msg.sender != owner() && !writers[msg.sender]) {
            revert Unauthorized();
        }
        _;
    }

    constructor() {
        _disableInitializers();
    }

    function initialize(address owner_) external initializer {
        _initializeOwner(owner_);
    }

    function limitOf(address token, address holder) external view override returns (uint256) {
        return limits[token][holder];
    }

    function addWriter(address writer) external onlyOwner returns (bool) {
        writers[writer] = true;
        emit WriterAdded(writer);
        return true;
    }

    function isWriter(address writer) external view returns (bool) {
        return writers[writer] || writer == owner();
    }

    function deleteWriter(address writer) external onlyOwner returns (bool) {
        writers[writer] = false;
        emit WriterRemoved(writer);
        return true;
    }

    function setLimitFor(address token, address holder, uint256 value) external onlyWriter {
        // Ensure holder is a contract
        uint256 codeSize;
        assembly {
            codeSize := extcodesize(holder)
        }
        if (codeSize == 0) revert InvalidHolder();

        limits[token][holder] = value;
        emit LimitSet(token, holder, value);
    }

    // EIP165 support
    function supportsInterface(bytes4 interfaceId) public pure returns (bool) {
        return interfaceId == 0x01ffc9a7 // ERC165
            || interfaceId == 0x7f5828d0 // ERC173 (Ownable)
            || interfaceId == 0x23778613; // TokenLimit
    }
}
