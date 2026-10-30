// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IGenuxMinerForMarket {
    function ownerOf(uint256 tokenId) external view returns (address);
    function transferFrom(address from, address to, uint256 tokenId) external;
    function isApprovedForAll(address owner, address operator) external view returns (bool);
    function getApproved(uint256 tokenId) external view returns (address);
    function royaltyInfo(uint256 tokenId, uint256 salePrice) external view returns (address, uint256);
}

interface IPancakeRouter {
    function swapExactETHForTokensSupportingFeeOnTransferTokens(
        uint256 amountOutMin, address[] calldata path, address to, uint256 deadline
    ) external payable;
}

/// @title GenuxMarket — built-in secondary market. Fees are charged in BNB and used to
///        support the GNX price: they accumulate here and are spent on buyback-and-burn.
/// @notice ERC-2981 royalties are advisory on third-party venues; sales here always pay
///         the fee because this contract settles the trade.
contract GenuxMarket {
    IGenuxMinerForMarket public immutable miner;
    address public immutable feeRecipient;   // fallback destination for withdrawFees()
    uint16 public immutable feeBps;
    IPancakeRouter public immutable router;
    address public immutable gnx;
    address public immutable wbnb;
    address public constant BURN = 0x000000000000000000000000000000000000dEaD;

    struct Listing { address seller; uint96 price; }
    mapping(uint256 => Listing) public listings;

    uint256 public accruedFees;      // BNB held for buyback
    uint256 public burnedTokens;     // GNX bought back and burned
    uint256 private _locked = 1;

    event Listed(uint256 indexed tokenId, address indexed seller, uint256 price);
    event Delisted(uint256 indexed tokenId);
    event Sold(uint256 indexed tokenId, address indexed seller, address indexed buyer, uint256 price, uint256 fee);
    event FeeAccrued(uint256 amount, uint256 total);
    event Buyback(uint256 bnbSpent, uint256 tokensBurned);
    event FeesWithdrawn(address indexed to, uint256 amount);

    modifier nonReentrant() {
        require(_locked == 1, "reentrant");
        _locked = 2;
        _;
        _locked = 1;
    }

    modifier onlyOwner() {
        require(msg.sender == feeRecipient, "not owner");
        _;
    }

    constructor(address miner_, address feeRecipient_, uint16 feeBps_, address router_, address gnx_, address wbnb_) {
        require(miner_ != address(0) && feeRecipient_ != address(0), "addr");
        require(feeBps_ <= 1000, "fee too high");
        require(router_ != address(0) && gnx_ != address(0) && wbnb_ != address(0), "addr");
        miner = IGenuxMinerForMarket(miner_);
        feeRecipient = feeRecipient_;
        feeBps = feeBps_;
        router = IPancakeRouter(router_);
        gnx = gnx_;
        wbnb = wbnb_;
    }

    // ---------- listings ----------
    /// @notice List or RE-LIST a miner. Re-listing overwrites price and seller.
    function list(uint256 tokenId, uint96 price) external {
        require(miner.ownerOf(tokenId) == msg.sender, "not owner");
        require(price > 0, "price");
        require(
            miner.isApprovedForAll(msg.sender, address(this)) || miner.getApproved(tokenId) == address(this),
            "approve market first"
        );
        listings[tokenId] = Listing(msg.sender, price);
        emit Listed(tokenId, msg.sender, price);
    }

    function cancel(uint256 tokenId) external {
        Listing memory l = listings[tokenId];
        require(l.seller == msg.sender, "not seller");
        delete listings[tokenId];
        emit Delisted(tokenId);
    }

    // ---------- trade ----------
    function buy(uint256 tokenId) external payable nonReentrant {
        Listing memory l = listings[tokenId];
        require(l.seller != address(0), "not listed");
        require(msg.value == l.price, "wrong value");

        uint256 fee = uint256(l.price) * feeBps / 10_000;
        (, uint256 royalty) = miner.royaltyInfo(tokenId, l.price);
        if (royalty > fee) fee = royalty;          // royalty above market fee wins
        require(fee < l.price, "fee too high");

        delete listings[tokenId];
        emit Sold(tokenId, l.seller, msg.sender, l.price, fee);

        miner.transferFrom(l.seller, msg.sender, tokenId);

        uint256 toSeller = uint256(l.price) - fee;
        (bool a, ) = payable(l.seller).call{value: toSeller}("");
        require(a, "seller payout failed");

        accruedFees += fee;
        emit FeeAccrued(fee, accruedFees);
    }

    // ---------- price support ----------
    /// @notice Spend accrued BNB fees on a GNX buyback and burn it. Anyone can trigger it,
    ///         but the money can only go to the fixed router path (WBNB -> GNX -> burn).
    function supportPrice(uint256 amount, uint256 minTokensOut, uint256 deadline) external nonReentrant {
        require(amount > 0 && amount <= accruedFees, "amount");
        require(deadline >= block.timestamp, "deadline");
        accruedFees -= amount;

        address[] memory path = new address[](2);
        path[0] = wbnb;
        path[1] = gnx;

        uint256 before_ = IERC20Min(gnx).balanceOf(BURN);
        router.swapExactETHForTokensSupportingFeeOnTransferTokens{value: amount}(minTokensOut, path, BURN, deadline);
        uint256 burned = IERC20Min(gnx).balanceOf(BURN) - before_;
        burnedTokens += burned;
        emit Buyback(amount, burned);
    }

    /// @notice Escape hatch: move accrued fees without buying back.
    function withdrawFees() external onlyOwner nonReentrant {
        uint256 amount = accruedFees;
        require(amount > 0, "nothing");
        accruedFees = 0;
        (bool ok, ) = payable(feeRecipient).call{value: amount}("");
        require(ok, "withdraw failed");
        emit FeesWithdrawn(feeRecipient, amount);
    }

    receive() external payable {}
}

interface IERC20Min {
    function balanceOf(address who) external view returns (uint256);
}
