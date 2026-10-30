// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IWeightSink {
    function onWeightChange(address from, address to) external;
}

/// @dev SPACE ID .ai Agent ID registry on BSC — only its balanceOf is used.
interface IAgentRegistry {
    function balanceOf(address owner) external view returns (uint256);
}

/// @title Genux Miner — 10,000 NFTs, mint, 3 levels, weight that moves with the token.
/// @notice O(1) per-wallet weight counter + a hook into the mining contract, so weight
///         always follows ownership. Fixes review findings H-1 and M-1.
contract GenuxMiner {
    string public name = "Genux Miner";
    string public symbol = "GNXM";
    uint256 public constant MAX_SUPPLY = 10_000;
    uint256 public constant MAX_PER_WALLET = 5;
    uint8 public constant MAX_LEVEL = 3;

    /// @notice 1,000 of the 10,000 supply are mintable FREE by .ai Agent ID holders.
    uint256 public constant FREE_SUPPLY = 1_000;
    /// @notice SPACE ID registry: balanceOf(wallet) > 0 means "has an .ai Agent ID".
    /// @dev Immutable, set at deploy to 0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F
    ///      on BSC mainnet (a mock is passed in tests).
    IAgentRegistry public immutable agentRegistry;

    uint256 public freeMinted;                 // how many of the 1,000 are gone
    mapping(address => bool) public freeUsed;  // 1 free per wallet

    address public owner;
    address public feeRecipient;
    address public mining;               // set once; receives onWeightChange hooks
    uint256 public mintPrice;            // wei
    mapping(uint8 => uint256) public levelPrices;   // levelPrices[2], levelPrices[3]
    bool public mintOpen;

    /// @notice ERC-2981 royalty: percentage of every sale paid to `feeRecipient`.
    uint16 public royaltyBps = 500;      // 5% default, cap 1000 (10%)

    uint256 public totalSupply;
    mapping(uint256 => address) public ownerOf;
    mapping(address => uint256) public balanceOf;
    mapping(address => uint256) public mintedBy;
    mapping(uint256 => uint8) public levelOf;
    /// @notice Art base, set once in the constructor. Solidity forbids `immutable` on
    ///         strings, so the guarantee is structural: there is NO setter and no
    ///         upgrade path, so the value can never change (review M-3).
    string internal _baseURI;

    /// @notice O(1) aggregate weight per wallet (review M-1).
    mapping(address => uint256) public weightOfWallet;

    mapping(uint256 => address) public getApproved;
    mapping(address => mapping(address => bool)) public isApprovedForAll;

    mapping(address => uint256[]) internal _owned;
    mapping(uint256 => uint256) internal _ownedIndex;

    event Transfer(address indexed from, address indexed to, uint256 indexed tokenId);
    event Approval(address indexed owner, address indexed approved, uint256 indexed tokenId);
    event ApprovalForAll(address indexed owner, address indexed operator, bool approved);
    event Minted(address indexed to, uint256 indexed tokenId, uint8 level);
    event LevelUp(uint256 indexed tokenId, uint8 newLevel, uint256 paid);
    event MiningSet(address indexed mining);
    event MintPriceChanged(uint256 price);
    event LevelPricesChanged(uint256 toLv2, uint256 toLv3);
    event FeeRecipientChanged(address indexed recipient);
    event FreeMinted(address indexed to, uint256 indexed tokenId);
    event RoyaltyChanged(uint16 bps);

    modifier onlyOwner() { require(msg.sender == owner, "not owner"); _; }

    constructor(
        address feeRecipient_,
        uint256 mintPrice_,
        uint256 priceToLv2_,
        uint256 priceToLv3_,
        string memory baseURI_,
        address agentRegistry_
    ) {
        require(agentRegistry_ != address(0), "registry");
        require(bytes(baseURI_).length > 0, "baseURI");
        require(feeRecipient_ != address(0), "fee recipient");
        owner = msg.sender;
        feeRecipient = feeRecipient_;
        mintPrice = mintPrice_;
        levelPrices[2] = priceToLv2_;
        levelPrices[3] = priceToLv3_;
        _baseURI = baseURI_;   // written once; no function can ever change it
        agentRegistry = IAgentRegistry(agentRegistry_);
    }

    // ---------- owner ----------
    function setMintOpen(bool v) external onlyOwner { mintOpen = v; }

    /// @notice One-time wiring of the mining contract that receives weight hooks.
    function setMining(address mining_) external onlyOwner {
        require(mining == address(0), "already set");
        require(mining_ != address(0), "zero");
        mining = mining_;
        emit MiningSet(mining_);
    }

    function setMintPrice(uint256 mintPrice_) external onlyOwner {
        require(mintPrice_ <= 0.01 ether, "price too high");     // review M-4 bound
        mintPrice = mintPrice_;
        emit MintPriceChanged(mintPrice_);
    }

    function setLevelPrices(uint256 priceToLv2_, uint256 priceToLv3_) external onlyOwner {
        require(priceToLv2_ <= 0.01 ether && priceToLv3_ <= 0.01 ether, "price too high");
        levelPrices[2] = priceToLv2_;
        levelPrices[3] = priceToLv3_;
        emit LevelPricesChanged(priceToLv2_, priceToLv3_);
    }

    function setFeeRecipient(address r) external onlyOwner {
        require(r != address(0), "zero");
        feeRecipient = r;
        emit FeeRecipientChanged(r);
    }

    function withdraw() external onlyOwner {
        (bool ok, ) = payable(feeRecipient).call{value: address(this).balance}("");
        require(ok, "withdraw failed");
    }

    // ---------- mint / level ----------
    function mint(uint256 qty) external payable {
        require(mintOpen, "mint closed");
        require(qty > 0 && qty <= MAX_PER_WALLET, "qty");
        require(totalSupply + qty <= MAX_SUPPLY, "sold out");
        require(mintedBy[msg.sender] + qty <= MAX_PER_WALLET, "wallet cap");
        require(msg.value == qty * mintPrice, "wrong value");

        mintedBy[msg.sender] += qty;
        for (uint256 i = 0; i < qty; i++) {
            uint256 id = _mintOne(msg.sender);
            emit Minted(msg.sender, id, 1);
        }
        _notifyWeight(address(0), msg.sender);   // weight already counted by _mintOne
    }

    /// @dev Creates one Lv1 miner; caller is responsible for counters and the weight hook.
    function _mintOne(address to) internal returns (uint256 id) {
        id = ++totalSupply;
        ownerOf[id] = to;
        balanceOf[to] += 1;
        levelOf[id] = 1;
        _owned[to].push(id);
        _ownedIndex[id] = _owned[to].length - 1;
        emit Transfer(address(0), to, id);
        weightOfWallet[to] += 1;                 // Lv1 weight = 1
    }

    function costToLevel(uint256 tokenId, uint8 targetLevel) public view returns (uint256 cost) {
        require(targetLevel <= MAX_LEVEL && targetLevel >= 1, "bad level");
        uint8 cur = levelOf[tokenId];
        require(targetLevel > cur, "already there");
        for (uint8 lv = cur + 1; lv <= targetLevel; lv++) cost += levelPrices[lv];
    }

    function levelUp(uint256 tokenId, uint8 targetLevel) external payable {
        require(ownerOf[tokenId] == msg.sender, "not owner");
        uint256 cost = costToLevel(tokenId, targetLevel);
        require(msg.value == cost, "wrong value");
        uint256 before = weightOf(tokenId);
        levelOf[tokenId] = targetLevel;
        uint256 after_ = weightOf(tokenId);
        weightOfWallet[msg.sender] = weightOfWallet[msg.sender] - before + after_;
        emit LevelUp(tokenId, targetLevel, msg.value);
        _notifyWeight(msg.sender, msg.sender);
    }

    /// @notice Mining weight: Lv1 = 1, Lv2 = 2, Lv3 = 4.
    function weightOf(uint256 tokenId) public view returns (uint256) {
        uint8 lv = levelOf[tokenId];
        if (lv >= 3) return 4;
        if (lv == 2) return 2;
        if (lv == 1) return 1;
        return 0;
    }

    function tokensOf(address wallet) external view returns (uint256[] memory) { return _owned[wallet]; }

    /// @notice The art base. Fixed at deploy; there is no setter.
    function baseURI() external view returns (string memory) { return _baseURI; }

    /// @notice Deterministic: baseURI + token id + ".json". Cannot be changed.
    /// @dev Fixed 2026-10-30: the GitHub Pages metadata files are named 1.json,
    ///      2.json, etc., so without the ".json" suffix tokenURI() returned a 404 URL.
    function tokenURI(uint256 tokenId) public view returns (string memory) {
        require(ownerOf[tokenId] != address(0), "no token");
        return string.concat(_baseURI, _toString(tokenId), ".json");
    }

    function _toString(uint256 v) internal pure returns (string memory) {
        if (v == 0) return "0";
        uint256 len = 0;
        for (uint256 t = v; t != 0; t /= 10) len++;
        bytes memory buf = new bytes(len);
        while (v != 0) {
            buf[--len] = bytes1(uint8(48 + v % 10));
            v /= 10;
        }
        return string(buf);
    }

    // ---------- free mint for .ai Agent ID wallets ----------
    /// @notice Hook for Binance Agentic Wallet users: one free miner per wallet while the
    ///         1,000-piece free allocation lasts. Requires a verified .ai Agent ID.
    function freeMint() external {
        require(mintOpen, "mint closed");
        require(!freeUsed[msg.sender], "free already used");
        require(freeMinted < FREE_SUPPLY, "free supply gone");
        require(totalSupply < MAX_SUPPLY, "sold out");
        require(mintedBy[msg.sender] < MAX_PER_WALLET, "wallet cap");
        require(agentRegistry.balanceOf(msg.sender) > 0, "agent id required");

        freeUsed[msg.sender] = true;
        freeMinted += 1;
        mintedBy[msg.sender] += 1;

        uint256 id = _mintOne(msg.sender);
        _notifyWeight(address(0), msg.sender);
        emit FreeMinted(msg.sender, id);
    }

    /// @notice True if this wallet can still take its free miner right now.
    function canFreeMint(address wallet) external view returns (bool) {
        return mintOpen
            && !freeUsed[wallet]
            && freeMinted < FREE_SUPPLY
            && totalSupply < MAX_SUPPLY
            && mintedBy[wallet] < MAX_PER_WALLET
            && agentRegistry.balanceOf(wallet) > 0;
    }

    // ---------- royalties (ERC-2981) ----------
    function setRoyalty(uint16 bps) external onlyOwner {
        require(bps <= 1000, "royalty too high");   // hard cap 10%
        royaltyBps = bps;
        emit RoyaltyChanged(bps);
    }

    function royaltyInfo(uint256, uint256 salePrice) external view returns (address, uint256) {
        return (feeRecipient, salePrice * royaltyBps / 10_000);
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == 0x01ffc9a7      // ERC-165
            || interfaceId == 0x80ac58cd      // ERC-721
            || interfaceId == 0x2a55205a;     // ERC-2981
    }

    // ---------- ERC721 ----------
    function approve(address to, uint256 tokenId) external {
        require(ownerOf[tokenId] == msg.sender || isApprovedForAll[ownerOf[tokenId]][msg.sender], "not authorized");
        getApproved[tokenId] = to;
        emit Approval(ownerOf[tokenId], to, tokenId);
    }

    function setApprovalForAll(address operator, bool approved) external {
        isApprovedForAll[msg.sender][operator] = approved;
        emit ApprovalForAll(msg.sender, operator, approved);
    }

    function transferFrom(address from, address to, uint256 tokenId) public {
        require(ownerOf[tokenId] == from, "not owner");
        require(to != address(0), "zero to");
        require(msg.sender == from || isApprovedForAll[from][msg.sender] || getApproved[tokenId] == msg.sender, "not authorized");
        delete getApproved[tokenId];

        uint256 w = weightOf(tokenId);

        uint256[] storage src = _owned[from];
        uint256 idx = _ownedIndex[tokenId];
        uint256 last = src[src.length - 1];
        src[idx] = last;
        _ownedIndex[last] = idx;
        src.pop();
        balanceOf[from] -= 1;

        _owned[to].push(tokenId);
        _ownedIndex[tokenId] = _owned[to].length - 1;
        balanceOf[to] += 1;
        ownerOf[tokenId] = to;

        weightOfWallet[from] -= w;              // weight follows the token (H-1)
        weightOfWallet[to] += w;

        emit Transfer(from, to, tokenId);
        _notifyWeight(from, to);
    }

    function safeTransferFrom(address from, address to, uint256 tokenId) external {
        transferFrom(from, to, tokenId);
        if (to.code.length > 0) {               // review M-2: receiver hook
            require(
                IERC721Receiver(to).onERC721Received(msg.sender, from, tokenId, "") ==
                    IERC721Receiver.onERC721Received.selector,
                "unsafe recipient"
            );
        }
    }

    function _notifyWeight(address from, address to) internal {
        if (mining != address(0)) IWeightSink(mining).onWeightChange(from, to);
    }
}

interface IERC721Receiver {
    function onERC721Received(address operator, address from, uint256 tokenId, bytes calldata data)
        external returns (bytes4);
}
