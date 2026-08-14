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
import "solady/utils/ReentrancyGuard.sol";

contract SwapPool is IERC20Meta, Ownable, Initializable, ReentrancyGuard {
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
    error InvalidRecipient();
    error InvalidToken();
    error Expired();
    error InsufficientOutput();
    error FeeTooHigh();

    address public tokenRegistry;
    address public tokenLimiter;
    address public quoter;
    address public feeAddress;
    address public feePolicy;
    address public protocolFeeController;

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
    uint8 constant REGISTRY_STATE = 8;
    uint8 constant LIMITER_STATE = 16;

    uint8 public constant maxSealState = 31;

    // Reserved so that a later variable cannot be packed beside sealState
    uint240 private __sealSlotPadding;
    // Written at initialize (and when a legacy pool first becomes fully sealed)
    // so raising maxSealState in a later implementation is not a silent unseal.
    uint8 public fullSealMask;
    uint256[48] private __gap;

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
    event Deposit(address indexed initiator, address indexed tokenIn, uint256 amountIn);

    // Emitted when collecting fees to the set feeAddress
    event Collect(address indexed feeAddress, address tokenOut, uint256 amountOut);

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
        bool feesDecoupled_,
        address protocolFeeController_
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
        protocolFeeController = protocolFeeController_;
        fullSealMask = maxSealState;
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
        if (_state & REGISTRY_STATE != 0 && tokenRegistry == address(0)) revert InvalidState();
        if (_state & LIMITER_STATE != 0 && tokenLimiter == address(0)) revert InvalidState();
        sealState |= _state;
        uint8 mask = _fullSealMask();
        if (fullSealMask == 0 && (sealState & maxSealState) == maxSealState) {
            fullSealMask = maxSealState;
            mask = maxSealState;
        }
        emit SealStateChange(sealState & mask == mask, sealState);
        return sealState;
    }

    function isSealed(uint8 _state) public view returns (bool) {
        if (_state > maxSealState) revert InvalidState();
        if (_state == 0) {
            uint8 mask = _fullSealMask();
            return sealState & mask == mask;
        }
        return _state & sealState == _state;
    }

    function _fullSealMask() private view returns (uint8) {
        uint8 mask = fullSealMask;
        return mask == 0 ? maxSealState : mask;
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
        if (isSealed(REGISTRY_STATE)) revert Sealed();
        tokenRegistry = _tokenRegistry;
    }

    function setTokenLimiter(address _tokenLimiter) public onlyOwner {
        if (isSealed(LIMITER_STATE)) revert Sealed();
        tokenLimiter = _tokenLimiter;
    }

    // Returns the amount the pool actually received, which is what every
    // downstream calculation is priced on
    function deposit(address _token, uint256 _value) public nonReentrant returns (uint256 received) {
        received = _deposit(_token, _value);
    }

    function _deposit(address _token, uint256 _value) private returns (uint256 received) {
        mustAllowedToken(_token, tokenRegistry);
        mustWithinLimit(_token, _value);

        uint256 balanceBefore = IERC20(_token).balanceOf(address(this));
        bool success = IERC20(_token).transferFrom(msg.sender, address(this), _value);
        if (!success) revert TransferFailed();

        received = IERC20(_token).balanceOf(address(this)) - balanceBefore;
        if (received == 0) revert TransferFailed();

        emit Deposit(msg.sender, _token, received);
    }

    function getQuote(address _outToken, address _inToken, uint256 _value) public returns (uint256) {
        if (quoter == address(0x0)) {
            return _value;
        }

        return IQuoter(quoter).valueFor(_outToken, _inToken, _value);
    }

    function getFee(address _inToken, address _outToken, uint256 _value) public view returns (uint256) {
        if (feePolicy == address(0)) {
            return 0;
        }

        uint256 feePpm = IFeePolicy(feePolicy).getFee(_inToken, _outToken);
        return (_value * feePpm) / PPM;
    }

    // Calculate the amount of output tokens received for a given input amount
    // Returns the net amount after all fees are deducted (including protocol fee)
    function getAmountOut(address _outToken, address _inToken, uint256 _amountIn) public returns (uint256) {
        uint256 quotedValue = getQuote(_outToken, _inToken, _amountIn);
        uint256 totalFee = getFee(_inToken, _outToken, quotedValue);
        uint256 protocolFee = _calcProtocolFee(quotedValue, totalFee);
        return _netAfterFees(quotedValue, totalFee, protocolFee);
    }

    // Calculate the amount of input tokens required to receive a desired output amount
    // Returns the input amount needed after accounting for all fees (including protocol fee)
    function getAmountIn(address _outToken, address _inToken, uint256 _amountOut) public returns (uint256) {
        uint256 feePpm = 0;
        if (feePolicy != address(0)) {
            feePpm = IFeePolicy(feePolicy).getFee(_inToken, _outToken);
        }

        uint256 protocolFeePpm = _getProtocolFeePpm();

        // Reverse-calculate the quotedValue from desired net output
        uint256 quotedValue = _reverseNetToQuoted(_amountOut, feePpm, protocolFeePpm);

        // Reverse the quoter: get input amount from quoted output
        uint256 amountIn;
        if (quoter == address(0x0)) {
            amountIn = quotedValue;
        } else {
            amountIn = IQuoter(quoter).reverseValueFor(_outToken, _inToken, quotedValue);
        }

        // +1 wei rounding safety
        return amountIn + 1;
    }

    // Extract protocol fee PPM, returning 0 if controller is unset or recipient is zero
    function _getProtocolFeePpm() internal view returns (uint256) {
        if (protocolFeeController == address(0)) return 0;
        IProtocolFeeController ctrl = IProtocolFeeController(protocolFeeController);
        uint256 pFeePpm = ctrl.getProtocolFee();
        address recipient = ctrl.getProtocolFeeRecipient();
        if (pFeePpm == 0 || recipient == address(0)) return 0;
        return pFeePpm;
    }

    // Reverse-calculate quotedValue from desired net output amount
    // netOutput = quotedValue - poolFee - protocolFee
    // Uses ceiling division to ensure sufficient input
    function _reverseNetToQuoted(uint256 _netOutput, uint256 _feePpm, uint256 _protocolFeePpm)
        internal
        pure
        returns (uint256)
    {
        if (_feePpm == 0 && _protocolFeePpm == 0) {
            return _netOutput;
        }

        if (_feePpm >= DEFAULT_FEE_PPM && _feePpm * (PPM + _protocolFeePpm) >= PPM * PPM) {
            revert FeeTooHigh();
        }

        // The protocol fee is based on max(totalFee, assumedFee) where assumedFee uses DEFAULT_FEE_PPM
        // Two cases based on whether pool fee >= DEFAULT_FEE_PPM (the floor)
        //
        // Case 1: feePpm >= DEFAULT_FEE_PPM
        //   totalFee = quotedValue * feePpm / PPM
        //   protocolFee = totalFee * protocolFeePpm / PPM = quotedValue * feePpm * protocolFeePpm / PPM²
        //   netOutput = quotedValue - totalFee - protocolFee
        //            = quotedValue * (PPM² - feePpm * PPM - feePpm * protocolFeePpm) / PPM²
        //            = quotedValue * (PPM² - feePpm * (PPM + protocolFeePpm)) / PPM²
        //
        // Case 2: feePpm < DEFAULT_FEE_PPM
        //   totalFee = quotedValue * feePpm / PPM
        //   protocolFee = assumedFee * protocolFeePpm / PPM = quotedValue * DEFAULT_FEE_PPM * protocolFeePpm / PPM²
        //   netOutput = quotedValue - totalFee - protocolFee
        //            = quotedValue * (PPM² - feePpm * PPM - DEFAULT_FEE_PPM * protocolFeePpm) / PPM²
        uint256 ppmSquared = PPM * PPM;
        uint256 denominator;

        if (_feePpm >= DEFAULT_FEE_PPM) {
            denominator = ppmSquared - _feePpm * (PPM + _protocolFeePpm);
        } else {
            denominator = ppmSquared - _feePpm * PPM - DEFAULT_FEE_PPM * _protocolFeePpm;
        }

        // Ceiling division: ceil(netOutput * PPM² / denominator)
        return (_netOutput * ppmSquared + denominator - 1) / denominator;
    }

    function withdraw(address _outToken, address _inToken, uint256 _value) public nonReentrant returns (uint256) {
        return _swap(_outToken, _inToken, _value, msg.sender);
    }

    function withdraw(address _outToken, address _inToken, uint256 _value, address _recipient)
        public
        nonReentrant
        returns (uint256)
    {
        if (_recipient == address(0)) revert InvalidRecipient();
        return _swap(_outToken, _inToken, _value, _recipient);
    }

    // Bounded swap: reverts unless the caller receives at least _minAmountOut
    // and the transaction is mined on or before _deadline
    function withdraw(
        address _outToken,
        address _inToken,
        uint256 _value,
        address _recipient,
        uint256 _minAmountOut,
        uint256 _deadline
    ) public nonReentrant returns (uint256 netValue) {
        if (_recipient == address(0)) revert InvalidRecipient();
        if (block.timestamp > _deadline) revert Expired();

        netValue = _swap(_outToken, _inToken, _value, _recipient);
        if (netValue < _minAmountOut) revert InsufficientOutput();
    }

    function _swap(address _outToken, address _inToken, uint256 _value, address _recipient)
        private
        returns (uint256 netValue)
    {
        if (_inToken == _outToken) revert InvalidToken();

        uint256 received = _deposit(_inToken, _value);

        uint256 quotedValue = getQuote(_outToken, _inToken, received);
        uint256 totalFee = getFee(_inToken, _outToken, quotedValue);

        // Check sufficient liquidity
        if (feesDecoupled) {
            uint256 bal = IERC20(_outToken).balanceOf(address(this));
            if ((bal > fees[_outToken] ? bal - fees[_outToken] : 0) < quotedValue) revert InsufficientBalance();
        } else {
            if (IERC20(_outToken).balanceOf(address(this)) < quotedValue) revert InsufficientBalance();
        }

        // Calculate protocol fee with floor at DEFAULT_FEE_PPM (1%) of quotedValue.
        // Pool operators cannot zero out or minimize their fee to avoid protocol fees.
        // Protocol fee is charged on top of the pool fee — both come from the user's output.
        // The pool owner always receives their full totalFee.
        // Floor at DEFAULT_FEE_PPM (1%) of quotedValue prevents gaming via tiny pool fees.
        uint256 protocolFee = _calcProtocolFee(quotedValue, totalFee);
        netValue = _netAfterFees(quotedValue, totalFee, protocolFee);

        if (protocolFee > 0) {
            if (!IERC20(_outToken).transfer(_getProtocolRecipient(), protocolFee)) revert TransferFailed();
        }
        if (!IERC20(_outToken).transfer(_recipient, netValue)) revert TransferFailed();

        if (totalFee > 0 && feeAddress != address(0)) {
            fees[_outToken] += totalFee;
        }

        emit Swap(msg.sender, _inToken, _outToken, received, netValue, totalFee);
    }

    function _getProtocolRecipient() internal view returns (address) {
        if (protocolFeeController == address(0)) return address(0);
        return IProtocolFeeController(protocolFeeController).getProtocolFeeRecipient();
    }

    function _netAfterFees(uint256 quotedValue, uint256 totalFee, uint256 protocolFee)
        internal
        pure
        returns (uint256 netValue)
    {
        if (totalFee + protocolFee > quotedValue) revert FeeTooHigh();
        netValue = quotedValue - totalFee - protocolFee;
        if (netValue == 0) revert InsufficientOutput();
    }

    function _calcProtocolFee(uint256 quotedValue, uint256 totalFee) internal view returns (uint256) {
        if (protocolFeeController == address(0)) return 0;
        IProtocolFeeController ctrl = IProtocolFeeController(protocolFeeController);
        uint256 protocolFeePpm = ctrl.getProtocolFee();
        address recipient = ctrl.getProtocolFeeRecipient();
        if (protocolFeePpm == 0 || recipient == address(0)) return 0;
        uint256 assumedFee = (quotedValue * DEFAULT_FEE_PPM) / PPM;
        uint256 effectiveFee = totalFee >= assumedFee ? totalFee : assumedFee;
        return (effectiveFee * protocolFeePpm) / PPM;
    }

    function withdraw(address _outToken) public onlyOwner returns (uint256) {
        uint256 balance = fees[_outToken];
        if (balance == 0) revert InsufficientFees();

        fees[_outToken] = 0;

        if (feeAddress == address(0)) revert InvalidFeeAddress();

        bool success = IERC20(_outToken).transfer(feeAddress, balance);
        if (!success) revert TransferFailed();

        emit Collect(feeAddress, _outToken, balance);
        return balance;
    }

    function withdraw(address _outToken, uint256 _value) public onlyOwner returns (uint256) {
        if (feeAddress == address(0)) revert InvalidFeeAddress();
        if (_value > fees[_outToken]) revert InsufficientFees();

        fees[_outToken] -= _value;

        bool success = IERC20(_outToken).transfer(feeAddress, _value);
        if (!success) revert TransferFailed();

        emit Collect(feeAddress, _outToken, _value);
        return _value;
    }

    // Owner can withdraw all liquidity.
    // Certain use-cases may require this functionality.
    // It is recommended that the owner be a timelock or multisig or both.
    function withdrawLiquidity(address token, address to, uint256 amount) external onlyOwner returns (uint256) {
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

        (bool r, bytes memory v) = _tokenRegistry.call(abi.encodeWithSignature("have(address)", _token));
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
