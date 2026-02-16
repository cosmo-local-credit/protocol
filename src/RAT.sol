// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import {IRAT} from "./interfaces/IRAT.sol";
import "solady/auth/Ownable.sol";
import "solady/utils/Initializable.sol";

contract RAT is IRAT, Ownable, Initializable {
    error TooManyTokens();
    error EmptyTokenList();
    error ZeroAddress();

    uint8 public constant MAX_TOKENS = 5;

    mapping(address => address[]) private _tokens;
    mapping(address => bool) public writers;

    event TokensSet(address indexed account, address[] tokens);
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

    function setTokens(address[] calldata tokens) external {
        _setTokens(msg.sender, tokens);
    }

    function setTokensFor(address account, address[] calldata tokens) external onlyWriter {
        _setTokens(account, tokens);
    }

    function getTokens(address account) external view returns (address[] memory) {
        return _tokens[account];
    }

    function tokenAt(address account, uint256 index) external view returns (address) {
        return _tokens[account][index];
    }

    function tokenCount(address account) external view returns (uint256) {
        return _tokens[account].length;
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

    function _setTokens(address account, address[] calldata tokens) internal {
        if (tokens.length == 0) revert EmptyTokenList();
        if (tokens.length > MAX_TOKENS) revert TooManyTokens();
        for (uint256 i = 0; i < tokens.length; i++) {
            if (tokens[i] == address(0)) revert ZeroAddress();
        }
        _tokens[account] = tokens;
        emit TokensSet(account, tokens);
    }
}
