// Author:	Mohamed Sohail <sohail@grassecon.org> 43CA77F641ADA031C12665CB47461C31B006BC0E
// Author:	Louis Holbrook <dev@holbrook.no> 0826EDA1702D1E87C6E2875121D2E7BB88C2A746
// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import "solady/auth/Ownable.sol";
import "solady/utils/Initializable.sol";

contract AccountsIndex is Ownable, Initializable {
    error Access();
    error AlreadyExists();
    error NotFound();
    error NotBlocked();
    error NotActive();
    error IndexFull();

    uint256 constant BLOCKED_FIELD = 1 << 128;

    address[] private entryList;
    mapping(address => uint256) private entryIndex;

    mapping(address => bool) public writers;

    event AddressAdded(address _account);
    event AddressActive(address indexed _account, bool _active);
    event AddressRemoved(address _account);
    event WriterAdded(address _account);
    event WriterDeleted(address _account);

    constructor() {
        _disableInitializers();
    }

    function initialize(address owner_) external initializer {
        _initializeOwner(owner_);
        entryList.push(address(0));
    }

    function entryCount() external view returns (uint256) {
        return entryList.length - 1;
    }

    function addWriter(address _writer) external onlyOwner returns (bool) {
        writers[_writer] = true;
        emit WriterAdded(_writer);
        return true;
    }

    function deleteWriter(address _writer) external onlyOwner returns (bool) {
        writers[_writer] = false;
        emit WriterDeleted(_writer);
        return true;
    }

    function isWriter(address _writer) external view returns (bool) {
        return writers[_writer] || _writer == owner();
    }

    function add(address _account) external returns (bool) {
        if (!writers[msg.sender] && msg.sender != owner()) revert Access();
        if (entryIndex[_account] != 0) revert AlreadyExists();
        if (entryList.length >= (1 << 64)) revert IndexFull();

        uint256 i = entryList.length;
        entryList.push(_account);
        uint256 _entry = uint64(i);
        _entry |= block.timestamp << 64;
        entryIndex[_account] = _entry;

        emit AddressAdded(_account);
        return true;
    }

    function remove(address _account) external returns (bool) {
        if (!writers[msg.sender] && msg.sender != owner()) revert Access();
        if (!this.have(_account)) revert AlreadyExists();

        uint256 l = entryList.length - 1;
        uint256 i = entryIndex[_account];

        if (i < l) {
            entryList[i] = entryList[l];
        }

        entryList.pop();
        entryIndex[_account] = 0;

        emit AddressRemoved(_account);
        return true;
    }

    function activate(address _account) external returns (bool) {
        if (!writers[msg.sender] && msg.sender != owner()) revert Access();
        if (entryIndex[_account] == 0) revert NotFound();
        if ((entryIndex[_account] & BLOCKED_FIELD) != BLOCKED_FIELD) revert NotBlocked();

        entryIndex[_account] >>= 129;
        emit AddressActive(_account, true);
        return true;
    }

    function deactivate(address _account) external returns (bool) {
        if (!writers[msg.sender] && msg.sender != owner()) revert Access();
        if (entryIndex[_account] == 0) revert NotFound();
        if ((entryIndex[_account] & BLOCKED_FIELD) == BLOCKED_FIELD) revert NotActive();

        entryIndex[_account] <<= 129;
        entryIndex[_account] |= BLOCKED_FIELD;
        emit AddressActive(_account, false);
        return true;
    }

    function entry(uint256 _i) external view returns (address) {
        return entryList[_i + 1];
    }

    function time(address _account) external view returns (uint256) {
        if (entryIndex[_account] == 0) revert NotFound();
        return entryIndex[_account] >> 64;
    }

    function have(address _account) external view returns (bool) {
        return entryIndex[_account] > 0;
    }

    function isActive(address _account) external view returns (bool) {
        return this.have(_account) && (entryIndex[_account] & BLOCKED_FIELD) != BLOCKED_FIELD;
    }

    function supportsInterface(bytes4 _sum) external pure returns (bool) {
        return
            _sum == 0xb7bca625 || _sum == 0x9479f0ae || _sum == 0x01ffc9a7 || _sum == 0x9493f8b2 || _sum == 0xabe1f1f5;
    }
}
