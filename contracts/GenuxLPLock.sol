// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IERC20Like {
    function transfer(address to, uint256 value) external returns (bool);
    function balanceOf(address who) external view returns (uint256);
}

/// @title GenuxLPLock — locks the GNX/BNB PancakeSwap LP tokens for a published term.
/// @notice Deployed before the pool is created so the lock address can be published in
///         advance. Once the pair exists, the LP tokens are sent here and cannot leave
///         before `unlockTime`. The owner can only ever EXTEND the lock, never shorten it.
///
/// Published term used for Genux: 12 months from listing
///   start      = 10 Dec 2026 13:00 UTC (1796907600)
///   unlockTime = 10 Dec 2027 13:00 UTC (1828443600)
contract GenuxLPLock {
    address public immutable owner;
    address public immutable pair;          // GNX/BNB pair address (fixed at deploy)
    address public immutable beneficiary;   // receives the LP after unlock
    uint256 public immutable start;
    uint256 public unlockTime;
    uint256 public released;

    IERC20Like public lpToken;              // set once via propose + confirm
    address public pendingLpToken;
    bool public funded;

    event LpTokenSet(address indexed token);
    event LpTokenProposed(address indexed token);
    event LockExtended(uint256 newUnlockTime);
    event Funded(uint256 amount);
    event Released(address indexed to, uint256 amount);

    constructor(address pair_, address beneficiary_, uint256 start_, uint256 unlockTime_) {
        require(pair_ != address(0), "pair");
        require(beneficiary_ != address(0), "beneficiary");
        require(unlockTime_ > start_, "term");
        owner = msg.sender;
        pair = pair_;
        beneficiary = beneficiary_;
        start = start_;
        unlockTime = unlockTime_;
    }

    /// @notice Step 1 of 2: propose the LP token. Must be the pair fixed at deploy;
    ///         re-proposing overwrites, so a typo can be corrected (review M-6).
    function proposeLpToken(address token_) external {
        require(msg.sender == owner, "not owner");
        require(address(lpToken) == address(0), "already set");
        require(token_ == pair, "not the pair");
        pendingLpToken = token_;
        emit LpTokenProposed(token_);
    }

    /// @notice Step 2 of 2: commit. Irreversible.
    function confirmLpToken() external {
        require(msg.sender == owner, "not owner");
        require(address(lpToken) == address(0), "already set");
        require(pendingLpToken != address(0), "nothing proposed");
        lpToken = IERC20Like(pendingLpToken);
        emit LpTokenSet(pendingLpToken);
    }

    function cancelLpTokenProposal() external {
        require(msg.sender == owner, "not owner");
        pendingLpToken = address(0);
    }

    /// @notice Extend the lock. Can only move the unlock date later.
    function extendLock(uint256 newUnlockTime) external {
        require(msg.sender == owner, "not owner");
        require(newUnlockTime > unlockTime, "can only extend");
        unlockTime = newUnlockTime;
        emit LockExtended(newUnlockTime);
    }

    /// @notice Record that LP tokens were sent here (call after adding liquidity).
    function markFunded() external {
        require(msg.sender == owner, "not owner");
        require(address(lpToken) != address(0), "lp not set");
        funded = true;
        emit Funded(lpToken.balanceOf(address(this)));
    }

    function lockedAmount() public view returns (uint256) {
        if (address(lpToken) == address(0)) return 0;
        return lpToken.balanceOf(address(this));
    }

    function isUnlocked() public view returns (bool) { return block.timestamp >= unlockTime; }

    function remaining() external view returns (uint256) { return lockedAmount(); }

    /// @notice LP is releasable only once the published term has ended.
    function releasable() public view returns (uint256) {
        if (!isUnlocked()) return 0;
        return lockedAmount();
    }

    /// @notice Releases the LP tokens to the fixed beneficiary after unlockTime.
    ///         Callable by anyone — it can only ever pay `beneficiary`.
    function release() external {
        require(isUnlocked(), "still locked");
        uint256 amount = lockedAmount();
        require(amount > 0, "nothing to release");
        released += amount;
        require(lpToken.transfer(beneficiary, amount), "transfer failed");
        emit Released(beneficiary, amount);
    }
}
