// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IERC20Like {
    function transfer(address to, uint256 value) external returns (bool);
    function balanceOf(address who) external view returns (uint256);
}

/// @title GenuxTeamVesting — 19,500,000 GNX locked for the team allocation.
/// @notice Cliff, then linear release. Beneficiary is fixed at deploy; the token
///         address is wired once. Every number below is a public getter, so the
///         schedule can be checked on-chain instead of being taken on trust.
///
/// Example schedule (set at deploy):
///   start  = listing day (10 Dec 2026 13:00 UTC)
///   cliff  = 180 days  -> nothing vests before 8 Jun 2027
///   period = 730 days  -> fully vested 8 Jun 2029
contract GenuxTeamVesting {
    address public immutable owner;
    address public immutable beneficiary;
    uint256 public immutable start;
    uint256 public immutable cliff;        // seconds
    uint256 public immutable period;       // seconds of linear vesting AFTER the cliff
    uint256 public immutable totalAllocation;

    IERC20Like public token;               // set once, via propose + confirm
    address public pendingToken;
    uint256 public released;

    event TokenSet(address indexed token);
    event TokenProposed(address indexed token);
    event Released(address indexed to, uint256 amount);

    constructor(address beneficiary_, uint256 start_, uint256 cliff_, uint256 period_, uint256 totalAllocation_) {
        require(beneficiary_ != address(0), "beneficiary");
        require(cliff_ > 0 && period_ > 0, "schedule");
        require(totalAllocation_ > 0, "amount");
        owner = msg.sender;
        beneficiary = beneficiary_;
        start = start_;
        cliff = cliff_;
        period = period_;
        totalAllocation = totalAllocation_;
    }

    /// @notice Step 1 of 2: propose the GNX token. Re-proposing overwrites (review M-6).
    function proposeToken(address token_) external {
        require(msg.sender == owner, "not owner");
        require(address(token) == address(0), "already set");
        require(token_ != address(0), "zero");
        pendingToken = token_;
        emit TokenProposed(token_);
    }

    /// @notice Step 2 of 2: commit. Irreversible.
    function confirmToken() external {
        require(msg.sender == owner, "not owner");
        require(address(token) == address(0), "already set");
        require(pendingToken != address(0), "nothing proposed");
        token = IERC20Like(pendingToken);
        emit TokenSet(pendingToken);
    }

    function cancelTokenProposal() external {
        require(msg.sender == owner, "not owner");
        pendingToken = address(0);
    }

    /// @notice Unix time at which anything at all starts vesting.
    function cliffEnd() public view returns (uint256) { return start + cliff; }

    /// @notice Unix time at which the allocation is fully vested.
    function vestEnd() public view returns (uint256) { return start + cliff + period; }

    /// @notice How much of the allocation has vested by `t`.
    function vestedAmount(uint256 t) public view returns (uint256) {
        if (t < cliffEnd()) return 0;
        if (t >= vestEnd()) return totalAllocation;
        return totalAllocation * (t - cliffEnd()) / period;
    }

    function vestedNow() external view returns (uint256) { return vestedAmount(block.timestamp); }

    function unreleased() public view returns (uint256) {
        uint256 v = vestedAmount(block.timestamp);
        return v > released ? v - released : 0;
    }

    /// @notice Amount currently claimable, capped by the tokens actually held here.
    function releasable() public view returns (uint256) {
        uint256 amount = unreleased();
        uint256 bal = address(token) == address(0) ? 0 : token.balanceOf(address(this));
        return amount > bal ? bal : amount;
    }

    /// @notice Send vested tokens to the beneficiary. Callable by anyone (it can only
    ///         ever pay the fixed beneficiary).
    function release() external {
        require(address(token) != address(0), "token not set");
        uint256 amount = releasable();
        require(amount > 0, "nothing vested");
        released += amount;
        require(token.transfer(beneficiary, amount), "transfer failed");
        emit Released(beneficiary, amount);
    }
}
