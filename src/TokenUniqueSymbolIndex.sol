// Author:	Mohamed Sohail <sohail@grassecon.org> 43CA77F641ADA031C12665CB47461C31B006BC0E
// Author:	Louis Holbrook <dev@holbrook.no> 0826EDA1702D1E87C6E2875121D2E7BB88C2A746
// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import "solady/auth/Ownable.sol";
import "solady/utils/Initializable.sol";

contract TokenUniqueSymbolIndex is Ownable, Initializable {
    error Access();
    error TokenSymbolTooLong();
    error NotFound();
    error SymbolAlreadyExists();

    mapping(address => bool) public isWriter;
    mapping(bytes32 => uint256) private registry;
    mapping(address => bytes32) public tokenIndex;
    address[] private tokens;
    bytes32[] public identifierList;

    event AddressKey(bytes32 indexed _symbol, address _token);
    event AddressAdded(address _token);
    event AddressRemoved(address _token);
    event WriterAdded(address _writer);
    event WriterDeleted(address _writer);

    constructor() {
        _disableInitializers();
    }

    function initialize(address owner_, address[] memory initialTokens, bytes32[] memory initialSymbols)
        external
        initializer
    {
        _initializeOwner(owner_);

        tokens.push(address(0));
        identifierList.push(bytes32(0));

        for (uint256 i = 0; i < initialTokens.length; i++) {
            _register(initialTokens[i], initialSymbols[i]);
        }
    }

    function entry(uint256 _idx) external view returns (address) {
        return tokens[_idx + 1];
    }

    function addressOf(bytes32 _key) external view returns (address) {
        uint256 idx = registry[_key];
        return tokens[idx];
    }

    function register(address _token) external returns (bool) {
        if (msg.sender != owner() && !isWriter[msg.sender]) revert Access();

        bytes memory tokenSymbol;
        (bool ok, bytes memory r) = _token.call(abi.encodeWithSignature("symbol()"));
        if (!ok) revert();
        tokenSymbol = abi.decode(r, (bytes));
        if (tokenSymbol.length > 32) revert TokenSymbolTooLong();
        bytes32 symbolKey = bytes32(tokenSymbol);

        _register(_token, symbolKey);
        return true;
    }

    function _register(address _token, bytes32 _symbolKey) internal {
        uint256 idx = registry[_symbolKey];
        if (idx != 0) revert SymbolAlreadyExists();

        registry[_symbolKey] = tokens.length;
        tokens.push(_token);
        identifierList.push(_symbolKey);
        tokenIndex[_token] = _symbolKey;

        emit AddressKey(_symbolKey, _token);
        emit AddressAdded(_token);
    }

    function add(address _token) external returns (bool) {
        bytes memory tokenSymbol;
        (bool ok, bytes memory r) = _token.call(abi.encodeWithSignature("symbol()"));
        if (!ok) revert();
        tokenSymbol = abi.decode(r, (bytes));
        if (tokenSymbol.length > 32) revert TokenSymbolTooLong();
        bytes32 symbolKey = bytes32(tokenSymbol);

        _register(_token, symbolKey);
        return true;
    }

    function time(address) external pure returns (uint256) {
        return 0;
    }

    function remove(address _token) external returns (bool) {
        if (msg.sender != owner() && !isWriter[msg.sender]) revert Access();
        if (tokenIndex[_token] == bytes32(0)) revert NotFound();

        uint256 i = registry[tokenIndex[_token]];
        uint256 l = tokens.length - 1;

        if (i < l) {
            tokens[i] = tokens[l];
            identifierList[i] = identifierList[l];
        }

        registry[identifierList[i]] = i;
        tokens.pop();
        identifierList.pop();
        registry[tokenIndex[_token]] = 0;
        tokenIndex[_token] = bytes32(0);

        emit AddressRemoved(_token);
        return true;
    }

    function activate(address) external pure returns (bool) {
        return false;
    }

    function deactivate(address) external pure returns (bool) {
        return false;
    }

    function entryCount() external view returns (uint256) {
        return tokens.length - 1;
    }

    function addWriter(address _writer) external onlyOwner returns (bool) {
        isWriter[_writer] = true;
        emit WriterAdded(_writer);
        return true;
    }

    function deleteWriter(address _writer) external onlyOwner returns (bool) {
        isWriter[_writer] = false;
        emit WriterDeleted(_writer);
        return true;
    }

    function identifier(uint256 _idx) external view returns (bytes32) {
        return identifierList[_idx + 1];
    }

    function identifierCount() external view returns (uint256) {
        return identifierList.length - 1;
    }

    function have(address _token) external view returns (bool) {
        return tokenIndex[_token] != bytes32(0x0);
    }

    function supportsInterface(bytes4 _sum) external pure returns (bool) {
        return _sum == 0xeffbf671 || _sum == 0xb7bca625 || _sum == 0x9479f0ae || _sum == 0x01ffc9a7
            || _sum == 0x9493f8b2 || _sum == 0x80c84bd6;
    }
}
