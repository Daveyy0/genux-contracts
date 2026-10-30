// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IERC20Like {
    function transfer(address to, uint256 value) external returns (bool);
    function balanceOf(address who) external view returns (uint256);
}

/// @title GenuxTreasuryLock — 60,000,000 GNX held for Season 2 mining and incentives.
/// @notice No tokens can leave before the cliff; afterwards they unlock linearly to a
///         recipient chosen by the owner (normally the Season 2 mining distributor).
///         Scheduled, capped and public — not a promise, a constraint.
///
/// Example schedule (set at deploy):
///   start  = 2027-01-10 13:00 UTC
///   cliff  = 120 days  -> first release possible 10 May 2027
///   period = 365 days  -> fully unlocked 9 May 2028
contract GenuxTreasuryLock {
    address public immutable owner;
    uint256 public immutable start;
    uint256 public immutable cliff;
    uint256 public immutable period;
    uint256 public immutable totalAllocation;

    IERC20Like public token;
    address public pendingToken;
    address public recipient;
    uint256 public released;

    event TokenSet(address indexed token);
    event TokenProposed(address indexed token);
    event RecipientSet(address indexed recipient);
    event Released(address indexed to, uint256 amount);

    constructor(uint256 start_, uint256 cliff_, uint256 period_, uint256 totalAllocation_, address recipient_) {
        require(cliff_ > 0 && period_ > 0, "schedule");
        require(totalAllocation_ > 0, "amount");
        require(recipient_ != address(0), "recipient");
        owner = msg.sender;
        start = start_;
        cliff = cliff_;
        period = period_;
        totalAllocation = totalAllocation_;
        recipient = recipient_;
    }

    /// @notice Step 1 of 2: propose the token. Re-proposing overwrites (review M-6).
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

    /// @notice Point releases at the Season 2 distributor — but ONLY before the lock
    ///         starts. Once `start` is reached the recipient is frozen forever, so the
    ///         destination can never be repointed at a personal wallet later (M-5).
    function setRecipient(address r) external {
        require(msg.sender == owner, "not owner");
        require(block.timestamp < start, "recipient frozen");
        require(r != address(0), "zero");
        recipient = r;
        emit RecipientSet(r);
    }

    /// @notice True once the recipient can no longer be changed.
    function recipientFrozen() public view returns (bool) { return block.timestamp >= start; }

    function cliffEnd() public view returns (uint256) { return start + cliff; }
    function lockEnd() public view returns (uint256) { return start + cliff + period; }

    function unlockedAmount(uint256 t) public view returns (uint256) {
        if (t < cliffEnd()) return 0;
        if (t >= lockEnd()) return totalAllocation;
        return totalAllocation * (t - cliffEnd()) / period;
    }

    function unlockedNow() external view returns (uint256) { return unlockedAmount(block.timestamp); }

    function releasable() public view returns (uint256) {
        uint256 amount = unlockedAmount(block.timestamp);
        amount = amount > released ? amount - released : 0;
        uint256 bal = address(token) == address(0) ? 0 : token.balanceOf(address(this));
        return amount > bal ? bal : amount;
    }

    /// @notice Owner-only release of the unlocked portion to the current recipient.
    function release() external {
        require(msg.sender == owner, "not owner");
        require(address(token) != address(0), "token not set");
        uint256 amount = releasable();
        require(amount > 0, "nothing unlocked");
        released += amount;
        require(token.transfer(recipient, amount), "transfer failed");
        emit Released(recipient, amount);
    }
}
