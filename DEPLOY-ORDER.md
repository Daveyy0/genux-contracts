# Genux deploy order (Bitget deployer)

Deployer / owner: 0xa6D5d7b7615f1a1DCF744614B12e399c5b0B5254
Network: BSC Mainnet (56). Compiler 0.8.24, optimizer on (Remix default).

1. GenuxMiner(feeRecipient=deployer, mintPrice=1350000000000000, priceToLv2=1350000000000000, priceToLv3=2020000000000000, baseURI="https://daveyy0.github.io/genux-metadata/", agentRegistry=0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F)
2. GenuxMining(miner, start=1794315600)
3. GenuxTeamVesting(beneficiary=deployer, start=1796907600, cliff=15552000, period=63072000, totalAllocation=19500000000000000000000000) -- beneficiary is immutable
4. GenuxTreasuryLock(start=1799586000, cliff=10368000, period=31536000, totalAllocation=60000000000000000000000000, recipient=deployer for now, changeable before 2027-01-10)
5. GenuxToken(mining, poolWallet=deployer, teamWallet=TeamVesting, treasuryWallet=TreasuryLock, pair=predicted pair from real Token address, router=0x10ED43C718714eb63d5aA57B78B54704E256024E, lpRecipient=deployer for now, changeable before first harvest)
6. Wiring: Miner.setMining(Mining); then proposeToken(GNX) + confirmToken() on Mining, TeamVesting, TreasuryLock. Confirm is irreversible -- double-check GNX first.
7. GenuxMarket(miner, feeRecipient=deployer, feeBps=500, router, GNX, WBNB=0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c)
8. GenuxLPLock -- only after the real pair exists / is recomputed; do not guess it.
9. Miner.setMintOpen(true) only when ready for public mint.
