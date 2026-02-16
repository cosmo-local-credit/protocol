// Author:	Mohamed Sohail <sohail@grassecon.org> 43CA77F641ADA031C12665CB47461C31B006BC0E
// Author:	Louis Holbrook <dev@holbrook.no> 0826EDA1702D1E87C6E2875121D2E7BB88C2A746
// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import "solady/auth/Ownable.sol";
import "solady/utils/Initializable.sol";

contract PeriodSimple is Ownable, Initializable {
    error Access();

    address public poker;
    uint256 public period;
    uint256 public balanceThreshold;
    mapping(address => uint256) public lastUsed;

    event PeriodChange(uint256 _value);
    event BalanceThresholdChange(uint256 _value);

    constructor() {
        _disableInitializers();
    }

    function initialize(address owner_, address poker_) external initializer {
        _initializeOwner(owner_);
        poker = poker_;
    }

    function setPeriod(uint256 _period) public onlyOwner {
        period = _period;
        emit PeriodChange(_period);
    }

    function setPoker(address _poker) public onlyOwner {
        poker = _poker;
    }

    function setBalanceThreshold(uint256 _threshold) public onlyOwner {
        balanceThreshold = _threshold;
        emit BalanceThresholdChange(_threshold);
    }

    function next(address _subject) external view returns (uint256) {
        return lastUsed[_subject] + period;
    }

    function have(address _subject) external view returns (bool) {
        if (balanceThreshold > 0 && _subject.balance >= balanceThreshold) {
            return false;
        }
        if (lastUsed[_subject] == 0) {
            return true;
        }
        return block.timestamp > this.next(_subject);
    }

    function poke(address _subject) external returns (bool) {
        if (msg.sender != owner() && msg.sender != poker) revert Access();
        if (!this.have(_subject)) {
            return false;
        }
        lastUsed[_subject] = block.timestamp;
        return true;
    }

    function supportsInterface(bytes4 _sum) public pure returns (bool) {
        return _sum == 0x01ffc9a7 || _sum == 0x9493f8b2 || _sum == 0x3ef25013 || _sum == 0x242824a9;
    }
}
