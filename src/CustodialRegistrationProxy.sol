// Author:	Mohamed Sohail <sohail@grassecon.org> 43CA77F641ADA031C12665CB47461C31B006BC0E
// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import {IEthFaucet} from "./interfaces/IEthFaucet.sol";
import {IAccountsIndex} from "./interfaces/IAccountsIndex.sol";
import "solady/auth/Ownable.sol";
import "solady/utils/Initializable.sol";

contract CustodialRegistrationProxy is Ownable, Initializable {
    error Access();

    address public systemAccount;

    IEthFaucet public ethFaucet;
    IAccountsIndex public accountsIndex;

    event NewRegistration(address indexed subject);

    modifier systemAccountOnly() {
        if (msg.sender != owner() && msg.sender != systemAccount) revert Access();
        _;
    }

    constructor() {
        _disableInitializers();
    }

    function initialize(address owner_, address ethFaucet_, address accountsIndex_, address systemAccount_) external initializer {
        _initializeOwner(owner_);
        ethFaucet = IEthFaucet(ethFaucet_);
        accountsIndex = IAccountsIndex(accountsIndex_);
        systemAccount = systemAccount_;
    }

    function setSystemAccount(address _account) external onlyOwner {
        systemAccount = _account;
    }

    function register(address _subject) external systemAccountOnly {
        accountsIndex.add(_subject);
        ethFaucet.giveTo(_subject);
        emit NewRegistration(_subject);
    }
}
