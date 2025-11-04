// Author:	Mohamed Sohail <sohail@grassecon.org> 43CA77F641ADA031C12665CB47461C31B006BC0E
// Author:	Louis Holbrook <dev@holbrook.no> 0826EDA1702D1E87C6E2875121D2E7BB88C2A746
// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import {IERC20} from "./interfaces/IERC20.sol";
import {IERC20Meta} from "./interfaces/IERC20Meta.sol";
import {IFeePolicy} from "./interfaces/IFeePolicy.sol";
import {IProtocolFeeController} from "./interfaces/IProtocolFeeController.sol";
import {ILimiter} from "./interfaces/ILimiter.sol";
import {IQuoter} from "./interfaces/IQuoter.sol";
import "solady/auth/Ownable.sol";
import "solady/utils/Initializable.sol";

contract SwapPool is IERC20Meta, Ownable, Initializable {
    error Sealed();
    error InvalidState();
    error AlreadyLocked();
    error TokenCallFailed();
    error TransferFailed();
    error QuoterCallFailed();
    error InsufficientBalance();
    error UnauthorizedToken();
    error RegistryCallFailed();
    error LimitExceeded();
    error LimiterCallFailed();
    error InvalidFeeAddress();
    error InsufficientFees();

    address public tokenRegistry;
    address public tokenLimiter;
    address public quoter;
    address public feeAddress;
    address public feePolicy;

    // Hardcoded protocol fee controller address
    address private constant PROTOCOL_FEE_CONTROLLER = address(0x0); // TODO: Set the actual address

    string private _name;
    string private _symbol;
    uint8 private _decimals;

    mapping(address => uint256) public fees;

    // If true, fees are decoupled from liquidity and accounted separately
    // If false (default), fees remain part of the pool liquidity
    bool public feesDecoupled;

    uint256 private constant PPM = 1_000_000;
    uint256 private constant DEFAULT_FEE_PPM = 10_000;

    // Implements Seal
    uint8 public sealState;

    uint8 constant FEE_STATE = 1;
    uint8 constant FEEADDRESS_STATE = 2;
    uint8 constant QUOTER_STATE = 4;

    uint8 public constant maxSealState = 7;

    // Implements Seal
    event SealStateChange(bool indexed _final, uint256 _sealState);

    // Emitted after a successful swap
    event Swap(
        address indexed initiator,
        address indexed tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        uint256 fee
    );

    // Emitted only after an explicit liquidity donation
    // Users can implictly donate via a normal send
    event Deposit(
        address indexed initiator,
        address indexed tokenIn,
        uint256 amountIn
    );

    // Emitted when collecting fees to the set feeAddress
    event Collect(
        address indexed feeAddress,
        address tokenOut,
        uint256 amountOut
    );

    constructor() {
        _disableInitializers();
    }

    function initialize(
        string memory name_,
        string memory symbol_,
        uint8 decimals_,
        address owner,
        address feePolicy_,
        address feeAddress_,
        address tokenRegistry_,
        address tokenLimiter_,
        address quoter_,
        bool feesDecoupled_
    ) external initializer {
        _initializeOwner(owner);

        _name = name_;
        _symbol = symbol_;
        _decimals = decimals_;

        feePolicy = feePolicy_;
        feeAddress = feeAddress_;
        tokenRegistry = tokenRegistry_;
        tokenLimiter = tokenLimiter_;
        quoter = quoter_;
        feesDecoupled = feesDecoupled_;
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

    function seal(uint8 _state) public onlyOwner returns (uint8) {
        if (_state > maxSealState) revert InvalidState();
        if (_state & sealState != 0) revert AlreadyLocked();
        sealState |= _state;
        emit SealStateChange(sealState == maxSealState, sealState);
        return sealState;
    }

    function isSealed(uint8 _state) public view returns (bool) {
        if (_state >= maxSealState) revert InvalidState();
        if (_state == 0) {
            return sealState == maxSealState;
        }
        return _state & sealState == _state;
    }

    function setFeeAddress(address _feeAddress) public onlyOwner {
        if (isSealed(FEEADDRESS_STATE)) revert Sealed();
        feeAddress = _feeAddress;
    }

    function setFeePolicy(address _feePolicy) public onlyOwner {
        if (isSealed(FEE_STATE)) revert Sealed();
        feePolicy = _feePolicy;
    }

    function setQuoter(address _quoter) public onlyOwner {
        if (isSealed(QUOTER_STATE)) revert Sealed();
        quoter = _quoter;
    }

    function setTokenRegistry(address _tokenRegistry) public onlyOwner {
        tokenRegistry = _tokenRegistry;
    }

    function setTokenLimiter(address _tokenLimiter) public onlyOwner {
        tokenLimiter = _tokenLimiter;
    }

    function deposit(address _token, uint256 _value) public {
        _deposit(_token, _value);
        emit Deposit(msg.sender, _token, _value);
    }

    function _deposit(address _token, uint256 _value) private {
        mustAllowedToken(_token, tokenRegistry);
        mustWithinLimit(_token, _value);

        bool success = IERC20(_token).transferFrom(
            msg.sender,
            address(this),
            _value
        );
        if (!success) revert TransferFailed();
    }

    function getQuote(
        address _outToken,
        address _inToken,
        uint256 _value
    ) public returns (uint256) {
        if (quoter == address(0x0)) {
            return _value;
        }

        return IQuoter(quoter).valueFor(_outToken, _inToken, _value);
    }

    function getFee(
        address _inToken,
        address _outToken,
        uint256 _value
    ) public view returns (uint256) {
        if (feePolicy == address(0)) {
            return 0;
        }

        uint256 feePpm = IFeePolicy(feePolicy).getFee(_inToken, _outToken);
        return (_value * feePpm) / PPM;
    }

    function withdraw(
        address _outToken,
        address _inToken,
        uint256 _value
    ) public {
        // First, deposit the input token
        deposit(_inToken, _value);

        // Get the quote for the output token
        uint256 quotedValue = getQuote(_outToken, _inToken, _value);

        // Calculate fee on the quoted output value
        uint256 totalFee = getFee(_inToken, _outToken, quotedValue);
        uint256 netValue = quotedValue - totalFee;

        // Check balance
        uint256 balance = IERC20(_outToken).balanceOf(address(this));
        if (balance < quotedValue) revert InsufficientBalance();

        // Calculate protocol fee
        IProtocolFeeController controller = IProtocolFeeController(
            PROTOCOL_FEE_CONTROLLER
        );
        uint256 protocolFeePpm = controller.getProtocolFee();
        address protocolRecipient = controller.getProtocolFeeRecipient();

        uint256 protocolFee = 0;
        if (protocolFeePpm > 0 && protocolRecipient != address(0)) {
            // If totalFee is 0, apply default 1% protocol fee
            if (totalFee == 0) {
                protocolFee = (DEFAULT_FEE_PPM * protocolFeePpm) / PPM;
            } else {
                // Protocol fee is a percentage of the total fee
                protocolFee = (totalFee * protocolFeePpm) / PPM;
            }

            // Transfer protocol fee in real-time
            bool protocolSuccess = IERC20(_outToken).transfer(
                protocolRecipient,
                protocolFee
            );
            if (!protocolSuccess) revert TransferFailed();
        }

        uint256 poolOwnerFee = totalFee - protocolFee;

        // Transfer net amount to user
        bool success = IERC20(_outToken).transfer(msg.sender, netValue);
        if (!success) revert TransferFailed();

        // Always account for pool owner fees
        // When feesDecoupled = true: all fees can be withdrawn
        // When feesDecoupled = false: fees tracked but must maintain liquidity
        if (poolOwnerFee > 0 && feeAddress != address(0)) {
            fees[_outToken] += poolOwnerFee;
        }

        emit Swap(
            msg.sender,
            _inToken,
            _outToken,
            _value,
            quotedValue,
            totalFee
        );
    }

    function withdraw(address _outToken) public onlyOwner returns (uint256) {
        uint256 balance = fees[_outToken];
        fees[_outToken] = 0;

        return withdraw(_outToken, balance);
    }

    function withdraw(
        address _outToken,
        uint256 _value
    ) public onlyOwner returns (uint256) {
        if (feeAddress == address(0)) revert InvalidFeeAddress();
        if (_value > fees[_outToken]) revert InsufficientFees();

        // When feesDecoupled = false, ensure we maintain minimum liquidity
        // Check actual balance to ensure withdrawal is possible
        if (!feesDecoupled) {
            uint256 balance = IERC20(_outToken).balanceOf(address(this));
            // Ensure we have enough balance and maintain some liquidity
            if (_value > balance) revert InsufficientBalance();
        }

        fees[_outToken] -= _value;

        bool success = IERC20(_outToken).transfer(feeAddress, _value);
        if (!success) revert TransferFailed();

        emit Collect(feeAddress, _outToken, _value);
        return _value;
    }

    // Owner can withdraw all liquidity.
    // Certain use-cases may require this functionality.
    // It is recommended that the owner be a timelock or multisig or both.
    function withdrawLiquidity(
        address token,
        address to,
        uint256 amount
    ) external onlyOwner returns (uint256) {
        uint256 balance = IERC20(token).balanceOf(address(this));
        if (amount > balance) revert InsufficientBalance();

        bool success = IERC20(token).transfer(to, amount);
        if (!success) revert TransferFailed();

        return amount;
    }

    function mustAllowedToken(address _token, address _tokenRegistry) private {
        if (_tokenRegistry == address(0)) {
            return;
        }

        (bool r, bytes memory v) = _tokenRegistry.call(
            abi.encodeWithSignature("have(address)", _token)
        );
        if (!r) revert RegistryCallFailed();
        bool isAllowed = abi.decode(v, (bool));
        if (!isAllowed) revert UnauthorizedToken();
    }

    function mustWithinLimit(address _token, uint256 _valueDelta) private view {
        if (tokenLimiter == address(0)) {
            return;
        }

        uint256 limit = ILimiter(tokenLimiter).limitOf(_token, address(this));
        uint256 balance = IERC20(_token).balanceOf(address(this));
        if (balance + _valueDelta > limit) revert LimitExceeded();
    }
}
