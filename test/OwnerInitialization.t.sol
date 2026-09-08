// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import {LibClone} from "solady/utils/LibClone.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {AccountsIndex} from "../src/AccountsIndex.sol";
import {CAT} from "../src/CAT.sol";
import {ContractRegistry} from "../src/ContractRegistry.sol";
import {EthFaucet} from "../src/EthFaucet.sol";
import {FeePolicy} from "../src/FeePolicy.sol";
import {GiftableToken} from "../src/GiftableToken.sol";
import {Limiter} from "../src/Limiter.sol";
import {OracleQuoter} from "../src/OracleQuoter.sol";
import {OracleRelay} from "../src/OracleRelay.sol";
import {PeriodSimple} from "../src/PeriodSimple.sol";
import {ProtocolFeeController} from "../src/ProtocolFeeController.sol";
import {RelativeQuoter} from "../src/RelativeQuoter.sol";
import {Splitter} from "../src/Splitter.sol";
import {SwapPool} from "../src/SwapPool.sol";
import {TokenUniqueSymbolIndex} from "../src/TokenUniqueSymbolIndex.sol";

contract OwnerInitializationTest is Test {
    bytes4 internal constant ZERO_OWNER = Ownable.NewOwnerIsZeroAddress.selector;

    function test_accountsIndex_rejectsZeroOwner() public {
        AccountsIndex instance = AccountsIndex(payable(LibClone.clone(address(new AccountsIndex()))));
        vm.expectRevert(ZERO_OWNER);
        instance.initialize(address(0));
    }

    function test_cat_rejectsZeroOwner() public {
        CAT instance = CAT(LibClone.clone(address(new CAT())));
        vm.expectRevert(ZERO_OWNER);
        instance.initialize(address(0));
    }

    function test_contractRegistry_rejectsZeroOwner() public {
        ContractRegistry instance = ContractRegistry(payable(LibClone.clone(address(new ContractRegistry()))));
        vm.expectRevert(ZERO_OWNER);
        instance.initialize(address(0), new bytes32[](0));
    }

    function test_ethFaucet_rejectsZeroOwner() public {
        EthFaucet instance = EthFaucet(payable(LibClone.clone(address(new EthFaucet()))));
        vm.expectRevert(ZERO_OWNER);
        instance.initialize(address(0), 1 ether);
    }

    function test_feePolicy_rejectsZeroOwner() public {
        FeePolicy instance = FeePolicy(LibClone.clone(address(new FeePolicy())));
        vm.expectRevert(ZERO_OWNER);
        instance.initialize(address(0), 0);
    }

    function test_giftableToken_rejectsZeroOwner() public {
        GiftableToken instance = GiftableToken(LibClone.clone(address(new GiftableToken())));
        vm.expectRevert(ZERO_OWNER);
        instance.initialize("Token", "TKN", 18, address(0), 0);
    }

    function test_limiter_rejectsZeroOwner() public {
        Limiter instance = Limiter(LibClone.clone(address(new Limiter())));
        vm.expectRevert(ZERO_OWNER);
        instance.initialize(address(0));
    }

    function test_oracleQuoter_rejectsZeroOwner() public {
        OracleQuoter instance = OracleQuoter(LibClone.clone(address(new OracleQuoter())));
        vm.expectRevert(ZERO_OWNER);
        instance.initialize(address(0), address(1));
    }

    function test_oracleRelay_rejectsZeroOwner() public {
        OracleRelay instance = OracleRelay(LibClone.clone(address(new OracleRelay())));
        vm.expectRevert(ZERO_OWNER);
        instance.initialize(address(0), address(1), 8, "KES / USD");
    }

    function test_periodSimple_rejectsZeroOwner() public {
        PeriodSimple instance = PeriodSimple(LibClone.clone(address(new PeriodSimple())));
        vm.expectRevert(ZERO_OWNER);
        instance.initialize(address(0), address(1));
    }

    function test_protocolFeeController_rejectsZeroOwner() public {
        ProtocolFeeController instance = ProtocolFeeController(LibClone.clone(address(new ProtocolFeeController())));
        vm.expectRevert(ZERO_OWNER);
        instance.initialize(address(0), 0, address(1));
    }

    function test_relativeQuoter_rejectsZeroOwner() public {
        RelativeQuoter instance = RelativeQuoter(LibClone.clone(address(new RelativeQuoter())));
        vm.expectRevert(ZERO_OWNER);
        instance.initialize(address(0));
    }

    function test_splitter_rejectsZeroOwner() public {
        Splitter instance = Splitter(payable(LibClone.clone(address(new Splitter()))));
        address[] memory accounts = new address[](2);
        accounts[0] = address(1);
        accounts[1] = address(2);
        uint32[] memory allocations = new uint32[](2);
        allocations[0] = 600_000;
        allocations[1] = 400_000;
        vm.expectRevert(ZERO_OWNER);
        instance.initialize(address(0), accounts, allocations);
    }

    function test_swapPool_rejectsZeroOwner() public {
        SwapPool instance = SwapPool(LibClone.clone(address(new SwapPool())));
        vm.expectRevert(ZERO_OWNER);
        instance.initialize(
            "Pool",
            "POOL",
            18,
            address(0),
            address(0),
            address(1),
            address(0),
            address(0),
            address(0),
            false,
            address(0)
        );
    }

    function test_tokenUniqueSymbolIndex_rejectsZeroOwner() public {
        TokenUniqueSymbolIndex instance =
            TokenUniqueSymbolIndex(payable(LibClone.clone(address(new TokenUniqueSymbolIndex()))));
        vm.expectRevert(ZERO_OWNER);
        instance.initialize(address(0), new address[](0), new bytes32[](0));
    }
}
