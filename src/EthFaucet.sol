// Author:	Mohamed Sohail <sohail@grassecon.org> 43CA77F641ADA031C12665CB47461C31B006BC0E
// Author:	Louis Holbrook <dev@holbrook.no> 0826EDA1702D1E87C6E2875121D2E7BB88C2A746
// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import "solady/auth/Ownable.sol";
import "solady/utils/Initializable.sol";

contract EthFaucet is Ownable, Initializable {
    error InvalidState();
    error AlreadyLocked();
    error NotOwner();
    error Sealed();
    error InsufficientBalance();
    error NotInWhitelist();
    error PeriodBackend();
    error RegistryBackend();
    error PeriodBackendError();

    address public registry;
    address public periodChecker;
    uint256 public amount;

    uint8 public sealState;
    uint8 constant REGISTRY_STATE = 1;
    uint8 constant PERIODCHECKER_STATE = 2;
    uint8 constant VALUE_STATE = 4;
    uint8 public constant maxSealState = 7;

    address public constant token = address(0);

    event Give(address indexed _recipient, address indexed _token, uint256 _amount);
    event FaucetAmountChange(uint256 _amount);
    event SealStateChange(uint256 indexed _sealState, address _registry, address _periodChecker);

    constructor() {
        _disableInitializers();
    }

    function initialize(address owner_, uint256 amount_) external initializer {
        _initializeOwner(owner_);
        amount = amount_;
    }

    receive() external payable {}

    function seal(uint256 _state) public returns (uint256) {
        if (_state >= 8) revert InvalidState();
        if (_state & sealState != 0) revert AlreadyLocked();
        sealState |= uint8(_state);
        emit SealStateChange(sealState, registry, periodChecker);
        return sealState;
    }

    function setAmount(uint256 _v) public onlyOwner returns (uint256) {
        if (sealState & VALUE_STATE != 0) revert Sealed();
        amount = _v;
        emit FaucetAmountChange(amount);
        return amount;
    }

    function setPeriodChecker(address _checker) public onlyOwner {
        if (sealState & PERIODCHECKER_STATE != 0) revert Sealed();
        periodChecker = _checker;
        emit SealStateChange(sealState, registry, periodChecker);
    }

    function setRegistry(address _registry) public onlyOwner {
        if (sealState & REGISTRY_STATE != 0) revert Sealed();
        registry = _registry;
        emit SealStateChange(sealState, registry, periodChecker);
    }

    function _checkPeriod(address _recipient) private returns (bool) {
        if (periodChecker == address(0)) {
            return true;
        }

        (bool ok, bytes memory result) = periodChecker.call(abi.encodeWithSignature("have(address)", _recipient));
        if (!ok) revert PeriodBackend();
        return result[31] == 0x01;
    }

    function _checkRegistry(address _recipient) private returns (bool) {
        if (registry == address(0)) {
            return true;
        }

        (bool ok, bytes memory result) = registry.call(abi.encodeWithSignature("have(address)", _recipient));
        if (!ok) revert RegistryBackend();
        return result[31] == 0x01;
    }

    function _checkBalance() private view returns (bool) {
        return amount <= address(this).balance;
    }

    function check(address _recipient) public returns (bool) {
        if (!_checkPeriod(_recipient)) {
            return false;
        }
        if (!_checkRegistry(_recipient)) {
            return false;
        }
        return _checkBalance();
    }

    function _checkAndPoke(address _recipient) private returns (bool) {
        if (!_checkBalance()) {
            revert InsufficientBalance();
        }

        if (!_checkRegistry(_recipient)) {
            revert NotInWhitelist();
        }

        if (periodChecker == address(0)) {
            return true;
        }

        (bool ok, bytes memory result) = periodChecker.call(abi.encodeWithSignature("poke(address)", _recipient));
        if (!ok) revert PeriodBackend();
        if (result[31] == 0) revert PeriodBackend();
        return true;
    }

    function gimme() public returns (uint256) {
        if (!_checkAndPoke(msg.sender)) revert PeriodBackend();
        payable(msg.sender).transfer(amount);
        emit Give(msg.sender, address(0), amount);
        return amount;
    }

    function giveTo(address _recipient) public returns (uint256) {
        if (!_checkAndPoke(_recipient)) revert PeriodBackend();
        payable(_recipient).transfer(amount);
        emit Give(_recipient, address(0), amount);
        return amount;
    }

    function nextTime(address _subject) public returns (uint256) {
        (bool ok, bytes memory result) = periodChecker.call(abi.encodeWithSignature("next(address)", _subject));
        if (!ok) revert PeriodBackendError();
        return uint256(bytes32(result));
    }

    function nextBalance(address _subject) public returns (uint256) {
        (bool ok, bytes memory result) = periodChecker.call(abi.encodeWithSignature("balanceThreshold()", _subject));
        if (!ok) revert PeriodBackendError();
        return uint256(bytes32(result));
    }

    function tokenAmount() public view returns (uint256) {
        return amount;
    }

    function supportsInterface(bytes4 _sum) public pure returns (bool) {
        return _sum == 0x01ffc9a7 || _sum == 0x9493f8b2 || _sum == 0x1a3ac634 || _sum == 0x0d7491f8;
    }
}
