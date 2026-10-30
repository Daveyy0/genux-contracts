// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IGenuxMiner {
    function weightOfWallet(address wallet) external view returns (uint256);
}

interface IGenuxToken {
    function transfer(address to, uint256 value) external returns (bool);
}

/// @title GenuxMining — Season 1: 20,000,000 GNX over 90 days, split by NFT weight.
/// @notice Weight is authoritative in the NFT contract and pushed here through
///         `onWeightChange` on every mint, level-up and transfer, so weight can never
///         be double-counted (review H-1) and reads are O(1) (review M-1).
contract GenuxMining {
    IGenuxMiner public immutable miner;
    IGenuxToken public token;          // set once, after the token is deployed
    address public immutable owner;

    uint256 public immutable start;
    uint256 public immutable end;
    uint256 public constant EMISSION = 20_000_000 ether;

    uint256 public accPerWeight;       // GNX per weight unit, scaled 1e18
    uint256 public totalWeight;        // authoritative sum of tracked wallet weights
    uint256 public lastUpdate;
    uint256 public claimedTotal;

    mapping(address => uint256) public weightTracked;   // weight recorded at last change
    mapping(address => uint256) public accSnap;         // accPerWeight at last settle
    mapping(address => uint256) public pendingStored;   // settled but unclaimed GNX
    address public pendingToken;                        // proposed token awaiting confirmation

    event WeightChanged(address indexed from, address indexed to, uint256 totalWeight);
    event Claimed(address indexed wallet, uint256 amount);
    event TokenSet(address indexed token);
    event TokenProposed(address indexed token);

    modifier onlyMiner() { require(msg.sender == address(miner), "only miner"); _; }

    constructor(address miner_, uint256 start_) {
        require(start_ > block.timestamp, "start in past");
        require(miner_ != address(0), "miner");
        owner = msg.sender;
        miner = IGenuxMiner(miner_);
        start = start_;
        end = start_ + 90 days;
        lastUpdate = start_;
    }

    /// @notice Step 1 of 2: propose the GNX token address. Re-proposing overwrites, so a
    ///         typo can be corrected before anything is committed (review M-6).
    function proposeToken(address token_) external {
        require(msg.sender == owner, "not owner");
        require(address(token) == address(0), "already set");
        require(token_ != address(0), "zero");
        pendingToken = token_;
        emit TokenProposed(token_);
    }

    /// @notice Step 2 of 2: commit the proposed address. Irreversible once confirmed.
    function confirmToken() external {
        require(msg.sender == owner, "not owner");
        require(address(token) == address(0), "already set");
        require(pendingToken != address(0), "nothing proposed");
        token = IGenuxToken(pendingToken);
        emit TokenSet(pendingToken);
    }

    /// @notice Drop a pending proposal that has not been confirmed.
    function cancelTokenProposal() external {
        require(msg.sender == owner, "not owner");
        pendingToken = address(0);
    }

    function emittedBetween(uint256 from, uint256 to) public view returns (uint256) {
        if (to <= from) return 0;
        uint256 f = from < start ? start : from;
        uint256 t = to > end ? end : to;
        if (t <= f) return 0;
        return EMISSION * (t - f) / (end - start);
    }

    function _accrue() internal {
        uint256 t = block.timestamp;
        if (t <= lastUpdate) return;
        uint256 from = lastUpdate < start ? start : lastUpdate;
        uint256 to = t > end ? end : t;
        if (to > from && totalWeight > 0) {
            accPerWeight += emittedBetween(from, to) * 1e18 / totalWeight;
        }
        lastUpdate = t;
    }

    /// @notice Move a wallet's accrued-but-unsettled GNX into storage, at its
    ///         currently tracked weight, then re-base its accumulator snapshot.
    function _settle(address wallet) internal {
        if (wallet == address(0)) return;
        uint256 w = weightTracked[wallet];
        if (w > 0) {
            pendingStored[wallet] += w * (accPerWeight - accSnap[wallet]) / 1e18;
        }
        accSnap[wallet] = accPerWeight;
    }

    /// @notice Hook called by the NFT contract whenever weight moves.
    /// @dev Called AFTER the miner has updated its own counters, so the new weights
    ///      are read from the miner and the old ones come from `weightTracked`.
    function onWeightChange(address from, address to) external onlyMiner {
        _accrue();
        _settle(from);
        _settle(to);

        if (from == to) {
            // single-wallet update (mint, or level-up where owner == owner)
            uint256 oldW = from == address(0) ? 0 : weightTracked[from];
            uint256 newW = from == address(0) ? 0 : miner.weightOfWallet(from);
            if (newW >= oldW) {
                totalWeight += newW - oldW;
            } else {
                require(totalWeight >= oldW - newW, "weight underflow");
                totalWeight -= oldW - newW;
            }
            if (from != address(0)) weightTracked[from] = newW;
        } else {
            uint256 oldFrom = from == address(0) ? 0 : weightTracked[from];
            uint256 oldTo = to == address(0) ? 0 : weightTracked[to];
            uint256 newFrom = from == address(0) ? 0 : miner.weightOfWallet(from);
            uint256 newTo = to == address(0) ? 0 : miner.weightOfWallet(to);
            require(totalWeight + newFrom + newTo >= oldFrom + oldTo, "weight underflow");
            totalWeight = totalWeight - oldFrom - oldTo + newFrom + newTo;
            if (from != address(0)) weightTracked[from] = newFrom;
            if (to != address(0)) weightTracked[to] = newTo;
        }

        emit WeightChanged(from, to, totalWeight);
    }

    function pending(address wallet) public view returns (uint256) {
        uint256 acc = accPerWeight;
        uint256 t = block.timestamp;
        uint256 from = lastUpdate < start ? start : lastUpdate;
        uint256 to = t > end ? end : t;
        if (to > from && totalWeight > 0) {
            acc += emittedBetween(from, to) * 1e18 / totalWeight;
        }
        uint256 w = weightTracked[wallet];
        return pendingStored[wallet] + (w > 0 ? w * (acc - accSnap[wallet]) / 1e18 : 0);
    }

    function claim() external {
        _accrue();
        _settle(msg.sender);                       // live accrual -> pendingStored
        uint256 total = pendingStored[msg.sender]; // now everything owed
        pendingStored[msg.sender] = 0;
        if (total > 0) {
            claimedTotal += total;
            require(address(token) != address(0), "token not set");
            require(token.transfer(msg.sender, total), "transfer failed");
            emit Claimed(msg.sender, total);
        }
    }
}
