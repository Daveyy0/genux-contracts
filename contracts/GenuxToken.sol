// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IUniRouter {
    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint256 amountIn, uint256 amountOutMin, address[] calldata path, address to, uint256 deadline
    ) external;
    function addLiquidityETH(
        address token, uint256 amountTokenDesired, uint256 amountTokenMin, uint256 amountETHMin,
        address to, uint256 deadline
    ) external payable returns (uint256 amountToken, uint256 amountETH, uint256 liquidity);
}

/// @title Genux (GNX) — 100,000,000 fixed supply with a 5% SELL tax that becomes liquidity.
/// @notice Tax applies only when GNX is sent to the LP pair or the router (i.e. an actual
///         sell). Wallet-to-wallet transfers, claims from the mining contract, distributions
///         from the locks/market and all internal liquidity operations are untaxed.
///         The collected 5% is converted into BNB and paired into the GNX/BNB pool by
///         `harvest()` — permissionless — which deepens liquidity instead of paying a wallet.
contract GenuxToken {
    string public name = "Genux";
    string public symbol = "GNX";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    address public immutable deployer;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    // ---- sell tax ----
    address public immutable pair;        // GNX/BNB pair: sells are taxed
    address public immutable router;      // sells routed through the router are taxed
    address public lpRecipient;           // receives the LP tokens created by harvest()
    bool public lpRecipientFrozen;        // freezes after the first harvest
    uint16 public sellFeeBps = 500;       // 5%
    uint256 public pendingFees;           // GNX awaiting harvest (held by this contract)
    uint256 public harvestedTokens;       // total GNX converted into liquidity
    mapping(address => bool) public isExempt;   // never taxed on either side

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    event SellTax(address indexed seller, uint256 gross, uint256 fee);
    event Harvested(uint256 tokensSwapped, uint256 bnbAdded, uint256 tokensAdded);
    event SellFeeChanged(uint16 bps);
    event LpRecipientChanged(address indexed recipient);

    modifier onlyDeployer() { require(msg.sender == deployer, "not deployer"); _; }

    constructor(
        address miningContract,   // 20,000,000 -> emission
        address poolWallet,       //    500,000 -> initial LP seed (pre-tax, exempt)
        address teamWallet,       // 19,500,000
        address treasuryWallet,   // 60,000,000
        address pair_,            // GNX/BNB pair (deterministic, see pair_address.py)
        address router_,          // PancakeSwap V2 router
        address lpRecipient_      // where harvested LP tokens go (lock or 0x…dEaD)
    ) {
        require(miningContract != address(0) && poolWallet != address(0), "addr");
        require(teamWallet != address(0) && treasuryWallet != address(0), "addr");
        require(pair_ != address(0) && router_ != address(0) && lpRecipient_ != address(0), "addr");
        deployer = msg.sender;
        pair = pair_;
        router = router_;
        lpRecipient = lpRecipient_;

        // internal, non-selling actors are exempt so claims/payouts/liquidity ops pay no tax
        isExempt[address(this)] = true;
        isExempt[miningContract] = true;
        isExempt[poolWallet] = true;
        isExempt[teamWallet] = true;
        isExempt[treasuryWallet] = true;
        // NOTE: the router is deliberately NOT exempt. Sells are taxed on the way OUT
        // (user -> pair/router). Harvest is safe because the *sender* is this contract,
        // which is exempt.
        isExempt[0x000000000000000000000000000000000000dEaD] = true;

        _mint(miningContract, 20_000_000 ether);
        _mint(poolWallet, 500_000 ether);
        _mint(teamWallet, 19_500_000 ether);
        _mint(treasuryWallet, 60_000_000 ether);
    }

    // ---------- owner ----------
    function setSellFee(uint16 bps) external onlyDeployer {
        require(bps <= 1000, "fee too high");     // hard cap 10%
        sellFeeBps = bps;
        emit SellFeeChanged(bps);
    }

    function setExempt(address who, bool exempt) external onlyDeployer {
        require(who != pair, "pair must stay taxable");
        isExempt[who] = exempt;
    }

    /// @notice Can only be changed BEFORE the first harvest; then frozen forever, so the
    ///         harvested liquidity can never be redirected afterwards.
    function setLpRecipient(address r) external onlyDeployer {
        require(!lpRecipientFrozen, "frozen");
        require(r != address(0), "zero");
        lpRecipient = r;
        emit LpRecipientChanged(r);
    }

    // ---------- transfers ----------
    function transfer(address to, uint256 value) external returns (bool) {
        _transfer(msg.sender, to, value);
        return true;
    }

    function approve(address spender, uint256 value) external returns (bool) {
        allowance[msg.sender][spender] = value;
        emit Approval(msg.sender, spender, value);
        return true;
    }

    function transferFrom(address from, address to, uint256 value) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        require(a >= value, "allowance");
        if (a != type(uint256).max) allowance[from][msg.sender] = a - value;
        _transfer(from, to, value);
        return true;
    }

    function _transfer(address from, address to, uint256 value) internal {
        require(to != address(0), "zero to");
        require(balanceOf[from] >= value, "balance");

        uint256 fee = 0;
        bool isSell = (to == pair || to == router) && !isExempt[from] && !isExempt[to];
        if (isSell && sellFeeBps > 0) {
            fee = value * sellFeeBps / 10_000;
        }

        unchecked { balanceOf[from] -= value; }
        if (fee > 0) {
            balanceOf[address(this)] += fee;      // held for harvest
            pendingFees += fee;
            emit SellTax(from, value, fee);
        }
        balanceOf[to] += value - fee;
        emit Transfer(from, to, value - fee);
        if (fee > 0) emit Transfer(from, address(this), fee);
    }

    function _mint(address to, uint256 value) internal {
        totalSupply += value;
        balanceOf[to] += value;
        emit Transfer(address(0), to, value);
    }

    // ---------- liquidity harvest ----------
    /// @notice Convert the collected sell tax into liquidity: half the GNX is swapped to
    ///         BNB, then GNX + BNB are paired and the LP tokens go to `lpRecipient`.
    ///         Permissionless — anyone can trigger it; nothing can be sent anywhere else.
    function harvest(uint256 minBnbOut, uint256 minTokensOut, uint256 minBnbAdd) external {
        uint256 amount = pendingFees;
        require(amount > 1, "nothing to harvest");
        pendingFees = 0;
        lpRecipientFrozen = true;         // destination is locked from the first harvest on
        harvestedTokens += amount;

        uint256 toSwap = amount / 2;
        uint256 toPair = amount - toSwap;

        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;   // WBNB

        // the router pulls the tokens, so this contract must approve it for both legs
        allowance[address(this)][router] = toSwap + toPair;

        uint256 bnbBefore = address(this).balance;
        IUniRouter(router).swapExactTokensForETHSupportingFeeOnTransferTokens(
            toSwap, minBnbOut, path, address(this), block.timestamp
        );
        uint256 bnbGained = address(this).balance - bnbBefore;

        IUniRouter(router).addLiquidityETH{value: bnbGained}(
            address(this), toPair, minTokensOut, minBnbAdd, lpRecipient, block.timestamp
        );
        allowance[address(this)][router] = 0;

        emit Harvested(toSwap, bnbGained, toPair);
    }

    receive() external payable {}
}
