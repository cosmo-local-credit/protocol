// Author:	Mohamed Sohail <sohail@grassecon.org> 43CA77F641ADA031C12665CB47461C31B006BC0E
// Author:	Louis Holbrook <dev@holbrook.no> 0826EDA1702D1E87C6E2875121D2E7BB88C2A746
// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import "solady/auth/Ownable.sol";
import "solady/utils/Initializable.sol";

contract ContractRegistry is Ownable, Initializable {
    error Access();
    error IdentifierAlreadyExists();
    error IdentifierNotFound();
    error ZeroAddress();

    mapping(bytes32 => address) private entries;
    bytes32[] public identifier;

    event AddressKey(bytes32 indexed _key, address _address);

    constructor() {
        _disableInitializers();
    }

    function initialize(address owner_, bytes32[] memory _identifiers) external initializer {
        _initializeOwner(owner_);

        for (uint256 i = 0; i < _identifiers.length; i++) {
            identifier.push(_identifiers[i]);
        }
    }

    function set(bytes32 _identifier, address _address) external onlyOwner returns (bool) {
        if (entries[_identifier] != address(0)) revert IdentifierAlreadyExists();
        if (_address == address(0)) revert ZeroAddress();

        bool found = false;
        for (uint256 i = 0; i < identifier.length; i++) {
            if (identifier[i] == _identifier) {
                found = true;
                break;
            }
        }
        if (!found) revert IdentifierNotFound();

        entries[_identifier] = _address;

        emit AddressKey(_identifier, _address);
        return true;
    }

    function addressOf(bytes32 _identifier) external view returns (address) {
        return entries[_identifier];
    }

    function identifierCount() external view returns (uint256) {
        return identifier.length;
    }

    function supportsInterface(bytes4 _sum) external pure returns (bool) {
        return _sum == 0xeffbf671 || _sum == 0x01ffc9a7 || _sum == 0x9493f8b2;
    }
}
