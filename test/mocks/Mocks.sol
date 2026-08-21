// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {PredictionMarket, Resolution} from "../../src/PredictionMarket.sol";

/// @dev Plain mintable ERC-20 for happy-path tests.
contract MockERC20 is ERC20 {
    uint8 private immutable _dec;

    constructor(string memory n, string memory s, uint8 d) ERC20(n, s) {
        _dec = d;
    }

    function decimals() public view override returns (uint8) {
        return _dec;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev A trivial contract oracle: it forwards a stored outcome into the market's
///      push-based `resolve`. Demonstrates a contract resolver (vs an EOA) without
///      changing the trust model — the market only checks msg.sender == oracle.
contract MockResolver {
    PredictionMarket public immutable market;

    constructor(PredictionMarket _market) {
        market = _market;
    }

    function report(uint256 marketId, Resolution resolution) external {
        market.resolve(marketId, resolution);
    }
}

/// @dev Malicious collateral that re-enters the market mid-transfer. `arm` selects
///      which guarded entry point to call back into; the ReentrancyGuard must make
///      the outer call revert. Used to prove redeem/burn cannot be re-entered.
contract ReentrantERC20 is ERC20 {
    enum Mode {
        None,
        Redeem,
        Burn
    }

    PredictionMarket public market;
    Mode public mode;
    uint256 public marketId;
    uint256 public burnAmount;

    constructor() ERC20("Evil", "EVL") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function armRedeem(PredictionMarket m, uint256 id) external {
        market = m;
        marketId = id;
        mode = Mode.Redeem;
    }

    function armBurn(PredictionMarket m, uint256 id, uint256 amount) external {
        market = m;
        marketId = id;
        burnAmount = amount;
        mode = Mode.Burn;
    }

    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        Mode _mode = mode;
        if (_mode == Mode.None) return;
        mode = Mode.None; // fire once
        if (_mode == Mode.Redeem) {
            market.redeem(marketId); // must revert under nonReentrant
        } else {
            market.burnCompleteSet(marketId, burnAmount); // must revert under nonReentrant
        }
    }
}
