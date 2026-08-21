# PredictionMarket

A factory of binary (**YES / NO**) prediction markets settled by the
**complete-set, full-collateral** model. One contract manages many independent
markets. Each market takes a question, an ERC-20 collateral token, a trusted
resolution oracle, and a trading deadline.

The contract guarantees **settlement, not pricing**. It never quotes a price and
holds no AMM. Price discovery for the individual YES/NO legs happens off-chain or
through a separate OTC desk; shares are freely transferable so those venues can
settle against this contract, which then guarantees that every winning share is
redeemable for collateral that is already in the pot.

## Why complete sets are always solvent

The only way collateral enters a market is `mintCompleteSet`: one collateral unit
mints **one complete set = 1 YES share + 1 NO share**. Burning a complete set
(`burnCompleteSet`) returns exactly one collateral. Therefore, at every moment
before resolution:

```
collateral held  ==  outstanding YES shares  ==  outstanding NO shares  ==  complete sets
```

Every share in existence is already backed one-for-one by collateral sitting in
the pot. Whatever the winning outcome, the total owed to winners equals the pot,
so the market can **always** pay every winner. This is the structural difference
from an AMM prediction market: an AMM prices shares against a bonded reserve and
can be drained or left unable to cover all winners under an adverse trade
sequence. Here there is no pricing surface to exploit — the invariant suite proves
no sequence of mint / burn / transfer / resolve / redeem can make a market
insolvent or let redemptions exceed collateral in.

## Lifecycle

1. `createMarket(question, collateral, oracle, tradingDeadline)` — anyone.
2. **Trading phase** (`block.timestamp < tradingDeadline`, unresolved):
   `mintCompleteSet`, `burnCompleteSet`, `transferShares`.
3. **Resolution** (`block.timestamp >= tradingDeadline`): the market's `oracle`
   calls `resolve(marketId, resolution)` exactly once.
4. **Redemption** (resolved): holders call `redeem(marketId)`.

`transferShares` is permitted at **any** time — including after the deadline and
after resolution — so winners can consolidate and OTC trades can settle late. It
only moves internal share bookkeeping; no collateral moves, so it can never affect
solvency.

### Trading gate (decision)

- `mintCompleteSet` / `burnCompleteSet`: **only before `tradingDeadline`** (and
  only while unresolved). Revert `TradingClosed` otherwise.
- `resolve`: **only at/after `tradingDeadline`** (`TradingStillOpen` before),
  once (`AlreadyResolved`), oracle-only (`NotOracle`).
- `redeem`: **only after resolution** (`NotResolved` before).
- `transferShares`: **always** allowed.

The deadline is a clean phase boundary: at exactly `tradingDeadline`, minting and
burning stop and resolution opens (no overlap).

## Resolution outcomes: YES / NO / INVALID

`resolve` accepts one of `Yes`, `No`, `Invalid` (never `Unresolved`). Redemption
uses payout numerators over a shared denominator:

| Resolution | YES share pays | NO share pays | complete set redeems to |
|------------|----------------|---------------|-------------------------|
| `Yes`      | `1`            | `0`           | `1`                     |
| `No`       | `0`            | `1`           | `1`                     |
| `Invalid`  | `1/2` (floor)  | `1/2` (floor) | `1`                     |

`redeem` pays `balance * numerator / denominator` per leg. Because a complete set
always redeems to exactly one collateral, collateral is conserved across any
resolution.

### INVALID rounding scheme

Shares are independently and divisibly transferable, so there is **no** on-chain
pairing of a YES holder with a NO holder. Under INVALID each leg pays
`floor(balance / 2)` — a floor on **both** legs. This is the only split that is
solvency-safe for freely-held fractional shares: a "YES floor, NO remainder"
scheme would pay `ceil` to NO holders and, with many odd-balance NO holders, could
sum to **more** than the pot. Flooring both legs guarantees total payout never
exceeds the pot; any odd-wei dust (from an odd share balance) stays in the pot,
i.e. **rounding always favours the market**. For the common case — a holder of a
whole complete set of even size — the split is exact (`n/2 + n/2 = n`). Callers who
need bit-exact INVALID redemption should mint even amounts.

## Oracle trust boundary

The `oracle` address supplied at creation is trusted for **exactly one thing**:
reporting the winning outcome, once, after the deadline. It has **no** path to
collateral beyond the defined redemption math — it cannot mint, burn, move anyone's
shares, seize the pot, resolve early, or resolve twice. Resolution is push-based:
the oracle can be a plain EOA or a contract that forwards a reported outcome via
`resolve` (see `IPredictionOracle` and the `MockResolver` test double). Choosing a
correct/honest oracle is the market creator's responsibility and is out of scope
for this contract.

Collateral is assumed to be a standard ERC-20: **no fee-on-transfer, no rebasing**.
`SafeERC20` is used throughout and `ReentrancyGuard` protects `mintCompleteSet`,
`burnCompleteSet`, and `redeem`.

## API

| Function | Notes |
|----------|-------|
| `createMarket(bytes32,IERC20,address,uint64) → uint256` | returns `marketId` |
| `mintCompleteSet(uint256,uint256)` | pull collateral, credit YES+NO |
| `burnCompleteSet(uint256,uint256)` | burn YES+NO, return collateral |
| `transferShares(uint256,uint8,address,uint256)` | move one leg, any time |
| `resolve(uint256,Resolution)` | oracle-only, once, post-deadline |
| `redeem(uint256) → uint256` | burn shares, pay out; returns payout |
| `marketInfo / sharesOf / totalSupplyOf / isResolved / winningOutcome / collateralOf / marketCount` | views |

Outcome indices: `YES = 0`, `NO = 1`.

## Invariants (proven)

Stateful, `runs = 64 × depth = 200 = 12,800` calls each, **0 reverts** under
`fail-on-revert = true` (pinned inline; the handler only issues must-succeed calls
and guards every `bound`), so the run is provably non-hollow (all five handler
selectors land thousands of successful calls):

- **`invariant_Solvency`** — before resolution `pot == YES supply == NO supply`;
  after resolution `pot >= redeemable value of outstanding winning shares`
  (INVALID: `pot >= floor(YES/2) + floor(NO/2)`). The market can always pay winners.
- **`invariant_ShareConservation`** — per market per outcome, the sum of holder
  balances equals tracked total supply; transfers move, mint/burn/redeem adjust.
- **`invariant_TokenBalanceBacksPots`** — the contract's real token balance backs
  the sum of every market's pot; one market's collateral never pays another.

## Tests

**47 tests** (44 unit/fuzz + 3 stateful invariants), all green. Coverage includes:
complete-set round-trips, directional exposure via mint-then-sell, YES/NO/INVALID
redemption, the INVALID odd-wei case, gating (early/late/twice/non-oracle resolve;
early / no-share / double redeem), transfer-then-recipient-redeems, multi-market
collateral isolation, reentrancy via a malicious collateral token on both `redeem`
and `burn`, and an arbitrary-sequence solvency script.

```bash
forge test
forge build --sizes
FOUNDRY_INVARIANT_FAIL_ON_REVERT=true forge test --match-path 'test/PredictionMarket.invariant.t.sol'
```

## Layout

```
src/PredictionMarket.sol            factory + Resolution enum + IPredictionOracle
test/PredictionMarket.t.sol         unit + fuzz
test/PredictionMarket.invariant.t.sol   stateful invariants (fail-on-revert)
test/mocks/Mocks.sol                MockERC20, MockResolver, ReentrantERC20
script/Deploy.s.sol                 deploys the factory (no args, no owner)
```

Toolchain: solc 0.8.26, `via_ir`, EVM `cancun`, OpenZeppelin v5.0.2.
