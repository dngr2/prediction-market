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
}
