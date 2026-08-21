// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {PredictionMarket, Resolution} from "../src/PredictionMarket.sol";
import {MockERC20} from "./mocks/Mocks.sol";

/// @dev Handler that only ever issues calls that MUST succeed, so the whole suite
///      runs clean under fail-on-revert. Time is fixed once in setUp so two families
///      of markets are always live simultaneously without any time management:
///        - "trading" markets: deadline far in the future -> mint/burn/transfer.
///        - "resolvable" markets: deadline already past -> resolve/redeem/transfer.
///      A single shared collateral token exercises multi-market pot isolation.
contract Handler is Test {
    PredictionMarket internal pm;
    MockERC20 internal coll;

    address internal oracle;
    address[4] internal actors;

    uint256[] internal tradingIds;
    uint256[] internal resolvableIds;
    uint256[] internal allIds;

    constructor(PredictionMarket _pm, MockERC20 _coll, address _oracle) {
        pm = _pm;
        coll = _coll;
        oracle = _oracle;

        actors[0] = address(0xA11CE);
        actors[1] = address(0xB0B);
        actors[2] = address(0xCA401);
        actors[3] = address(0xD00D);

        for (uint256 i; i < actors.length; i++) {
            coll.mint(actors[i], 1e30);
            vm.prank(actors[i]);
            coll.approve(address(pm), type(uint256).max);
        }

        uint64 far = uint64(block.timestamp + 1_000_000);
        uint64 near = uint64(block.timestamp + 100);

        // Trading markets stay open the whole run.
        for (uint256 i; i < 2; i++) {
            uint256 id = pm.createMarket(bytes32(uint256(0x7000 + i)), coll, oracle, far);
            tradingIds.push(id);
            allIds.push(id);
            // Seed so burn/transfer have material immediately.
            vm.prank(actors[0]);
            pm.mintCompleteSet(id, 1e21);
        }

        // Resolvable markets: seed BEFORE their deadline, then time warps past it.
        for (uint256 i; i < 2; i++) {
            uint256 id = pm.createMarket(bytes32(uint256(0x8000 + i)), coll, oracle, near);
            resolvableIds.push(id);
            allIds.push(id);
            // Seed and spread shares across actors so redemption has many redeemers.
            vm.prank(actors[i % actors.length]);
            pm.mintCompleteSet(id, 4e21);
            vm.prank(actors[i % actors.length]);
            pm.transferShares(id, uint8(1), actors[(i + 1) % actors.length], 2e21);
            vm.prank(actors[i % actors.length]);
            pm.transferShares(id, uint8(0), actors[(i + 2) % actors.length], 1e21);
        }

        // Freeze time past the near deadline, before the far one.
        vm.warp(block.timestamp + 200);
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[bound(seed, 0, actors.length - 1)];
    }

    // ---- trading-phase handlers (trading markets only) ---- //

    function mint(uint256 idSeed, uint256 amtSeed, uint256 actorSeed) external {
        uint256 id = tradingIds[bound(idSeed, 0, tradingIds.length - 1)];
        uint256 amount = bound(amtSeed, 1, 1e24);
        address a = _actor(actorSeed);
        vm.prank(a);
        pm.mintCompleteSet(id, amount);
    }

    function burn(uint256 idSeed, uint256 amtSeed, uint256 actorSeed) external {
        uint256 id = tradingIds[bound(idSeed, 0, tradingIds.length - 1)];
        address a = _actor(actorSeed);
        uint256 yes = pm.sharesOf(id, uint8(0), a);
        uint256 no = pm.sharesOf(id, uint8(1), a);
        uint256 maxBurn = yes < no ? yes : no;
        if (maxBurn == 0) return;
        uint256 amount = bound(amtSeed, 1, maxBurn);
        vm.prank(a);
        pm.burnCompleteSet(id, amount);
    }

    // ---- transfer works on any market, pre or post resolution ---- //

    function transfer(uint256 idSeed, uint256 outSeed, uint256 fromSeed, uint256 toSeed, uint256 amtSeed) external {
        uint256 id = allIds[bound(idSeed, 0, allIds.length - 1)];
        uint8 outcome = uint8(bound(outSeed, 0, 1));
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        uint256 bal = pm.sharesOf(id, outcome, from);
        if (bal == 0) return;
        uint256 amount = bound(amtSeed, 1, bal);
        vm.prank(from);
        pm.transferShares(id, outcome, to, amount);
    }

    // ---- resolution-phase handlers (resolvable markets only) ---- //

    function resolveOne(uint256 idSeed, uint256 resSeed) external {
        uint256 id = resolvableIds[bound(idSeed, 0, resolvableIds.length - 1)];
        if (pm.isResolved(id)) return;
        Resolution r = Resolution(bound(resSeed, 1, 3)); // Yes|No|Invalid
        vm.prank(oracle);
        pm.resolve(id, r);
    }

    function redeemOne(uint256 idSeed, uint256 actorSeed) external {
        uint256 id = resolvableIds[bound(idSeed, 0, resolvableIds.length - 1)];
        if (!pm.isResolved(id)) return;
        address a = _actor(actorSeed);
        if (pm.sharesOf(id, uint8(0), a) == 0 && pm.sharesOf(id, uint8(1), a) == 0) return;
        vm.prank(a);
        pm.redeem(id);
    }

    // ---- views for invariants ---- //

    function actorAt(uint256 i) external view returns (address) {
        return actors[i];
    }

    function actorCount() external pure returns (uint256) {
        return 4;
    }

    function allIdsLength() external view returns (uint256) {
        return allIds.length;
    }

    function idAt(uint256 i) external view returns (uint256) {
        return allIds[i];
    }
}

/// forge-config: default.invariant.fail-on-revert = true
contract PredictionMarketInvariant is StdInvariant, Test {
    PredictionMarket internal pm;
    MockERC20 internal coll;
    Handler internal handler;
    address internal oracle = address(0x074C1E);

    function setUp() public {
        pm = new PredictionMarket();
        coll = new MockERC20("USD Coin", "USDC", 6);
        handler = new Handler(pm, coll, oracle);

        bytes4[] memory selectors = new bytes4[](5);
        selectors[0] = Handler.mint.selector;
        selectors[1] = Handler.burn.selector;
        selectors[2] = Handler.transfer.selector;
        selectors[3] = Handler.resolveOne.selector;
        selectors[4] = Handler.redeemOne.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /// Share conservation: for every market/outcome, the sum of holder balances
    /// equals the tracked total supply. Transfers move, mint/burn/redeem adjust —
    /// nothing is ever created or destroyed off the books.
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_ShareConservation() public view {
        uint256 n = handler.allIdsLength();
        uint256 na = handler.actorCount();
        for (uint256 i; i < n; i++) {
            uint256 id = handler.idAt(i);
            uint256 sumYes;
            uint256 sumNo;
            for (uint256 j; j < na; j++) {
                address a = handler.actorAt(j);
                sumYes += pm.sharesOf(id, uint8(0), a);
                sumNo += pm.sharesOf(id, uint8(1), a);
            }
            assertEq(sumYes, pm.totalSupplyOf(id, uint8(0)), "YES supply mismatch");
            assertEq(sumNo, pm.totalSupplyOf(id, uint8(1)), "NO supply mismatch");
        }
    }

    /// Collateral solvency, per market. Before resolution the pot equals both
    /// outstanding legs (== complete sets). After resolution the pot is always at
    /// least the redeemable value of all outstanding winning shares, so every winner
    /// can be paid; rounding dust (Invalid) is retained by the market.
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_Solvency() public view {
        uint256 n = handler.allIdsLength();
        for (uint256 i; i < n; i++) {
            uint256 id = handler.idAt(i);
            uint256 pot = pm.collateralOf(id);
            uint256 sY = pm.totalSupplyOf(id, uint8(0));
            uint256 sN = pm.totalSupplyOf(id, uint8(1));
            if (!pm.isResolved(id)) {
                assertEq(pot, sY, "pot != YES supply (open)");
                assertEq(pot, sN, "pot != NO supply (open)");
            } else {
                Resolution r = pm.winningOutcome(id);
                uint256 redeemable;
                if (r == Resolution.Yes) {
                    redeemable = sY;
                } else if (r == Resolution.No) {
                    redeemable = sN;
                } else {
                    redeemable = sY / 2 + sN / 2; // upper bound on payable
                }
                assertGe(pot, redeemable, "pot below redeemable");
            }
        }
    }

    /// The contract's real token balance backs the sum of every market's pot. No
    /// market's collateral can leak into another's accounting.
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_TokenBalanceBacksPots() public view {
        uint256 n = handler.allIdsLength();
        uint256 sumPots;
        for (uint256 i; i < n; i++) {
            sumPots += pm.collateralOf(handler.idAt(i));
        }
        assertGe(coll.balanceOf(address(pm)), sumPots, "token balance below pots");
    }
}
