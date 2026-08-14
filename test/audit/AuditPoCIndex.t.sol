// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

// Audit PoC suite for the enumerable registries:
//   src/AccountsIndex.sol
//   src/ContractRegistry.sol
//   src/TokenUniqueSymbolIndex.sol
//
// CONVENTION
//   * A PASSING test whose name describes a defect means the defect is PRESENT
//     (the assertions encode the broken behaviour).
//   * Tests named `*_holds` / `*_isCorrect` encode a property that DOES hold.

import "forge-std/Test.sol";
import {LibClone} from "solady/utils/LibClone.sol";
import "../../src/AccountsIndex.sol";
import "../../src/ContractRegistry.sol";
import "../../src/TokenUniqueSymbolIndex.sol";

/* ------------------------------------------------------------------ mocks */

// Normal ERC20-ish token: `symbol()` returns `string`.
contract IxStringSymbolToken {
    string public name;
    string public symbol;

    constructor(string memory name_, string memory symbol_) {
        name = name_;
        symbol = symbol_;
    }
}

// Token whose symbol can change over time (upgradeable token, rebrand, ...).
contract IxMutableSymbolToken {
    string private _symbol;

    constructor(string memory s) {
        _symbol = s;
    }

    function setSymbol(string memory s) external {
        _symbol = s;
    }

    function symbol() external view returns (string memory) {
        return _symbol;
    }
}

// Token whose `symbol()` returns the empty string.
contract IxEmptySymbolToken {
    function symbol() external pure returns (string memory) {
        return "";
    }
}

// MKR-style token: `symbol()` returns bytes32, not string.
contract IxBytes32SymbolToken {
    function symbol() external pure returns (bytes32) {
        return bytes32("DAI");
    }
}

// Not a token at all: a catch-all fallback that answers any selector with
// a well-formed dynamic-bytes return value. NB the `fallback(bytes) returns
// (bytes)` form returns its output verbatim, so the ABI framing is explicit.
contract IxFallbackOnly {
    fallback(bytes calldata) external returns (bytes memory) {
        return abi.encode(bytes("FAKE"));
    }
}

/* ------------------------------------------------------------------ tests */

contract AuditPoCIndexTest is Test {
    error Access();
    error AlreadyExists();
    error NotFound();
    error NotBlocked();
    error NotActive();
    error IndexFull();
    error Unauthorized();
    error TokenSymbolTooLong();
    error SymbolAlreadyExists();
    error IdentifierAlreadyExists();
    error IdentifierNotFound();
    error ZeroAddress();
    error InvalidInitialization();

    uint256 constant BLOCKED_FIELD = 1 << 128;
    // AccountsIndex storage layout: slot0 = entryList, slot1 = entryIndex, slot2 = writers.
    uint256 constant AI_ENTRYINDEX_SLOT = 1;

    AccountsIndex aiImpl;
    AccountsIndex ai;

    ContractRegistry crImpl;
    ContractRegistry cr;

    TokenUniqueSymbolIndex tiImpl;
    TokenUniqueSymbolIndex ti;

    IxStringSymbolToken tokenA;
    IxStringSymbolToken tokenB;
    IxStringSymbolToken tokenC;

    address owner = makeAddr("ix_owner");
    address writer = makeAddr("ix_writer");
    address acc1 = makeAddr("ix_acc1");
    address acc2 = makeAddr("ix_acc2");
    address acc3 = makeAddr("ix_acc3");
    address attacker = makeAddr("ix_attacker");

    bytes32 constant KEY_A = keccak256("A");
    bytes32 constant KEY_B = keccak256("B");

    function setUp() public {
        aiImpl = new AccountsIndex();
        ai = AccountsIndex(payable(LibClone.clone(address(aiImpl))));
        ai.initialize(owner);
        vm.prank(owner);
        ai.addWriter(writer);

        crImpl = new ContractRegistry();
        cr = ContractRegistry(payable(LibClone.clone(address(crImpl))));
        bytes32[] memory ids = new bytes32[](2);
        ids[0] = KEY_A;
        ids[1] = KEY_B;
        cr.initialize(owner, ids);

        tiImpl = new TokenUniqueSymbolIndex();
        ti = TokenUniqueSymbolIndex(payable(LibClone.clone(address(tiImpl))));
        ti.initialize(owner, new address[](0), new bytes32[](0));
        vm.prank(owner);
        ti.addWriter(writer);

        tokenA = new IxStringSymbolToken("Token A", "TKA");
        tokenB = new IxStringSymbolToken("Token B", "TKB");
        tokenC = new IxStringSymbolToken("Token C", "TKC");
    }

    function _rawEntryIndex(address account) internal view returns (uint256) {
        return uint256(vm.load(address(ai), keccak256(abi.encode(account, AI_ENTRYINDEX_SLOT))));
    }

    // TokenUniqueSymbolIndex layout: slot0 isWriter, slot1 registry,
    // slot2 tokenIndex, slot3 tokens[], slot4 identifierList[].
    function _tiSentinel(TokenUniqueSymbolIndex t) internal view returns (address) {
        return address(uint160(uint256(vm.load(address(t), keccak256(abi.encode(uint256(3)))))));
    }

    /* ============================================================ *
     *  PART 1 - stale scv-scan.md claims (2026-03-04) re-verified   *
     * ============================================================ */

    // STALE CLAIM 1 -- NOT PRESENT ANYMORE.
    // scv-scan.md Finding 2 asserted deactivate()/activate() use `<<= 129` / `>>= 129`
    // and that a deactivate->activate cycle zeroes the slot so have() becomes false and
    // the account becomes re-registerable. Current code uses `|= BLOCKED_FIELD` /
    // `&= ~BLOCKED_FIELD`; the index bits, the timestamp bits and presence all survive.
    function test_AI_staleClaim1_deactivateActivateCycle_preservesEntry_isCorrect() public {
        vm.warp(1_700_000_000);
        vm.startPrank(writer);
        ai.add(acc1);
        ai.add(acc2);
        vm.stopPrank();

        uint256 packedBefore = _rawEntryIndex(acc1);
        assertEq(packedBefore & type(uint64).max, 1, "index bits");
        assertEq(packedBefore >> 64, 1_700_000_000, "timestamp bits");
        assertEq(packedBefore & BLOCKED_FIELD, 0, "not blocked");

        vm.startPrank(writer);
        ai.deactivate(acc1);
        ai.activate(acc1);
        vm.stopPrank();

        // The exact packed word is restored bit-for-bit.
        assertEq(_rawEntryIndex(acc1), packedBefore, "packed word restored");
        assertTrue(ai.have(acc1), "still present");
        assertTrue(ai.isActive(acc1), "active again");
        assertEq(ai.entry(0), acc1, "still enumerable at same slot");
        assertEq(ai.entryCount(), 2);
        assertEq(ai.time(acc1), 1_700_000_000, "timestamp intact");

        // Not re-registerable, i.e. no slot duplication.
        vm.prank(writer);
        vm.expectRevert(AlreadyExists.selector);
        ai.add(acc1);
    }

    // STALE CLAIM 2 -- NOT PRESENT ANYMORE.
    // scv-scan.md Finding 5 asserted remove() reads the packed word as an array
    // position so `if (i < l)` never fires and pop() always evicts the last element.
    // Current code masks with `uint64(...)` and also rewrites the relocated entry's
    // index bits, so swap-and-pop is correct.
    function test_AI_staleClaim2_removeSwapAndPop_isCorrect() public {
        vm.warp(1_700_000_000);
        vm.startPrank(writer);
        ai.add(acc1); // slot 1
        ai.add(acc2); // slot 2
        ai.add(acc3); // slot 3
        vm.stopPrank();

        uint256 acc3PackedBefore = _rawEntryIndex(acc3);

        // Remove the middle element: acc3 must be relocated into acc2's slot.
        vm.prank(writer);
        ai.remove(acc2);

        assertEq(ai.entryCount(), 2);
        assertEq(ai.entry(0), acc1);
        assertEq(ai.entry(1), acc3, "last element relocated into the hole");
        assertFalse(ai.have(acc2));
        assertTrue(ai.have(acc3));

        // The relocated element's index mapping was updated ...
        assertEq(_rawEntryIndex(acc3) & type(uint64).max, 2, "relocated index bits updated");
        // ... and only its index bits changed (timestamp + blocked flag preserved).
        assertEq(_rawEntryIndex(acc3) >> 64, acc3PackedBefore >> 64, "upper bits preserved");
        assertEq(ai.time(acc3), 1_700_000_000);

        // No stale duplicate is left behind: acc2 is gone from every view.
        for (uint256 i = 0; i < ai.entryCount(); i++) {
            assertTrue(ai.entry(i) != acc2, "no stale entry in entryList");
        }
    }

    // Removal must also carry the blocked flag of the relocated element.
    function test_AI_remove_relocatedEntryKeepsBlockedFlag_isCorrect() public {
        vm.startPrank(writer);
        ai.add(acc1);
        ai.add(acc2);
        ai.deactivate(acc2);
        ai.remove(acc1);
        vm.stopPrank();

        assertEq(ai.entry(0), acc2);
        assertTrue(ai.have(acc2));
        assertFalse(ai.isActive(acc2), "blocked flag survived relocation");
        assertEq(_rawEntryIndex(acc2) & type(uint64).max, 1);
    }

    /* ============================================================ *
     *  PART 2 - AccountsIndex bit-packing                           *
     * ============================================================ */

    // FINDING: time() does not mask the packed word before shifting, so the
    // BLOCKED_FIELD bit (bit 128) lands on bit 64 of the returned timestamp.
    // A deactivated account reports a timestamp of `ts + 2**64`.
    function test_AI_time_leaksBlockedFlagIntoTimestamp() public {
        vm.warp(1_700_000_000);
        vm.prank(writer);
        ai.add(acc1);
        assertEq(ai.time(acc1), 1_700_000_000);

        vm.prank(writer);
        ai.deactivate(acc1);

        // time() is now garbage: real timestamp + 2**64.
        assertEq(ai.time(acc1), 1_700_000_000 + (uint256(1) << 64), "blocked bit leaks into time()");
        assertTrue(ai.time(acc1) > block.timestamp, "reported timestamp is in the future");

        // and it silently repairs itself on reactivation, so the corruption is
        // state-dependent rather than permanent.
        vm.prank(writer);
        ai.activate(acc1);
        assertEq(ai.time(acc1), 1_700_000_000);
    }

    // The timestamp field is written as `block.timestamp << 64` with no width
    // clamp, so bits 64..255 belong to the timestamp while BLOCKED_FIELD claims
    // bit 128. The two overlap: at timestamp == 2**64 the "blocked" bit is set by
    // add() itself. (Layout defect; the trigger value is not reachable on a real
    // chain, but it shows reads and writes disagree on the field widths.)
    function test_AI_packedLayout_timestampFieldOverlapsBlockedFieldBit() public {
        vm.warp(uint256(1) << 64);
        vm.prank(writer);
        ai.add(acc1);

        assertEq(_rawEntryIndex(acc1) & BLOCKED_FIELD, BLOCKED_FIELD, "add() set the blocked bit");
        assertTrue(ai.have(acc1));
        assertFalse(ai.isActive(acc1), "entry is born deactivated");

        // and deactivate() refuses to run because the entry already looks blocked.
        vm.prank(writer);
        vm.expectRevert(NotActive.selector);
        ai.deactivate(acc1);

        // activate() "works", and destroys a timestamp bit doing so.
        vm.prank(writer);
        ai.activate(acc1);
        assertTrue(ai.isActive(acc1));
        assertEq(ai.time(acc1), 0, "timestamp bit cleared by activate()");
    }

    /* ============================================================ *
     *  PART 3 - AccountsIndex misc                                  *
     * ============================================================ */

    // FINDING: remove() of an absent account reverts AlreadyExists() instead of
    // NotFound(). Integrators branching on the error see the opposite meaning.
    function test_AI_remove_absentAccount_revertsAlreadyExistsInsteadOfNotFound() public {
        vm.prank(writer);
        vm.expectRevert(AlreadyExists.selector);
        ai.remove(acc1);
    }

    // FINDING: address(0) can be added. entryList[0] is a reserved sentinel, so
    // after add(address(0)) the same value appears twice in the list, and
    // `have(address(0))`/`isActive(address(0))` return true - i.e. the null
    // address is whitelisted for every downstream consumer.
    function test_AI_add_zeroAddress_isWhitelistedAndAliasesTheSentinel() public {
        assertFalse(ai.have(address(0)));

        vm.prank(writer);
        ai.add(address(0));

        assertTrue(ai.have(address(0)), "null address whitelisted");
        assertTrue(ai.isActive(address(0)));
        assertEq(ai.entryCount(), 1);
        assertEq(ai.entry(0), address(0), "enumeration yields the null address");
    }

    // FINDING (semantics): the SwapPool / EthFaucet security boundary calls
    // `have(address)`, never `isActive(address)`. Deactivating an account
    // therefore does not revoke it from the whitelist.
    function test_AI_deactivate_doesNotRevokeTheHaveWhitelist() public {
        vm.startPrank(writer);
        ai.add(acc1);
        ai.deactivate(acc1);
        vm.stopPrank();

        assertFalse(ai.isActive(acc1), "marked inactive");
        assertTrue(ai.have(acc1), "but still passes the have() whitelist");

        // exactly the call SwapPool.mustAllowedToken / EthFaucet._checkRegistry make
        (bool ok, bytes memory v) = address(ai).call(abi.encodeWithSignature("have(address)", acc1));
        assertTrue(ok);
        assertTrue(abi.decode(v, (bool)), "consumer sees a blocked account as allowed");
    }

    function test_AI_removeThenReAdd_isCorrect() public {
        vm.warp(1000);
        vm.startPrank(writer);
        ai.add(acc1);
        ai.add(acc2);
        ai.remove(acc1);
        vm.stopPrank();
        assertFalse(ai.have(acc1));

        vm.warp(2000);
        vm.prank(writer);
        ai.add(acc1);

        assertTrue(ai.have(acc1));
        assertEq(ai.entryCount(), 2);
        assertEq(ai.time(acc1), 2000, "timestamp refreshed");
        // both entries enumerate to distinct addresses
        assertTrue(ai.entry(0) != ai.entry(1));
    }

    function test_AI_removeTwice_reverts_isCorrect() public {
        vm.startPrank(writer);
        ai.add(acc1);
        ai.remove(acc1);
        vm.expectRevert(AlreadyExists.selector);
        ai.remove(acc1);
        vm.stopPrank();
        assertEq(ai.entryCount(), 0);
    }

    function test_AI_entryOutOfBounds_reverts_isCorrect() public {
        vm.prank(writer);
        ai.add(acc1);
        assertEq(ai.entryCount(), 1);
        vm.expectRevert();
        ai.entry(1);
        vm.expectRevert();
        ai.entry(type(uint256).max);
    }

    function test_AI_accessControl_isCorrect() public {
        vm.startPrank(attacker);
        vm.expectRevert(Access.selector);
        ai.add(acc1);
        vm.expectRevert(Access.selector);
        ai.remove(acc1);
        vm.expectRevert(Access.selector);
        ai.activate(acc1);
        vm.expectRevert(Access.selector);
        ai.deactivate(acc1);
        vm.expectRevert(Unauthorized.selector);
        ai.addWriter(attacker);
        vm.expectRevert(Unauthorized.selector);
        ai.deleteWriter(writer);
        vm.stopPrank();
    }

    function test_AI_isWriterIncludesOwner_matchesSpec_isCorrect() public view {
        assertTrue(ai.isWriter(owner));
        assertTrue(ai.isWriter(writer));
        assertFalse(ai.isWriter(attacker));
    }

    function test_AI_initializerSafety_isCorrect() public {
        // implementation cannot be initialized
        vm.expectRevert(InvalidInitialization.selector);
        aiImpl.initialize(attacker);
        // proxy cannot be re-initialized
        vm.expectRevert(InvalidInitialization.selector);
        ai.initialize(attacker);
    }

    // FINDING (info): initialize() accepts a zero owner. The contract then has no
    // administrator forever, and isWriter(address(0)) starts answering true.
    function test_AI_initializeZeroOwner_leavesUnownedAndLiesAboutIsWriter() public {
        AccountsIndex orphan = AccountsIndex(payable(LibClone.clone(address(aiImpl))));
        orphan.initialize(address(0));

        assertEq(orphan.owner(), address(0));
        assertTrue(orphan.isWriter(address(0)), "address(0) reported as a writer");

        // no one can ever appoint a writer again
        vm.prank(attacker);
        vm.expectRevert(Unauthorized.selector);
        orphan.addWriter(attacker);
    }

    /* ============================================================ *
     *  PART 4 - TokenUniqueSymbolIndex                              *
     * ============================================================ */

    // FINDING: a token whose `symbol()` returns "" gets symbolKey == bytes32(0),
    // which is also the "absent" marker for `tokenIndex`. _register() pushes the
    // token into `tokens` / `identifierList` and bumps entryCount(), but stores
    // tokenIndex[token] = 0. Result: an entry that is enumerable and counted,
    // is NOT covered by have(), and can never be removed.
    function test_TI_emptySymbolToken_createsUnremovableGhostEntry() public {
        IxEmptySymbolToken ghost = new IxEmptySymbolToken();

        vm.prank(writer);
        ti.add(address(ghost));

        // present in enumeration
        assertEq(ti.entryCount(), 1);
        assertEq(ti.entry(0), address(ghost));
        assertEq(ti.identifierCount(), 1);
        assertEq(ti.identifier(0), bytes32(0));
        // and reachable through the symbol lookup
        assertEq(ti.addressOf(bytes32(0)), address(ghost));

        // but invisible to the whitelist
        assertFalse(ti.have(address(ghost)), "have() denies an indexed token");
        assertEq(ti.tokenIndex(address(ghost)), bytes32(0));

        // and unremovable: remove() gates on tokenIndex != 0
        vm.prank(writer);
        vm.expectRevert(NotFound.selector);
        ti.remove(address(ghost));
        vm.prank(owner);
        vm.expectRevert(NotFound.selector);
        ti.remove(address(ghost));

        // entryCount() is permanently inflated relative to have()
        vm.prank(writer);
        ti.add(address(tokenA));
        assertEq(ti.entryCount(), 2);
        assertTrue(ti.have(address(tokenA)));
        assertFalse(ti.have(ti.entry(0)));

        // the bytes32(0) symbol slot is now squatted forever
        IxEmptySymbolToken ghost2 = new IxEmptySymbolToken();
        vm.prank(writer);
        vm.expectRevert(SymbolAlreadyExists.selector);
        ti.add(address(ghost2));
    }

    // FINDING: _register() only rejects duplicate SYMBOLS, never a duplicate
    // TOKEN. A token whose symbol changes can be registered twice, occupying two
    // slots, while tokenIndex[] can only remember one symbol. remove() then
    // deregisters one slot and clears tokenIndex, so have() says "no" while the
    // token is still enumerable and still resolvable via addressOf(). The
    // orphaned symbol key can never be freed, permanently locking the token out
    // of the index under its real symbol.
    function test_TI_symbolChangingToken_doubleRegisters_thenCorruptsHaveVersusEnumeration() public {
        IxMutableSymbolToken t = new IxMutableSymbolToken("AAA");

        vm.prank(writer);
        ti.register(address(t)); // slot 1, symbol "AAA"
        t.setSymbol("BBB");
        vm.prank(writer);
        ti.register(address(t)); // slot 2, symbol "BBB" -- same address, no duplicate check

        assertEq(ti.entryCount(), 2, "one token occupies two slots");
        assertEq(ti.entry(0), address(t));
        assertEq(ti.entry(1), address(t));
        assertEq(ti.tokenIndex(address(t)), bytes32(bytes("BBB")), "only the last symbol is remembered");

        vm.prank(writer);
        ti.remove(address(t));

        // whitelist and enumeration now disagree
        assertFalse(ti.have(address(t)), "have() says the token is not registered");
        assertEq(ti.entryCount(), 1);
        assertEq(ti.entry(0), address(t), "but it is still enumerable");
        assertEq(ti.addressOf(bytes32(bytes("AAA"))), address(t), "and still resolvable by symbol");
        assertEq(ti.identifier(0), bytes32(bytes("AAA")));

        // permanent lockout: the orphaned "AAA" key cannot be reused, so the
        // token can never be re-registered under its original symbol.
        t.setSymbol("AAA");
        vm.prank(writer);
        vm.expectRevert(SymbolAlreadyExists.selector);
        ti.register(address(t));
        assertFalse(ti.have(address(t)));

        // the tokens[0] sentinel is NOT damaged, so addressOf() of an unknown
        // key still resolves to address(0) (see discarded candidate: remove()'s
        // unconditional `registry[identifierList[i]] = i` with i == 0).
        assertEq(_tiSentinel(ti), address(0), "sentinel intact");
        assertEq(ti.addressOf(keccak256("never-registered")), address(0));
    }

    // Randomised hunt for the `i == 0` branch of remove(), which would write
    // tokens[0] (the sentinel) and make addressOf() resolve arbitrary unknown
    // keys to a live token. Mixes duplicate registrations, empty symbols and
    // removals; the sentinel survives every reachable sequence.
    function test_TI_fuzz_sentinelSlotIsNeverOverwritten_holds(uint256 seed) public {
        IxMutableSymbolToken[] memory ts = new IxMutableSymbolToken[](4);
        for (uint256 i = 0; i < 4; i++) {
            ts[i] = new IxMutableSymbolToken(string(abi.encodePacked("S", vm.toString(i))));
        }
        address ghost = address(new IxEmptySymbolToken());

        vm.startPrank(writer);
        for (uint256 step = 0; step < 24; step++) {
            seed = uint256(keccak256(abi.encode(seed, step)));
            uint256 op = seed % 4;
            uint256 which = (seed >> 8) % 4;
            if (op == 0) {
                try ti.register(address(ts[which])) {} catch {}
            } else if (op == 1) {
                ts[which].setSymbol(string(abi.encodePacked("X", vm.toString((seed >> 16) % 6))));
            } else if (op == 2) {
                try ti.remove(address(ts[which])) {} catch {}
            } else {
                try ti.add(ghost) {} catch {}
            }
            assertEq(_tiSentinel(ti), address(0), "tokens[0] sentinel overwritten");
            assertEq(ti.addressOf(keccak256(abi.encode("unknown", step))), address(0));
        }
        vm.stopPrank();
    }

    // Same root cause reached without a malicious token: initialize() accepts a
    // duplicated token address with two different symbol keys.
    function test_TI_initializeWithDuplicateToken_corruptsHaveAfterRemove() public {
        TokenUniqueSymbolIndex dup = TokenUniqueSymbolIndex(payable(LibClone.clone(address(tiImpl))));
        address[] memory toks = new address[](2);
        bytes32[] memory syms = new bytes32[](2);
        toks[0] = address(tokenA);
        toks[1] = address(tokenA);
        syms[0] = bytes32(bytes("TKA"));
        syms[1] = bytes32(bytes("TKA2"));
        dup.initialize(owner, toks, syms);

        assertEq(dup.entryCount(), 2);

        vm.prank(owner);
        dup.remove(address(tokenA));

        assertFalse(dup.have(address(tokenA)));
        assertEq(dup.entryCount(), 1);
        assertEq(dup.entry(0), address(tokenA), "ghost slot left behind");
    }

    // FINDING (compatibility): `abi.decode(r, (bytes))` assumes a dynamically
    // sized return value. A bytes32-returning symbol() (MKR-style) is 32 bytes of
    // static data, so the decode reads the symbol itself as an ABI head offset
    // and reverts. Such tokens can never be registered by register()/add().
    function test_TI_bytes32SymbolToken_cannotBeRegistered() public {
        IxBytes32SymbolToken mkrLike = new IxBytes32SymbolToken();
        vm.prank(writer);
        vm.expectRevert();
        ti.register(address(mkrLike));
        assertFalse(ti.have(address(mkrLike)));
        assertEq(ti.entryCount(), 0);
    }

    // FINDING (info): register()/add() do no ERC20 sanity check at all. Any
    // address with a permissive fallback is accepted as a "token" with whatever
    // symbol it feels like reporting.
    function test_TI_nonTokenWithCatchAllFallback_isAcceptedAsAToken() public {
        IxFallbackOnly notAToken = new IxFallbackOnly();
        vm.prank(writer);
        ti.add(address(notAToken));

        assertTrue(ti.have(address(notAToken)));
        assertEq(ti.tokenIndex(address(notAToken)), bytes32(bytes("FAKE")));
        assertEq(ti.addressOf(bytes32(bytes("FAKE"))), address(notAToken));
    }

    // An EOA is rejected (empty returndata fails the decode). Property holds.
    function test_TI_eoaCannotBeRegistered_isCorrect() public {
        vm.prank(writer);
        vm.expectRevert();
        ti.add(attacker);
    }

    // `abi.decode(r, (bytes))` on a string-returning symbol() is CORRECT: the ABI
    // encodings of `string` and `bytes` are identical.
    function test_TI_stringSymbolDecodesCorrectly_isCorrect() public {
        vm.prank(writer);
        ti.add(address(tokenA));
        assertEq(ti.tokenIndex(address(tokenA)), bytes32(bytes("TKA")));
        assertEq(ti.addressOf(bytes32(bytes("TKA"))), address(tokenA));
        assertTrue(ti.have(address(tokenA)));
    }

    // A full 32-byte symbol survives `bytes32(...)` without truncation; 33 bytes
    // is rejected rather than silently truncated. Property holds.
    function test_TI_symbolBoundary32Bytes_noSilentTruncation_isCorrect() public {
        string memory s32 = "ABCDEFGHIJKLMNOPQRSTUVWXYZ123456"; // 32 chars
        string memory s33 = "ABCDEFGHIJKLMNOPQRSTUVWXYZ1234567"; // 33 chars
        assertEq(bytes(s32).length, 32);
        assertEq(bytes(s33).length, 33);

        IxStringSymbolToken long = new IxStringSymbolToken("Long", s32);
        vm.prank(writer);
        ti.add(address(long));
        assertEq(ti.tokenIndex(address(long)), bytes32(bytes(s32)));

        IxStringSymbolToken tooLong = new IxStringSymbolToken("TooLong", s33);
        vm.prank(writer);
        vm.expectRevert(TokenSymbolTooLong.selector);
        ti.add(address(tooLong));
    }

    // Swap-and-pop keeps `tokens`, `identifierList` and `registry` in lockstep for
    // well-formed (single-symbol) registrations. Property holds.
    function test_TI_removeSwapAndPop_updatesRelocatedMappings_isCorrect() public {
        vm.startPrank(writer);
        ti.add(address(tokenA)); // slot 1
        ti.add(address(tokenB)); // slot 2
        ti.add(address(tokenC)); // slot 3
        vm.stopPrank();

        vm.prank(writer);
        ti.remove(address(tokenB)); // middle element

        assertEq(ti.entryCount(), 2);
        assertEq(ti.identifierCount(), 2);
        assertEq(ti.entry(0), address(tokenA));
        assertEq(ti.entry(1), address(tokenC), "last element relocated into the hole");
        assertEq(ti.identifier(1), bytes32(bytes("TKC")), "identifierList relocated in lockstep");
        assertEq(ti.addressOf(bytes32(bytes("TKC"))), address(tokenC), "registry updated for relocated entry");
        assertEq(ti.addressOf(bytes32(bytes("TKB"))), address(0), "removed key cleared");
        assertFalse(ti.have(address(tokenB)));
        assertTrue(ti.have(address(tokenA)));
        assertTrue(ti.have(address(tokenC)));

        // now remove the last element
        vm.prank(writer);
        ti.remove(address(tokenC));
        assertEq(ti.entryCount(), 1);
        assertEq(ti.entry(0), address(tokenA));
        assertEq(ti.addressOf(bytes32(bytes("TKC"))), address(0));
        assertEq(ti.addressOf(bytes32(bytes("TKA"))), address(tokenA));

        // and the first
        vm.prank(writer);
        ti.remove(address(tokenA));
        assertEq(ti.entryCount(), 0);
        assertEq(ti.identifierCount(), 0);
        assertEq(ti.addressOf(bytes32(bytes("TKA"))), address(0));
    }

    function test_TI_removeThenReAdd_isCorrect() public {
        vm.startPrank(writer);
        ti.add(address(tokenA));
        ti.add(address(tokenB));
        ti.remove(address(tokenA));
        ti.add(address(tokenA));
        vm.stopPrank();

        assertEq(ti.entryCount(), 2);
        assertTrue(ti.have(address(tokenA)));
        assertTrue(ti.have(address(tokenB)));
        assertTrue(ti.entry(0) != ti.entry(1));
        assertEq(ti.addressOf(bytes32(bytes("TKA"))), address(tokenA));
        assertEq(ti.addressOf(bytes32(bytes("TKB"))), address(tokenB));
    }

    function test_TI_removeTwice_reverts_isCorrect() public {
        vm.startPrank(writer);
        ti.add(address(tokenA));
        ti.remove(address(tokenA));
        vm.expectRevert(NotFound.selector);
        ti.remove(address(tokenA));
        vm.stopPrank();
        assertEq(ti.entryCount(), 0);
    }

    function test_TI_addressOfUnknownKey_returnsZeroViaSentinel_isCorrect() public view {
        assertEq(ti.addressOf(keccak256("nope")), address(0));
    }

    function test_TI_entryAndIdentifierOutOfBounds_revert_isCorrect() public {
        vm.prank(writer);
        ti.add(address(tokenA));
        vm.expectRevert();
        ti.entry(1);
        vm.expectRevert();
        ti.identifier(1);
        vm.expectRevert();
        ti.entry(type(uint256).max);
    }

    // FINDING (info): the raw `identifierList` array is public alongside the
    // 0-based `identifier(idx)` accessor, and the two are off by one because
    // identifierList[0] is the bytes32(0) sentinel. `tokens` is private, so the
    // asymmetry is easy to trip over.
    function test_TI_publicIdentifierListGetter_isOffByOneAgainstIdentifier() public {
        vm.prank(writer);
        ti.add(address(tokenA));

        assertEq(ti.identifier(0), bytes32(bytes("TKA")));
        assertEq(ti.identifierList(0), bytes32(0), "raw getter exposes the sentinel");
        assertEq(ti.identifierList(1), bytes32(bytes("TKA")));
    }

    // FINDING (low): SPEC says initialize()'s two arrays "must be the same
    // length", but nothing enforces it. Extra symbols are silently dropped.
    function test_TI_initializeArrayLengthMismatch_isUnchecked() public {
        TokenUniqueSymbolIndex a = TokenUniqueSymbolIndex(payable(LibClone.clone(address(tiImpl))));
        address[] memory toks = new address[](1);
        bytes32[] memory syms = new bytes32[](3);
        toks[0] = address(tokenA);
        syms[0] = bytes32(bytes("TKA"));
        syms[1] = bytes32(bytes("TKB"));
        syms[2] = bytes32(bytes("TKC"));
        a.initialize(owner, toks, syms); // succeeds, TKB/TKC silently dropped
        assertEq(a.entryCount(), 1);
        assertEq(a.identifierCount(), 1);

        // the reverse mismatch reverts with a bare array-bounds panic (0x32)
        TokenUniqueSymbolIndex b = TokenUniqueSymbolIndex(payable(LibClone.clone(address(tiImpl))));
        address[] memory toks2 = new address[](2);
        bytes32[] memory syms2 = new bytes32[](1);
        toks2[0] = address(tokenA);
        toks2[1] = address(tokenB);
        syms2[0] = bytes32(bytes("TKA"));
        vm.expectRevert(stdError.indexOOBError);
        b.initialize(owner, toks2, syms2);
    }

    function test_TI_accessControl_isCorrect() public {
        vm.startPrank(attacker);
        vm.expectRevert(Access.selector);
        ti.register(address(tokenA));
        vm.expectRevert(Access.selector);
        ti.add(address(tokenA));
        vm.expectRevert(Access.selector);
        ti.remove(address(tokenA));
        vm.expectRevert(Unauthorized.selector);
        ti.addWriter(attacker);
        vm.expectRevert(Unauthorized.selector);
        ti.deleteWriter(writer);
        vm.stopPrank();
    }

    // SPEC: TokenUniqueSymbolIndex.isWriter is a plain mapping and does NOT
    // treat the owner as a writer (unlike AccountsIndex). Matches the spec.
    function test_TI_isWriterExcludesOwner_matchesSpec_isCorrect() public view {
        assertFalse(ti.isWriter(owner));
        assertTrue(ti.isWriter(writer));
    }

    function test_TI_initializerSafety_isCorrect() public {
        vm.expectRevert(InvalidInitialization.selector);
        tiImpl.initialize(attacker, new address[](0), new bytes32[](0));
        vm.expectRevert(InvalidInitialization.selector);
        ti.initialize(attacker, new address[](0), new bytes32[](0));
    }

    // Stubs behave as SPEC documents them (inert, no state change).
    function test_TI_inertStubs_matchSpec_isCorrect() public {
        vm.prank(writer);
        ti.add(address(tokenA));
        assertEq(ti.time(address(tokenA)), 0);
        vm.prank(attacker);
        assertFalse(ti.activate(address(tokenA)));
        vm.prank(attacker);
        assertFalse(ti.deactivate(address(tokenA)));
        assertTrue(ti.have(address(tokenA)));
    }

    /* ============================================================ *
     *  PART 5 - ContractRegistry                                    *
     * ============================================================ */

    function test_CR_writeOnce_isCorrect() public {
        vm.prank(owner);
        cr.set(KEY_A, acc1);
        assertEq(cr.addressOf(KEY_A), acc1);

        vm.prank(owner);
        vm.expectRevert(IdentifierAlreadyExists.selector);
        cr.set(KEY_A, acc2);
        assertEq(cr.addressOf(KEY_A), acc1, "a mistake is permanent by design");
    }

    function test_CR_unknownIdentifierAndZeroAddress_revert_isCorrect() public {
        vm.startPrank(owner);
        vm.expectRevert(IdentifierNotFound.selector);
        cr.set(keccak256("unknown"), acc1);
        vm.expectRevert(ZeroAddress.selector);
        cr.set(KEY_A, address(0));
        vm.stopPrank();
        assertEq(cr.addressOf(KEY_A), address(0));
    }

    function test_CR_setAccessControl_isCorrect() public {
        vm.prank(attacker);
        vm.expectRevert(Unauthorized.selector);
        cr.set(KEY_A, attacker);
    }

    function test_CR_identifierOutOfBounds_reverts_isCorrect() public {
        assertEq(cr.identifierCount(), 2);
        vm.expectRevert();
        cr.identifier(2);
    }

    // FINDING (low): initialize() pushes identifiers blindly. A duplicated key
    // inflates identifierCount(), makes identifier(i) non-injective, and creates
    // a list slot that can never correspond to its own address entry.
    function test_CR_duplicateIdentifiersInInitialize_inflateCountAndAliasSlots() public {
        ContractRegistry d = ContractRegistry(payable(LibClone.clone(address(crImpl))));
        bytes32[] memory ids = new bytes32[](3);
        ids[0] = KEY_A;
        ids[1] = KEY_A;
        ids[2] = KEY_B;
        d.initialize(owner, ids);

        assertEq(d.identifierCount(), 3, "count claims 3 configurable keys");
        assertEq(d.identifier(0), d.identifier(1), "identifier() is not injective");

        vm.prank(owner);
        d.set(KEY_A, acc1);

        // only 2 of the 3 advertised slots can ever hold an address
        vm.prank(owner);
        vm.expectRevert(IdentifierAlreadyExists.selector);
        d.set(KEY_A, acc2);

        uint256 settable = 0;
        for (uint256 i = 0; i < d.identifierCount(); i++) {
            if (d.addressOf(d.identifier(i)) != address(0)) settable++;
        }
        assertEq(settable, 2, "one identifier slot resolves to an already-taken key");
    }

    // FINDING (info): an empty identifier list produces a registry in which
    // set() can never succeed, and the list is immutable after initialize().
    function test_CR_initializeWithNoIdentifiers_isPermanentlyUnusable() public {
        ContractRegistry e = ContractRegistry(payable(LibClone.clone(address(crImpl))));
        e.initialize(owner, new bytes32[](0));
        assertEq(e.identifierCount(), 0);

        vm.prank(owner);
        vm.expectRevert(IdentifierNotFound.selector);
        e.set(KEY_A, acc1);
    }

    // FINDING (info): zero owner is accepted, permanently bricking set().
    function test_CR_initializeZeroOwner_bricksSetForever() public {
        ContractRegistry o = ContractRegistry(payable(LibClone.clone(address(crImpl))));
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = KEY_A;
        o.initialize(address(0), ids);

        assertEq(o.owner(), address(0));
        vm.prank(attacker);
        vm.expectRevert(Unauthorized.selector);
        o.set(KEY_A, attacker);
        vm.prank(owner);
        vm.expectRevert(Unauthorized.selector);
        o.set(KEY_A, acc1);
    }

    function test_CR_initializerSafety_isCorrect() public {
        vm.expectRevert(InvalidInitialization.selector);
        crImpl.initialize(attacker, new bytes32[](0));
        vm.expectRevert(InvalidInitialization.selector);
        cr.initialize(attacker, new bytes32[](0));
    }

    function test_CR_addressOfUnsetIdentifier_returnsZero_isCorrect() public view {
        assertEq(cr.addressOf(KEY_A), address(0));
        assertEq(cr.addressOf(keccak256("never-configured")), address(0));
    }

    /* ============================================================ *
     *  PART 6 - invariant-style fuzzing                             *
     * ============================================================ */

    // For well-formed usage the AccountsIndex enumeration/whitelist agree.
    function test_AI_fuzz_enumerationMatchesHave_holds(uint8 n, uint8 removeAt) public {
        n = uint8(bound(n, 1, 24));
        address[] memory accs = new address[](n);
        vm.startPrank(writer);
        for (uint256 i = 0; i < n; i++) {
            accs[i] = address(uint160(0x1000 + i));
            ai.add(accs[i]);
        }
        uint256 k = bound(removeAt, 0, n - 1);
        ai.remove(accs[k]);
        vm.stopPrank();

        assertEq(ai.entryCount(), n - 1);
        assertFalse(ai.have(accs[k]));
        for (uint256 i = 0; i < ai.entryCount(); i++) {
            address e = ai.entry(i);
            assertTrue(ai.have(e), "every enumerated entry passes have()");
            assertTrue(e != accs[k], "the removed entry is gone");
        }
    }

    // Same invariant for TokenUniqueSymbolIndex with single-symbol tokens.
    function test_TI_fuzz_enumerationMatchesHave_holds(uint8 n, uint8 removeAt) public {
        n = uint8(bound(n, 1, 12));
        address[] memory toks = new address[](n);
        vm.startPrank(writer);
        for (uint256 i = 0; i < n; i++) {
            toks[i] = address(new IxStringSymbolToken("t", string(abi.encodePacked("S", vm.toString(i)))));
            ti.add(toks[i]);
        }
        uint256 k = bound(removeAt, 0, n - 1);
        ti.remove(toks[k]);
        vm.stopPrank();

        assertEq(ti.entryCount(), n - 1);
        assertEq(ti.identifierCount(), n - 1);
        assertFalse(ti.have(toks[k]));
        for (uint256 i = 0; i < ti.entryCount(); i++) {
            address e = ti.entry(i);
            assertTrue(ti.have(e), "every enumerated entry passes have()");
            assertEq(ti.addressOf(ti.identifier(i)), e, "identifier(i) resolves back to entry(i)");
        }
    }
}
