// Author:	Mohamed Sohail <sohail@grassecon.org> 43CA77F641ADA031C12665CB47461C31B006BC0E
// Author:	Louis Holbrook <dev@holbrook.no> 0826EDA1702D1E87C6E2875121D2E7BB88C2A746
// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import "solady/tokens/ERC20.sol";
import "solady/auth/Ownable.sol";
import "solady/utils/Initializable.sol";

contract GiftableToken is ERC20, Ownable, Initializable {
    error TokenExpired();

    mapping(address => bool) public writers;
    bool public expired;
    uint256 public totalBurned;
    uint256 public totalMinted;

    string private _name;
    string private _symbol;
    uint8 private _decimals;
    uint256 private _expires;

    event Mint(
        address indexed minter,
        address indexed beneficiary,
        uint256 value
    );
    event Burn(address indexed from, uint256 value);
    event Expired(uint256 timestamp);
    event WriterAdded(address indexed writer);
    event WriterRemoved(address indexed writer);

    constructor() {
        _disableInitializers();
    }

    function initialize(
        string memory name_,
        string memory symbol_,
        uint8 decimals_,
        address owner,
        uint256 expiresAt
    ) external initializer {
        _initializeOwner(owner);

        _name = name_;
        _symbol = symbol_;
        _decimals = decimals_;
        _expires = expiresAt;
    }

    modifier onlyWriter() virtual {
        if (msg.sender != owner() && !writers[msg.sender]) {
            revert Unauthorized();
        }
        _;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function name() public view override returns (string memory) {
        return _name;
    }

    function symbol() public view override returns (string memory) {
        return _symbol;
    }

    function totalSupply() public view override returns (uint256) {
        return totalMinted - totalBurned;
    }

    function addWriter(address _minter) public onlyOwner returns (bool) {
        writers[_minter] = true;
        emit WriterAdded(_minter);
        return true;
    }

    function isWriter(address _minter) public view returns (bool) {
        return writers[_minter] || _minter == owner();
    }

    function deleteWriter(address _minter) public onlyOwner returns (bool) {
        writers[_minter] = false;
        emit WriterRemoved(_minter);
        return true;
    }

    function mintTo(address to_, uint256 amount_) external onlyWriter {
        totalMinted += amount_;
        _mint(to_, amount_);
        emit Mint(msg.sender, to_, amount_);
    }

    function applyExpiry() public returns (uint8) {
        if (_expires == 0) {
            return 0;
        }
        if (expired) {
            return 1;
        }
        if (block.timestamp >= _expires) {
            expired = true;
            emit Expired(block.timestamp);
            return 2;
        }
        return 0;
    }

    function burn(uint256 _value) external onlyOwner {
        if (balanceOf(msg.sender) < _value) {
            revert InsufficientBalance();
        }
        totalBurned += _value;
        _burn(msg.sender, _value);
        emit Burn(msg.sender, _value);
    }

    function _beforeTokenTransfer(
        address,
        address,
        uint256
    ) internal virtual override {
        if (applyExpiry() != 0) revert TokenExpired();
    }

    function supportsInterface(bytes4 interfaceId) public pure returns (bool) {
        return
            interfaceId == 0x01ffc9a7 ||
            interfaceId == 0xb61bc941 ||
            interfaceId == 0x449a52f8 ||
            interfaceId == 0x9493f8b2 ||
            interfaceId == 0xabe1f1f5 ||
            interfaceId == 0xb1110c1b ||
            interfaceId == 0x841a0e94;
    }
}
