// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @notice How a market settled. `Unresolved` is the pre-resolution sentinel and is
///         never a valid argument to `resolve`.
enum Resolution {
    Unresolved,
    Yes,
    No,
    Invalid
}

/// @notice Optional interface a resolver contract MAY implement. This contract's
///         resolution is push-based — the stored `oracle` address calls `resolve`
///         directly — so an oracle can be a plain EOA or a contract that forwards a
///         reported outcome here. The interface exists to document that shape.
interface IPredictionOracle {
    function resolvePredictionMarket(uint256 marketId) external view returns (Resolution);
}

/// @title  PredictionMarket
/// @notice A factory of binary (YES/NO) prediction markets settled by the
///         complete-set, full-collateral model.
///
/// @dev    Model. One collateral unit mints one complete set = 1 YES share + 1 NO
///         share (`mintCompleteSet`); burning a complete set returns one collateral
///         (`burnCompleteSet`). Therefore, at all times before resolution:
///
///             collateral held == outstanding YES == outstanding NO == complete sets.
///
///         Shares are transferable, so directional exposure and a secondary market
///         are expressed by trading the individual legs (this contract guarantees
///         settlement, not pricing — price discovery is off-chain / an OTC desk).
///         Because every share is fully backed by collateral already in the pot, the
///         market can ALWAYS pay every winner: unlike an AMM market it can never
///         become insolvent regardless of the trade sequence.
///
///         Trust boundary. The `oracle` address supplied at creation is trusted for
///         exactly one thing: reporting the winning outcome, once, after the trading
///         deadline. It has NO path to collateral beyond the defined redemption math
///         and cannot mint, burn, move shares, or seize the pot.
contract PredictionMarket is ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @dev Outcome indices for the two share legs.
    uint8 public constant YES = 0;
    uint8 public constant NO = 1;

    struct Market {
        bytes32 question;
        IERC20 collateral;
        address oracle;
        uint64 tradingDeadline;
        bool resolved;
        Resolution resolution;
        uint256 pot; // collateral held for this market (accounting balance)
        uint256 supplyYes; // total YES shares in existence
        uint256 supplyNo; // total NO shares in existence
    }

    Market[] private _markets;

    /// @dev marketId => outcome => holder => share balance.
    mapping(uint256 => mapping(uint8 => mapping(address => uint256))) private _shares;

    event MarketCreated(
        uint256 indexed marketId,
        bytes32 question,
        address indexed collateral,
        address indexed oracle,
        uint64 tradingDeadline
    );
    event CompleteSetMinted(uint256 indexed marketId, address indexed account, uint256 amount);
    event CompleteSetBurned(uint256 indexed marketId, address indexed account, uint256 amount);
    event SharesTransferred(
        uint256 indexed marketId, uint8 indexed outcome, address indexed from, address to, uint256 amount
    );
    event MarketResolved(uint256 indexed marketId, Resolution resolution);
    event Redeemed(uint256 indexed marketId, address indexed account, uint256 payout);

    error ZeroAddress();
    error InvalidDeadline();
    error UnknownMarket();
    error ZeroAmount();
    error InvalidOutcome();
    error TradingClosed();
    error TradingStillOpen();
    error AlreadyResolved();
    error NotResolved();
    error NotOracle();
    error BadResolution();
    error InsufficientShares();

    modifier marketExists(uint256 marketId) {
        if (marketId >= _markets.length) revert UnknownMarket();
        _;
    }

    // --------------------------------------------------------------------- //
    //                               Creation                                //
    // --------------------------------------------------------------------- //

    /// @notice Create a new binary market.
    /// @param question         Opaque identifier / hash of the market question.
    /// @param collateral       ERC-20 used to mint sets and pay redemptions. Assumed
    ///                         standard: no fee-on-transfer and no rebasing.
    /// @param oracle           Address trusted to report the winning outcome.
    /// @param tradingDeadline  Timestamp at which minting/burning stops and resolution
    ///                         opens. Must be strictly in the future.
    function createMarket(bytes32 question, IERC20 collateral, address oracle, uint64 tradingDeadline)
        external
        returns (uint256 marketId)
    {
        if (address(collateral) == address(0) || oracle == address(0)) revert ZeroAddress();
        if (tradingDeadline <= block.timestamp) revert InvalidDeadline();

        marketId = _markets.length;
        _markets.push(
            Market({
                question: question,
                collateral: collateral,
                oracle: oracle,
                tradingDeadline: tradingDeadline,
                resolved: false,
                resolution: Resolution.Unresolved,
                pot: 0,
                supplyYes: 0,
                supplyNo: 0
            })
        );
        emit MarketCreated(marketId, question, address(collateral), oracle, tradingDeadline);
    }

    // --------------------------------------------------------------------- //
    //                        Complete-set mint / burn                       //
    // --------------------------------------------------------------------- //

    /// @notice Pull `amount` collateral and credit the caller `amount` YES AND
    ///         `amount` NO shares. Allowed only while trading is open (before the
    ///         deadline and before resolution).
    function mintCompleteSet(uint256 marketId, uint256 amount) external nonReentrant marketExists(marketId) {
        if (amount == 0) revert ZeroAmount();
        Market storage m = _markets[marketId];
        if (m.resolved || block.timestamp >= m.tradingDeadline) revert TradingClosed();

        m.pot += amount;
        m.supplyYes += amount;
        m.supplyNo += amount;
        _shares[marketId][YES][msg.sender] += amount;
        _shares[marketId][NO][msg.sender] += amount;

        m.collateral.safeTransferFrom(msg.sender, address(this), amount);
        emit CompleteSetMinted(marketId, msg.sender, amount);
    }

    /// @notice Burn `amount` YES AND `amount` NO shares from the caller and return
    ///         `amount` collateral. Allowed only while trading is open.
    function burnCompleteSet(uint256 marketId, uint256 amount) external nonReentrant marketExists(marketId) {
        if (amount == 0) revert ZeroAmount();
        Market storage m = _markets[marketId];
        if (m.resolved || block.timestamp >= m.tradingDeadline) revert TradingClosed();
        if (_shares[marketId][YES][msg.sender] < amount || _shares[marketId][NO][msg.sender] < amount) {
            revert InsufficientShares();
        }

        _shares[marketId][YES][msg.sender] -= amount;
        _shares[marketId][NO][msg.sender] -= amount;
        m.supplyYes -= amount;
        m.supplyNo -= amount;
        m.pot -= amount;

        m.collateral.safeTransfer(msg.sender, amount);
        emit CompleteSetBurned(marketId, msg.sender, amount);
    }

    // --------------------------------------------------------------------- //
    //                             Share transfer                            //
    // --------------------------------------------------------------------- //

    /// @notice Move `amount` shares of one outcome to `to`. Permitted at ANY time,
    ///         including after the deadline and after resolution, so winners can
    ///         consolidate and an off-chain / OTC market can settle. Purely internal
    ///         bookkeeping — no collateral moves — so it never affects solvency.
    function transferShares(uint256 marketId, uint8 outcome, address to, uint256 amount)
        external
        marketExists(marketId)
    {
        if (outcome > NO) revert InvalidOutcome();
        if (to == address(0)) revert ZeroAddress();

        uint256 bal = _shares[marketId][outcome][msg.sender];
        if (bal < amount) revert InsufficientShares();
        unchecked {
            _shares[marketId][outcome][msg.sender] = bal - amount;
        }
        _shares[marketId][outcome][to] += amount;
        emit SharesTransferred(marketId, outcome, msg.sender, to, amount);
    }

    // --------------------------------------------------------------------- //
    //                              Resolution                               //
    // --------------------------------------------------------------------- //

    /// @notice Report the winning outcome. Callable once, only by the market's
    ///         oracle, only at/after the trading deadline. Irreversible.
    /// @param resolution One of Yes, No, Invalid (never Unresolved).
    function resolve(uint256 marketId, Resolution resolution) external marketExists(marketId) {
        if (resolution == Resolution.Unresolved) revert BadResolution();
        Market storage m = _markets[marketId];
        if (msg.sender != m.oracle) revert NotOracle();
        if (block.timestamp < m.tradingDeadline) revert TradingStillOpen();
        if (m.resolved) revert AlreadyResolved();

        m.resolved = true;
        m.resolution = resolution;
        emit MarketResolved(marketId, resolution);
    }

    // --------------------------------------------------------------------- //
    //                              Redemption                               //
    // --------------------------------------------------------------------- //

    /// @notice Burn the caller's shares in a resolved market and pay out collateral.
    ///         YES-win: each YES redeems 1, each NO redeems 0. NO-win: mirror.
    ///         Invalid: each share of EITHER leg redeems 1/2, floored. Losing (and
    ///         Invalid-dust) shares are burned for their computed value, so a second
    ///         redeem by the same account reverts — no double-redeem.
    /// @dev    Rounding always favours the market (floor); redemptions can never
    ///         exceed the pot. See README for the Invalid split's exact accounting.
    function redeem(uint256 marketId) external nonReentrant marketExists(marketId) returns (uint256 payout) {
        Market storage m = _markets[marketId];
        if (!m.resolved) revert NotResolved();

        (uint256 numYes, uint256 numNo, uint256 den) = _payoutNumerators(m.resolution);

        uint256 balYes = _shares[marketId][YES][msg.sender];
        uint256 balNo = _shares[marketId][NO][msg.sender];
        if (balYes == 0 && balNo == 0) revert InsufficientShares();

        if (balYes != 0) {
            _shares[marketId][YES][msg.sender] = 0;
            m.supplyYes -= balYes;
            payout += balYes * numYes / den;
        }
        if (balNo != 0) {
            _shares[marketId][NO][msg.sender] = 0;
            m.supplyNo -= balNo;
            payout += balNo * numNo / den;
        }

        m.pot -= payout;
        if (payout != 0) m.collateral.safeTransfer(msg.sender, payout);
        emit Redeemed(marketId, msg.sender, payout);
    }

    /// @dev Payout numerators per leg and the shared denominator for a resolution.
    ///      Yes: (1,0)/1 · No: (0,1)/1 · Invalid: (1,1)/2. A complete set therefore
    ///      always redeems to exactly one collateral (Invalid: 1/2 + 1/2).
    function _payoutNumerators(Resolution r) internal pure returns (uint256 numYes, uint256 numNo, uint256 den) {
        if (r == Resolution.Yes) return (1, 0, 1);
        if (r == Resolution.No) return (0, 1, 1);
        return (1, 1, 2); // Invalid
    }

    // --------------------------------------------------------------------- //
    //                                 Views                                 //
    // --------------------------------------------------------------------- //

    function marketCount() external view returns (uint256) {
        return _markets.length;
    }

    function marketInfo(uint256 marketId) external view marketExists(marketId) returns (Market memory) {
        return _markets[marketId];
    }

    function sharesOf(uint256 marketId, uint8 outcome, address holder) external view returns (uint256) {
        return _shares[marketId][outcome][holder];
    }

    function totalSupplyOf(uint256 marketId, uint8 outcome) external view marketExists(marketId) returns (uint256) {
        Market storage m = _markets[marketId];
        return outcome == YES ? m.supplyYes : m.supplyNo;
    }

    function isResolved(uint256 marketId) external view marketExists(marketId) returns (bool) {
        return _markets[marketId].resolved;
    }

    /// @notice The winning outcome of a resolved market. Reverts if not yet resolved.
    function winningOutcome(uint256 marketId) external view marketExists(marketId) returns (Resolution) {
        Market storage m = _markets[marketId];
        if (!m.resolved) revert NotResolved();
        return m.resolution;
    }

    /// @notice Collateral currently held for a market (its pot).
    function collateralOf(uint256 marketId) external view marketExists(marketId) returns (uint256) {
        return _markets[marketId].pot;
    }
}
