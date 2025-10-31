// Author:	Mohamed Sohail <sohail@grassecon.org> 43CA77F641ADA031C12665CB47461C31B006BC0E
// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import {IProtocolFeeController} from "./interfaces/IProtocolFeeController.sol";
import "solady/auth/Ownable.sol";
import "solady/utils/Initializable.sol";

contract ProtocolFeeController is IProtocolFeeController, Ownable, Initializable {
    uint256 private constant PPM = 1_000_000;

    uint256 private protocolFee;
    address private protocolFeeRecipient;
    bool private active;

    event ProtocolFeeUpdated(uint256 oldFee, uint256 newFee);

    event ProtocolFeeRecipientUpdated(address indexed oldRecipient, address indexed newRecipient);

    event ActiveStateUpdated(bool active);

    error InvalidFee();
    error InvalidRecipient();

    constructor() {
        _disableInitializers();
    }

    function initialize(address owner_, uint256 initialFee_, address initialRecipient_) external initializer {
        _initializeOwner(owner_);

        if (initialFee_ > PPM) revert InvalidFee();
        if (initialRecipient_ == address(0)) revert InvalidRecipient();

        protocolFee = initialFee_;
        protocolFeeRecipient = initialRecipient_;
        active = true;

        emit ProtocolFeeUpdated(0, initialFee_);
        emit ProtocolFeeRecipientUpdated(address(0), initialRecipient_);
        emit ActiveStateUpdated(true);
    }

    function getProtocolFee() external view override returns (uint256) {
        return protocolFee;
    }

    function getProtocolFeeRecipient() external view override returns (address) {
        return protocolFeeRecipient;
    }

    function isActive() external view override returns (bool) {
        return active;
    }

    function setProtocolFee(uint256 newFee_) external onlyOwner {
        if (newFee_ > PPM) revert InvalidFee();

        uint256 oldFee = protocolFee;
        protocolFee = newFee_;

        emit ProtocolFeeUpdated(oldFee, newFee_);
    }

    function setProtocolFeeRecipient(address newRecipient_) external onlyOwner {
        if (newRecipient_ == address(0)) revert InvalidRecipient();

        address oldRecipient = protocolFeeRecipient;
        protocolFeeRecipient = newRecipient_;

        emit ProtocolFeeRecipientUpdated(oldRecipient, newRecipient_);
    }

    function setActive(bool active_) external onlyOwner {
        active = active_;
        emit ActiveStateUpdated(active_);
    }
}
