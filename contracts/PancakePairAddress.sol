// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title PancakePairAddress — derive a PancakeSwap V2 pair address before it exists.
/// @notice Pure CREATE2 derivation; nothing is deployed or called. Use it in a deploy
///         script (or on-chain) to know the GNX/BNB pair address ahead of listing, so the
///         GenuxLPLock address can be published before the pool opens.
library PancakePairAddress {
    // PancakeSwap V2 factory on BSC
    address internal constant FACTORY = 0xcA143Ce32Fe78f1f7019d7d551a6402fC5350c73;
    // keccak256 of PancakePair creation code, as used by the current factory
    bytes32 internal constant INIT_CODE_HASH =
        0x00fb7f630766e6a796048ea87d01acd3068e8ff67d078148a3fa3f4a84f69bd5;

    /// @notice Deterministic pair address for two tokens (order does not matter).
    function pairFor(address tokenA, address tokenB) internal pure returns (address pair) {
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        bytes32 salt = keccak256(abi.encodePacked(token0, token1));
        bytes32 h = keccak256(abi.encodePacked(hex"ff", FACTORY, salt, INIT_CODE_HASH));
        pair = address(uint160(uint256(h)));
    }

    /// @notice True if the derivation matches the factory's own record.
    function verify(address tokenA, address tokenB) internal view returns (bool) {
        (bool ok, bytes memory data) = FACTORY.staticcall(
            abi.encodeWithSignature("getPair(address,address)", tokenA, tokenB)
        );
        if (!ok || data.length < 32) return false;
        address onChain = address(uint160(uint256(bytes32(data))));
        return onChain == pairFor(tokenA, tokenB);
    }
}

/// @notice Example deploy-time usage (wire into your deploy script, not deployed itself):
///
///   address predictedPair = PancakePairAddress.pairFor(address(gnx), WBNB);
///   GenuxLPLock locker = new GenuxLPLock(predictedPair, beneficiary, 1796907600, 1828443600);
///
///   // later, on listing day, after adding liquidity:
///   //   transfer the LP tokens to `locker`, then call locker.markFunded()
contract GenuxPairHelper {
    address public constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;

    function pairFor(address tokenA, address tokenB) external pure returns (address) {
        return PancakePairAddress.pairFor(tokenA, tokenB);
    }

    function verifyPair(address tokenA, address tokenB) external view returns (bool) {
        return PancakePairAddress.verify(tokenA, tokenB);
    }
}
