// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {PredictionMarket, Resolution} from "../src/PredictionMarket.sol";
import {MockERC20, MockResolver, ReentrantERC20} from "./mocks/Mocks.sol";

contract PredictionMarketTest is Test {
    PredictionMarket internal pm;
    MockERC20 internal coll;

    address internal oracle = address(0x074C1E);
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);
    address internal carol = address(0xCA401);

    uint64 internal deadline;
    bytes32 internal constant Q = keccak256("Will it rain tomorrow?");

    function setUp() public {
        pm = new PredictionMarket();
        coll = new MockERC20("USD Coin", "USDC", 6);
        deadline = uint64(block.timestamp + 7 days);

        _fund(alice);
        _fund(bob);
        _fund(carol);
    }

    function _fund(address who) internal {
        coll.mint(who, 1_000_000e6);
        vm.prank(who);
        coll.approve(address(pm), type(uint256).max);
    }

    function _newMarket() internal returns (uint256 id) {
        id = pm.createMarket(Q, coll, oracle, deadline);
    }

    function _mint(address who, uint256 id, uint256 amount) internal {
        vm.prank(who);
        pm.mintCompleteSet(id, amount);
    }

    function _resolve(uint256 id, Resolution r) internal {
        vm.warp(deadline);
        vm.prank(oracle);
        pm.resolve(id, r);
    }

    // ------------------------------------------------------------------ //
    //                              Creation                              //
    // ------------------------------------------------------------------ //

    function test_CreateMarket_SetsFields() public {
        uint256 id = _newMarket();
        PredictionMarket.Market memory m = pm.marketInfo(id);
        assertEq(m.question, Q);
        assertEq(address(m.collateral), address(coll));
        assertEq(m.oracle, oracle);
        assertEq(m.tradingDeadline, deadline);
        assertFalse(m.resolved);
        assertEq(uint256(m.resolution), uint256(Resolution.Unresolved));
        assertEq(pm.collateralOf(id), 0);
        assertFalse(pm.isResolved(id));
    }

    function test_CreateMarket_IncrementsIds() public {
        assertEq(_newMarket(), 0);
        assertEq(_newMarket(), 1);
        assertEq(_newMarket(), 2);
        assertEq(pm.marketCount(), 3);
    }

    function test_CreateMarket_RevertZeroCollateral() public {
        vm.expectRevert(PredictionMarket.ZeroAddress.selector);
        pm.createMarket(Q, MockERC20(address(0)), oracle, deadline);
    }

    function test_CreateMarket_RevertZeroOracle() public {
        vm.expectRevert(PredictionMarket.ZeroAddress.selector);
        pm.createMarket(Q, coll, address(0), deadline);
    }

    function test_CreateMarket_RevertPastDeadline() public {
        vm.expectRevert(PredictionMarket.InvalidDeadline.selector);
        pm.createMarket(Q, coll, oracle, uint64(block.timestamp));
    }

    // ------------------------------------------------------------------ //
    //                       Complete-set mint / burn                     //
    // ------------------------------------------------------------------ //

    function test_MintCompleteSet_CreditsBothOutcomes() public {
        uint256 id = _newMarket();
        _mint(alice, id, 100e6);
        assertEq(pm.sharesOf(id, uint8(0), alice), 100e6);
        assertEq(pm.sharesOf(id, uint8(1), alice), 100e6);
        assertEq(pm.totalSupplyOf(id, uint8(0)), 100e6);
        assertEq(pm.totalSupplyOf(id, uint8(1)), 100e6);
        assertEq(pm.collateralOf(id), 100e6);
        assertEq(coll.balanceOf(address(pm)), 100e6);
    }

    function test_MintCompleteSet_PullsExactCollateral() public {
        uint256 id = _newMarket();
        uint256 before = coll.balanceOf(alice);
        _mint(alice, id, 250e6);
        assertEq(before - coll.balanceOf(alice), 250e6);
    }

    function test_MintCompleteSet_RevertZeroAmount() public {
        uint256 id = _newMarket();
        vm.prank(alice);
        vm.expectRevert(PredictionMarket.ZeroAmount.selector);
        pm.mintCompleteSet(id, 0);
    }

    function test_MintCompleteSet_RevertUnknownMarket() public {
        vm.prank(alice);
        vm.expectRevert(PredictionMarket.UnknownMarket.selector);
        pm.mintCompleteSet(42, 1e6);
    }

    function test_MintCompleteSet_RevertAfterDeadline() public {
        uint256 id = _newMarket();
        vm.warp(deadline);
        vm.prank(alice);
        vm.expectRevert(PredictionMarket.TradingClosed.selector);
        pm.mintCompleteSet(id, 1e6);
    }

    function test_BurnCompleteSet_RoundTripExact() public {
        uint256 id = _newMarket();
        uint256 before = coll.balanceOf(alice);
        _mint(alice, id, 100e6);
        vm.prank(alice);
        pm.burnCompleteSet(id, 100e6);
        assertEq(coll.balanceOf(alice), before);
        assertEq(pm.sharesOf(id, uint8(0), alice), 0);
        assertEq(pm.sharesOf(id, uint8(1), alice), 0);
        assertEq(pm.collateralOf(id), 0);
        assertEq(pm.totalSupplyOf(id, uint8(0)), 0);
    }

    function test_BurnCompleteSet_Partial() public {
        uint256 id = _newMarket();
        _mint(alice, id, 100e6);
        vm.prank(alice);
        pm.burnCompleteSet(id, 40e6);
        assertEq(pm.sharesOf(id, uint8(0), alice), 60e6);
        assertEq(pm.sharesOf(id, uint8(1), alice), 60e6);
        assertEq(pm.collateralOf(id), 60e6);
    }

    function test_BurnCompleteSet_RevertInsufficient() public {
        uint256 id = _newMarket();
        _mint(alice, id, 10e6);
        // Sell away one leg so the set is incomplete.
        vm.prank(alice);
        pm.transferShares(id, uint8(0), bob, 10e6);
        vm.prank(alice);
        vm.expectRevert(PredictionMarket.InsufficientShares.selector);
        pm.burnCompleteSet(id, 10e6);
    }

    function test_BurnCompleteSet_RevertAfterDeadline() public {
        uint256 id = _newMarket();
        _mint(alice, id, 10e6);
        vm.warp(deadline);
        vm.prank(alice);
        vm.expectRevert(PredictionMarket.TradingClosed.selector);
        pm.burnCompleteSet(id, 10e6);
    }

    // ------------------------------------------------------------------ //
    //                          Directional trade                         //
    // ------------------------------------------------------------------ //

    /// @dev Buy YES exposure: mint a complete set, then sell the NO leg to a
    ///      counterparty. Alice ends up net-long YES, Bob net-long NO.
    function test_DirectionalExposure_ViaMintThenSellNo() public {
        uint256 id = _newMarket();
        _mint(alice, id, 100e6);
        vm.prank(alice);
        pm.transferShares(id, uint8(1), bob, 100e6);

        assertEq(pm.sharesOf(id, uint8(0), alice), 100e6);
        assertEq(pm.sharesOf(id, uint8(1), alice), 0);
        assertEq(pm.sharesOf(id, uint8(1), bob), 100e6);
        // Supply unchanged by transfer.
        assertEq(pm.totalSupplyOf(id, uint8(1)), 100e6);
        assertEq(pm.collateralOf(id), 100e6);
    }

    // ------------------------------------------------------------------ //
    //                          Share transfer                            //
    // ------------------------------------------------------------------ //

    function test_TransferShares_MovesBalance() public {
        uint256 id = _newMarket();
        _mint(alice, id, 50e6);
        vm.prank(alice);
        pm.transferShares(id, uint8(0), bob, 20e6);
        assertEq(pm.sharesOf(id, uint8(0), alice), 30e6);
        assertEq(pm.sharesOf(id, uint8(0), bob), 20e6);
    }

    function test_TransferShares_RevertInsufficient() public {
        uint256 id = _newMarket();
        _mint(alice, id, 5e6);
        vm.prank(alice);
        vm.expectRevert(PredictionMarket.InsufficientShares.selector);
        pm.transferShares(id, uint8(0), bob, 6e6);
    }

    function test_TransferShares_RevertZeroTo() public {
        uint256 id = _newMarket();
        _mint(alice, id, 5e6);
        vm.prank(alice);
        vm.expectRevert(PredictionMarket.ZeroAddress.selector);
        pm.transferShares(id, uint8(0), address(0), 1e6);
    }

    function test_TransferShares_RevertBadOutcome() public {
        uint256 id = _newMarket();
        _mint(alice, id, 5e6);
        vm.prank(alice);
        vm.expectRevert(PredictionMarket.InvalidOutcome.selector);
        pm.transferShares(id, 2, bob, 1e6);
    }

    function test_TransferShares_AllowedAfterResolution() public {
        uint256 id = _newMarket();
        _mint(alice, id, 50e6);
        _resolve(id, Resolution.Yes);
        // Transfer still works post-resolution.
        vm.prank(alice);
        pm.transferShares(id, uint8(0), bob, 50e6);
        assertEq(pm.sharesOf(id, uint8(0), bob), 50e6);
    }

    // ------------------------------------------------------------------ //
    //                             Resolution                             //
    // ------------------------------------------------------------------ //

    function test_Resolve_SetsState() public {
        uint256 id = _newMarket();
        _resolve(id, Resolution.Yes);
        assertTrue(pm.isResolved(id));
        assertEq(uint256(pm.winningOutcome(id)), uint256(Resolution.Yes));
    }

    function test_Resolve_RevertBeforeDeadline() public {
        uint256 id = _newMarket();
        vm.prank(oracle);
        vm.expectRevert(PredictionMarket.TradingStillOpen.selector);
        pm.resolve(id, Resolution.Yes);
    }

    function test_Resolve_RevertNotOracle() public {
        uint256 id = _newMarket();
        vm.warp(deadline);
        vm.prank(alice);
        vm.expectRevert(PredictionMarket.NotOracle.selector);
        pm.resolve(id, Resolution.Yes);
    }

    function test_Resolve_RevertTwice() public {
        uint256 id = _newMarket();
        _resolve(id, Resolution.Yes);
        vm.prank(oracle);
        vm.expectRevert(PredictionMarket.AlreadyResolved.selector);
        pm.resolve(id, Resolution.No);
    }

    function test_Resolve_RevertUnresolvedArg() public {
        uint256 id = _newMarket();
        vm.warp(deadline);
        vm.prank(oracle);
        vm.expectRevert(PredictionMarket.BadResolution.selector);
        pm.resolve(id, Resolution.Unresolved);
    }

    function test_Resolve_ViaContractOracle() public {
        MockResolver resolver = new MockResolver(pm);
        uint256 id = pm.createMarket(Q, coll, address(resolver), deadline);
        _mint(alice, id, 10e6);
        vm.warp(deadline);
        resolver.report(id, Resolution.No);
        assertEq(uint256(pm.winningOutcome(id)), uint256(Resolution.No));
    }

    function test_WinningOutcome_RevertBeforeResolution() public {
        uint256 id = _newMarket();
        vm.expectRevert(PredictionMarket.NotResolved.selector);
        pm.winningOutcome(id);
    }

    // ------------------------------------------------------------------ //
    //                             Redemption                             //
    // ------------------------------------------------------------------ //

    function test_Redeem_YesWinner_GetsOnePerShare() public {
        uint256 id = _newMarket();
        _mint(alice, id, 100e6);
        // Alice keeps YES, hands NO to bob.
        vm.prank(alice);
        pm.transferShares(id, uint8(1), bob, 100e6);
        _resolve(id, Resolution.Yes);

        uint256 before = coll.balanceOf(alice);
        vm.prank(alice);
        uint256 paid = pm.redeem(id);
        assertEq(paid, 100e6);
        assertEq(coll.balanceOf(alice) - before, 100e6);
        assertEq(pm.sharesOf(id, uint8(0), alice), 0);
    }

    function test_Redeem_Loser_GetsZero() public {
        uint256 id = _newMarket();
        _mint(alice, id, 100e6);
        vm.prank(alice);
        pm.transferShares(id, uint8(1), bob, 100e6);
        _resolve(id, Resolution.Yes);

        uint256 potBefore = pm.collateralOf(id);
        uint256 before = coll.balanceOf(bob);
        vm.prank(bob);
        uint256 paid = pm.redeem(id); // bob holds only losing NO
        assertEq(paid, 0);
        assertEq(coll.balanceOf(bob), before);
        assertEq(pm.collateralOf(id), potBefore); // pot untouched by loser
        assertEq(pm.sharesOf(id, uint8(1), bob), 0); // losing shares burned
    }

    function test_Redeem_NoWinner_GetsOnePerShare() public {
        uint256 id = _newMarket();
        _mint(alice, id, 80e6);
        _resolve(id, Resolution.No);
        uint256 before = coll.balanceOf(alice);
        vm.prank(alice);
        uint256 paid = pm.redeem(id); // holds both; NO wins
        assertEq(paid, 80e6);
        assertEq(coll.balanceOf(alice) - before, 80e6);
        assertEq(pm.collateralOf(id), 0);
    }

    function test_Redeem_RevertBeforeResolution() public {
        uint256 id = _newMarket();
        _mint(alice, id, 10e6);
        vm.prank(alice);
        vm.expectRevert(PredictionMarket.NotResolved.selector);
        pm.redeem(id);
    }

    function test_Redeem_RevertNoShares() public {
        uint256 id = _newMarket();
        _mint(alice, id, 10e6);
        _resolve(id, Resolution.Yes);
        vm.prank(carol); // never held anything
        vm.expectRevert(PredictionMarket.InsufficientShares.selector);
        pm.redeem(id);
    }

    function test_Redeem_RevertDoubleRedeem() public {
        uint256 id = _newMarket();
        _mint(alice, id, 10e6);
        _resolve(id, Resolution.Yes);
        vm.prank(alice);
        pm.redeem(id);
        vm.prank(alice);
        vm.expectRevert(PredictionMarket.InsufficientShares.selector);
        pm.redeem(id);
    }

    function test_Redeem_TransferThenRecipientRedeems() public {
        uint256 id = _newMarket();
        _mint(alice, id, 100e6);
        vm.prank(alice);
        pm.transferShares(id, uint8(0), carol, 60e6);
        _resolve(id, Resolution.Yes);

        uint256 carolBefore = coll.balanceOf(carol);
        vm.prank(carol);
        uint256 paid = pm.redeem(id);
        assertEq(paid, 60e6);
        assertEq(coll.balanceOf(carol) - carolBefore, 60e6);

        vm.prank(alice);
        uint256 paidA = pm.redeem(id);
        assertEq(paidA, 40e6); // alice kept 40 YES (+ her 100 NO, worth 0)
        assertEq(pm.collateralOf(id), 0);
    }

    // ------------------------------------------------------------------ //
    //                        INVALID resolution                          //
    // ------------------------------------------------------------------ //

    function test_Invalid_EachLegRedeemsHalf() public {
        uint256 id = _newMarket();
        _mint(alice, id, 100e6);
        vm.prank(alice);
        pm.transferShares(id, uint8(1), bob, 100e6);
        _resolve(id, Resolution.Invalid);

        vm.prank(alice);
        assertEq(pm.redeem(id), 50e6); // 100 YES -> 50
        vm.prank(bob);
        assertEq(pm.redeem(id), 50e6); // 100 NO -> 50
        assertEq(pm.collateralOf(id), 0); // 100 in, 100 out
    }

    function test_Invalid_CompleteSetRedeemsToWhole() public {
        uint256 id = _newMarket();
        _mint(alice, id, 100e6);
        _resolve(id, Resolution.Invalid);
        vm.prank(alice);
        uint256 paid = pm.redeem(id); // holds 100 YES + 100 NO -> 50 + 50
        assertEq(paid, 100e6);
        assertEq(pm.collateralOf(id), 0);
    }

    /// @dev Odd wei: 1 share on each leg held by different people redeems to 0 each
    ///      (floor(1/2)), and the 1-wei dust stays in the pot — never over-paid.
    function test_Invalid_OddWeiFavorsMarket() public {
        uint256 id = _newMarket();
        _mint(alice, id, 1); // 1 YES + 1 NO, pot = 1
        vm.prank(alice);
        pm.transferShares(id, uint8(1), bob, 1);
        _resolve(id, Resolution.Invalid);

        vm.prank(alice);
        assertEq(pm.redeem(id), 0); // floor(1/2) = 0
        vm.prank(bob);
        assertEq(pm.redeem(id), 0);
        assertEq(pm.collateralOf(id), 1); // dust retained by market
    }

    // ------------------------------------------------------------------ //
    //                        Multi-market isolation                      //
    // ------------------------------------------------------------------ //

    function test_MultiMarket_CollateralIsolation() public {
        uint256 a = _newMarket();
        uint256 b = _newMarket();
        _mint(alice, a, 100e6);
        _mint(bob, b, 300e6);
        assertEq(pm.collateralOf(a), 100e6);
        assertEq(pm.collateralOf(b), 300e6);
        assertEq(coll.balanceOf(address(pm)), 400e6);

        // Resolve+drain market A entirely; market B's pot is untouched.
        _resolve(a, Resolution.Yes);
        vm.prank(alice);
        pm.redeem(a);
        assertEq(pm.collateralOf(a), 0);
        assertEq(pm.collateralOf(b), 300e6);
        assertEq(coll.balanceOf(address(pm)), 300e6);
    }

    // ------------------------------------------------------------------ //
    //                             Reentrancy                             //
    // ------------------------------------------------------------------ //

    function test_Reentrancy_RedeemGuarded() public {
        ReentrantERC20 evil = new ReentrantERC20();
        evil.mint(alice, 1_000e6);
        vm.prank(alice);
        evil.approve(address(pm), type(uint256).max);

        uint256 id = pm.createMarket(Q, evil, oracle, deadline);
        vm.prank(alice);
        pm.mintCompleteSet(id, 100e6);
        vm.warp(deadline);
        vm.prank(oracle);
        pm.resolve(id, Resolution.Yes);

        evil.armRedeem(pm, id);
        vm.prank(alice);
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        pm.redeem(id);
    }

    function test_Reentrancy_BurnGuarded() public {
        ReentrantERC20 evil = new ReentrantERC20();
        evil.mint(alice, 1_000e6);
        vm.prank(alice);
        evil.approve(address(pm), type(uint256).max);

        uint256 id = pm.createMarket(Q, evil, oracle, deadline);
        vm.prank(alice);
        pm.mintCompleteSet(id, 100e6);

        evil.armBurn(pm, id, 10e6);
        vm.prank(alice);
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        pm.burnCompleteSet(id, 50e6);
    }

    // ------------------------------------------------------------------ //
    //                         Solvency sequence                          //
    // ------------------------------------------------------------------ //

    /// @dev A scripted mix of mint/burn/transfer across actors, then resolve, then
    ///      every holder redeems. Total paid out must never exceed collateral in.
    function test_Solvency_ArbitrarySequence() public {
        uint256 id = _newMarket();
        uint256 potIn;

        _mint(alice, id, 100e6);
        potIn += 100e6;
        _mint(bob, id, 50e6);
        potIn += 50e6;

        vm.prank(alice);
        pm.transferShares(id, uint8(0), carol, 30e6);
        vm.prank(bob);
        pm.transferShares(id, uint8(1), carol, 20e6);

        vm.prank(bob);
        pm.burnCompleteSet(id, 10e6); // bob withdraws 10 complete set
        potIn -= 10e6;

        _mint(carol, id, 25e6);
        potIn += 25e6;

        assertEq(pm.collateralOf(id), potIn);

        _resolve(id, Resolution.Yes);

        uint256 paidOut;
        vm.prank(alice);
        paidOut += pm.redeem(id);
        vm.prank(bob);
        paidOut += pm.redeem(id);
        vm.prank(carol);
        paidOut += pm.redeem(id);

        assertLe(paidOut, potIn, "over-paid");
        // YES-win: pot exactly drains to total YES outstanding at resolution.
        assertEq(paidOut, potIn); // all collateral was backing YES via complete sets
        assertEq(pm.collateralOf(id), 0);
        assertGe(coll.balanceOf(address(pm)), 0);
    }

    // ------------------------------------------------------------------ //
    //                               Fuzz                                 //
    // ------------------------------------------------------------------ //

    function testFuzz_MintBurnRoundTrip(uint256 amount) public {
        amount = bound(amount, 1, 500_000e6);
        uint256 id = _newMarket();
        uint256 before = coll.balanceOf(alice);
        _mint(alice, id, amount);
        vm.prank(alice);
        pm.burnCompleteSet(id, amount);
        assertEq(coll.balanceOf(alice), before);
        assertEq(pm.collateralOf(id), 0);
    }

    function testFuzz_YesRedeemEqualsShares(uint256 amount) public {
        amount = bound(amount, 1, 500_000e6);
        uint256 id = _newMarket();
        _mint(alice, id, amount);
        _resolve(id, Resolution.Yes);
        vm.prank(alice);
        assertEq(pm.redeem(id), amount);
        assertEq(pm.collateralOf(id), 0);
    }

    function testFuzz_InvalidNeverOverpays(uint256 amount) public {
        amount = bound(amount, 1, 500_000e6);
        uint256 id = _newMarket();
        _mint(alice, id, amount);
        // Split legs across two holders in a fuzzed way.
        vm.prank(alice);
        pm.transferShares(id, uint8(1), bob, amount);
        _resolve(id, Resolution.Invalid);

        vm.prank(alice);
        uint256 pa = pm.redeem(id);
        vm.prank(bob);
        uint256 pb = pm.redeem(id);
        assertLe(pa + pb, amount, "over-paid on invalid");
        assertEq(pa, amount / 2);
        assertEq(pb, amount / 2);
    }

    // ================================================================== //
    //                        Deep dive (v2) tests                        //
    // ================================================================== //

    // ------------------------------------------------------------------ //
    //          INVALID split across MANY holders — solvency crux         //
    // ------------------------------------------------------------------ //

    /// @dev The adversarial case for the "floor both legs" scheme: scatter an odd
    ///      supply across many holders in odd-sized chunks, on BOTH legs, held by
    ///      disjoint accounts. Because sum-of-floors <= floor-of-sum, splitting can
    ///      only LOSE payout to per-account dust; the summed payout can never exceed
    ///      the pot. Verifies each holder gets exactly floor(bal/2), the total is
    ///      <= pot, and the pot never underflows (a bug would revert here).
    function test_Invalid_ManyHolderOddSplit_NeverOverpays() public {
        uint256 id = _newMarket();
        _mint(alice, id, 101); // 101 YES + 101 NO, pot = 101 (odd on purpose)

        // Disjoint holder sets for each leg, odd chunks summing to 101.
        address[5] memory yesHolders =
            [address(0x1001), address(0x1002), address(0x1003), address(0x1004), address(0x1005)];
        uint256[5] memory yesAmt = [uint256(33), 25, 17, 13, 13];
        address[5] memory noHolders =
            [address(0x2001), address(0x2002), address(0x2003), address(0x2004), address(0x2005)];
        uint256[5] memory noAmt = [uint256(51), 25, 11, 7, 7];

        for (uint256 i; i < 5; i++) {
            vm.prank(alice);
            pm.transferShares(id, uint8(0), yesHolders[i], yesAmt[i]);
            vm.prank(alice);
            pm.transferShares(id, uint8(1), noHolders[i], noAmt[i]);
        }
        // Alice fully divested both legs.
        assertEq(pm.sharesOf(id, uint8(0), alice), 0);
        assertEq(pm.sharesOf(id, uint8(1), alice), 0);

        _resolve(id, Resolution.Invalid);
        uint256 pot0 = pm.collateralOf(id);
        assertEq(pot0, 101);

        uint256 totalPaid;
        for (uint256 i; i < 5; i++) {
            vm.prank(yesHolders[i]);
            uint256 py = pm.redeem(id);
            assertEq(py, yesAmt[i] / 2, "yes holder != floor(bal/2)");
            totalPaid += py;
            vm.prank(noHolders[i]);
            uint256 pn = pm.redeem(id);
            assertEq(pn, noAmt[i] / 2, "no holder != floor(bal/2)");
            totalPaid += pn;
        }

        // Fragmenting an odd supply strictly reduces payout below the whole-set value.
        assertLt(totalPaid, pot0, "fragmented payout should be < pot");
        assertLe(totalPaid, pot0, "over-paid on many-holder invalid");
        // Dust retained by the market; pot never underflowed.
        assertEq(pm.collateralOf(id), pot0 - totalPaid);
        assertGe(coll.balanceOf(address(pm)), pm.collateralOf(id));
    }

    /// @dev Fuzzed many-holder INVALID: an arbitrary supply split three ways on each
    ///      leg across disjoint holders. Total payout must stay <= pot for every split.
    function testFuzz_Invalid_ThreeWaySplit_NeverOverpays(uint256 amount, uint256 s1, uint256 s2) public {
        amount = bound(amount, 2, 500_000e6);
        uint256 y1 = bound(s1, 0, amount);
        uint256 y2 = bound(s2, 0, amount - y1);
        uint256 y3 = amount - y1 - y2;

        uint256 id = _newMarket();
        _mint(alice, id, amount);
        address h1 = address(0x3001);
        address h2 = address(0x3002);
        address h3 = address(0x3003);
        // Split the YES leg three ways; leave the whole NO leg on alice.
        if (y1 != 0) {
            vm.prank(alice);
            pm.transferShares(id, uint8(0), h1, y1);
        }
        if (y2 != 0) {
            vm.prank(alice);
            pm.transferShares(id, uint8(0), h2, y2);
        }
        if (y3 != 0) {
            vm.prank(alice);
            pm.transferShares(id, uint8(0), h3, y3);
        }
        _resolve(id, Resolution.Invalid);

        uint256 paid;
        if (y1 != 0) {
            vm.prank(h1);
            paid += pm.redeem(id);
        }
        if (y2 != 0) {
            vm.prank(h2);
            paid += pm.redeem(id);
        }
        if (y3 != 0) {
            vm.prank(h3);
            paid += pm.redeem(id);
        }
        vm.prank(alice); // holds full NO leg (+ any zeroed YES)
        paid += pm.redeem(id);

        assertLe(paid, amount, "fuzz invalid split over-paid");
        assertGe(pm.collateralOf(id) + paid, amount); // conservation: dust + paid <= in
    }

    // ------------------------------------------------------------------ //
    //                Cross-market isolation — hostile drain              //
    // ------------------------------------------------------------------ //

    /// @dev Two markets share one token. Fully drain market A (YES win). Market B must
    ///      remain fully redeemable afterwards — its collateral was never touched.
    function test_CrossMarket_DrainA_BStillFullyPayable() public {
        uint256 a = _newMarket();
        uint256 b = _newMarket();
        _mint(alice, a, 100e6);
        _mint(bob, b, 300e6);

        _resolve(a, Resolution.Yes); // resolve warps to deadline; b shares same deadline
        vm.prank(alice);
        assertEq(pm.redeem(a), 100e6);
        assertEq(pm.collateralOf(a), 0);

        // Market B untouched and still exactly covers its winner.
        assertEq(pm.collateralOf(b), 300e6);
        vm.prank(oracle);
        pm.resolve(b, Resolution.No);
        vm.prank(bob);
        assertEq(pm.redeem(b), 300e6);
        assertEq(pm.collateralOf(b), 0);
        assertEq(coll.balanceOf(address(pm)), 0);
    }

    /// @dev Per-market collateral token is respected: a market on token X cannot be
    ///      funded or drained through token Y. Redemption pays in the market's own token.
    function test_CrossMarket_DistinctTokens_NoCrossPay() public {
        MockERC20 collB = new MockERC20("DAI", "DAI", 18);
        collB.mint(bob, 1_000e18);
        vm.prank(bob);
        collB.approve(address(pm), type(uint256).max);

        uint256 a = _newMarket(); // uses coll (6dp)
        uint256 b = pm.createMarket(Q, collB, oracle, deadline); // uses collB (18dp)

        _mint(alice, a, 100e6);
        vm.prank(bob);
        pm.mintCompleteSet(b, 500e18);

        assertEq(coll.balanceOf(address(pm)), 100e6);
        assertEq(collB.balanceOf(address(pm)), 500e18);

        _resolve(a, Resolution.Yes);
        vm.prank(oracle);
        pm.resolve(b, Resolution.Yes);

        uint256 aBefore = coll.balanceOf(alice);
        uint256 bBefore = collB.balanceOf(bob);
        vm.prank(alice);
        pm.redeem(a);
        vm.prank(bob);
        pm.redeem(b);
        // Each paid strictly in its own token; balances of the other token untouched.
        assertEq(coll.balanceOf(alice) - aBefore, 100e6);
        assertEq(collB.balanceOf(bob) - bBefore, 500e18);
        assertEq(coll.balanceOf(address(pm)), 0);
        assertEq(collB.balanceOf(address(pm)), 0);
    }

    // ------------------------------------------------------------------ //
    //               Post-resolution mint / burn are gated               //
    // ------------------------------------------------------------------ //

    function test_MintAfterResolution_Reverts() public {
        uint256 id = _newMarket();
        _mint(alice, id, 10e6);
        _resolve(id, Resolution.Yes);
        vm.prank(alice);
        vm.expectRevert(PredictionMarket.TradingClosed.selector);
        pm.mintCompleteSet(id, 1e6);
    }

    function test_BurnAfterResolution_Reverts() public {
        uint256 id = _newMarket();
        _mint(alice, id, 10e6);
        _resolve(id, Resolution.Yes);
        vm.prank(alice);
        vm.expectRevert(PredictionMarket.TradingClosed.selector);
        pm.burnCompleteSet(id, 1e6);
    }

    /// @dev No free winning shares: a winner cannot mint after resolution to redeem 1:1.
    function test_NoFreeShares_MintBlockedPostResolve() public {
        uint256 id = _newMarket();
        _mint(alice, id, 10e6);
        _resolve(id, Resolution.Yes);
        uint256 supplyBefore = pm.totalSupplyOf(id, uint8(0));
        vm.prank(alice);
        vm.expectRevert(PredictionMarket.TradingClosed.selector);
        pm.mintCompleteSet(id, 1_000e6);
        assertEq(pm.totalSupplyOf(id, uint8(0)), supplyBefore);
    }

    // ------------------------------------------------------------------ //
    //              Double-redeem hardening across transfers             //
    // ------------------------------------------------------------------ //

    /// @dev Split winning shares to three accounts; all redeem; the total equals the
    ///      supply exactly and the origin account can't redeem a second time.
    function test_Redeem_FanOutThenAllRedeem_NoDouble() public {
        uint256 id = _newMarket();
        _mint(alice, id, 90e6); // 90 YES to fan out
        address[3] memory hs = [address(0x4001), address(0x4002), address(0x4003)];
        for (uint256 i; i < 3; i++) {
            vm.prank(alice);
            pm.transferShares(id, uint8(0), hs[i], 30e6);
        }
        _resolve(id, Resolution.Yes);

        uint256 total;
        for (uint256 i; i < 3; i++) {
            vm.prank(hs[i]);
            total += pm.redeem(id);
        }
        assertEq(total, 90e6);
        // Alice kept only losing NO -> redeeming burns it for 0 (allowed once)...
        vm.prank(alice);
        assertEq(pm.redeem(id), 0);
        // ...and a further redeem by alice now reverts (nothing left).
        vm.prank(alice);
        vm.expectRevert(PredictionMarket.InsufficientShares.selector);
        pm.redeem(id);
        assertEq(pm.collateralOf(id), 0);
    }

    /// @dev A winner who redeems then re-acquires shares by transfer can redeem the
    ///      newly-received shares (they were already backed) — but never double-spends
    ///      the same shares. Solvency holds: total out == supply.
    function test_Redeem_ReacquireAfterRedeem_StillSolvent() public {
        uint256 id = _newMarket();
        _mint(alice, id, 100e6);
        vm.prank(alice);
        pm.transferShares(id, uint8(0), bob, 40e6);
        _resolve(id, Resolution.Yes);

        vm.prank(alice);
        assertEq(pm.redeem(id), 60e6); // alice redeems her 60 YES
        // Bob hands his 40 YES to alice; alice redeems those too.
        vm.prank(bob);
        pm.transferShares(id, uint8(0), alice, 40e6);
        vm.prank(alice);
        assertEq(pm.redeem(id), 40e6);
        assertEq(pm.collateralOf(id), 0); // exactly drained, never over
    }

    // ------------------------------------------------------------------ //
    //                    Transfer conservation / edges                  //
    // ------------------------------------------------------------------ //

    /// @dev Self-transfer must be a no-op on balance (reads bal once, writes back).
    function test_TransferShares_SelfTransfer_Conserves() public {
        uint256 id = _newMarket();
        _mint(alice, id, 50e6);
        vm.prank(alice);
        pm.transferShares(id, uint8(0), alice, 50e6);
        assertEq(pm.sharesOf(id, uint8(0), alice), 50e6);
        assertEq(pm.totalSupplyOf(id, uint8(0)), 50e6);
    }

    /// @dev Fuzz: a chain of transfers among three holders conserves total supply and
    ///      the per-outcome holder sum, and never changes the tracked supply.
    function testFuzz_TransferConservation(uint256 mintAmt, uint256 t1, uint256 t2, uint256 t3) public {
        mintAmt = bound(mintAmt, 1, 500_000e6);
        uint256 id = _newMarket();
        _mint(alice, id, mintAmt);
        uint256 supply = pm.totalSupplyOf(id, uint8(0));

        // alice -> bob
        uint256 a1 = bound(t1, 0, pm.sharesOf(id, uint8(0), alice));
        if (a1 != 0) {
            vm.prank(alice);
            pm.transferShares(id, uint8(0), bob, a1);
        }
        // bob -> carol
        uint256 a2 = bound(t2, 0, pm.sharesOf(id, uint8(0), bob));
        if (a2 != 0) {
            vm.prank(bob);
            pm.transferShares(id, uint8(0), carol, a2);
        }
        // carol -> alice
        uint256 a3 = bound(t3, 0, pm.sharesOf(id, uint8(0), carol));
        if (a3 != 0) {
            vm.prank(carol);
            pm.transferShares(id, uint8(0), alice, a3);
        }

        uint256 sum =
            pm.sharesOf(id, uint8(0), alice) + pm.sharesOf(id, uint8(0), bob) + pm.sharesOf(id, uint8(0), carol);
        assertEq(sum, supply, "transfers changed total shares");
        assertEq(pm.totalSupplyOf(id, uint8(0)), supply, "supply drifted");
    }
}
