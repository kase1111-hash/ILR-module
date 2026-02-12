# NatLangChain ILRM - Deployment Guide

**Software Version:** 0.1.0-alpha
**Protocol Specification:** v1.5
**Last Updated:** January 2026

---

## Table of Contents

1. [Prerequisites](#prerequisites)
2. [Environment Setup](#environment-setup)
3. [Testnet Deployment](#testnet-deployment)
4. [Mainnet Deployment](#mainnet-deployment)
5. [Contract Verification](#contract-verification)
6. [Governance Setup](#governance-setup)
7. [Post-Deployment Checklist](#post-deployment-checklist)

---

## Prerequisites

### Required Tools

```bash
# Node.js v18+
node --version  # Should be >= 18.0.0

# Foundry (for contract compilation and testing)
curl -L https://foundry.paradigm.xyz | bash
foundryup

# Hardhat (included via npm)
npm install
```

### Required Accounts & Keys

1. **Deployer Wallet**
   - Generate a fresh wallet for deployment
   - Fund with native tokens (ETH/OP/ARB) for gas
   - NEVER use a personal wallet

2. **Multi-sig Wallet (Gnosis Safe)**
   - Deploy at [safe.global](https://safe.global)
   - Configure 2-of-3 or 3-of-5 signers minimum
   - Use hardware wallets for signers

3. **RPC Endpoints**
   - Alchemy, Infura, or QuickNode account
   - Get API keys for target networks

4. **Block Explorer API Keys**
   - Etherscan, Optimism Etherscan, Arbiscan

---

## Environment Setup

### 1. Create Environment File

```bash
cp .env.example .env
```

### 2. Configure Required Variables

```bash
# Deployer key (use dedicated deployment wallet)
DEPLOYER_PRIVATE_KEY=your_private_key_without_0x

# RPC endpoints
OPTIMISM_SEPOLIA_RPC_URL=https://opt-sepolia.g.alchemy.com/v2/YOUR_KEY
OPTIMISM_RPC_URL=https://opt-mainnet.g.alchemy.com/v2/YOUR_KEY

# Block explorer keys
OPTIMISM_ETHERSCAN_API_KEY=your_api_key

# Multi-sig address
MULTISIG_ADDRESS=0x...
```

### 3. Verify Configuration

```bash
# Check Hardhat config loads
npx hardhat compile

# Run tests to verify setup
forge test
```

---

## Testnet Deployment

### Recommended: Optimism Sepolia

**Why Optimism Sepolia?**
- Low gas costs for testing
- Same L2 environment as production target
- Reliable bridge and faucet availability

### Step 1: Fund Deployer

Get testnet ETH from faucets:
- [Optimism Sepolia Faucet](https://www.alchemy.com/faucets/optimism-sepolia)
- [Chainlink Faucet](https://faucets.chain.link/)

Verify balance:
```bash
cast balance $DEPLOYER_ADDRESS --rpc-url $OPTIMISM_SEPOLIA_RPC_URL
```

### Step 2: Deploy Core Contracts

```bash
# Deploy all contracts
npx hardhat run scripts/deploy.js --network optimismSepolia

# Save output addresses to .env
# ILRM_ADDRESS=0x...
# TREASURY_ADDRESS=0x...
# etc.
```

### Step 3: Verify Deployment

```bash
# Run tests against deployed contracts
forge test --fork-url $OPTIMISM_SEPOLIA_RPC_URL

# Verify contract source on block explorer
node scripts/verify-contracts.js --network optimismSepolia
```

### Step 4: Deploy Governance

```bash
# Configure contract addresses in .env first
npx hardhat run scripts/deploy-governance.ts --network optimismSepolia
```

---

## Mainnet Deployment

### Pre-Deployment Checklist

- [ ] All tests pass with 10,000 fuzz runs
- [ ] Testnet deployment verified for 7+ days
- [ ] Multi-sig configured and tested
- [ ] Emergency procedures documented
- [ ] Team trained on incident response
- [ ] Legal review complete (if applicable)
- [ ] Gas budget approved (~$500-2000 for full deployment)

### Step 1: Fund Deployer

Calculate required gas:
```bash
# Estimate deployment costs via dry-run
npx hardhat run scripts/deploy.js --network optimism --dry-run
```

Transfer funds to deployer wallet (add 50% buffer for safety).

### Step 2: Deploy Core Contracts

```bash
# Deploy with confirmation
npx hardhat run scripts/deploy.js --network optimism

# IMMEDIATELY RECORD ALL ADDRESSES
# Save to deployments/optimism-mainnet.json
```

### Step 3: Verify Contracts on Explorer

```bash
# Verify each contract
npx hardhat verify --network optimism ILRM_ADDRESS "TOKEN_ADDRESS" "ORACLE_ADDRESS" "REGISTRY_ADDRESS"
npx hardhat verify --network optimism TREASURY_ADDRESS "TOKEN_ADDRESS" "..." "..." "..."
# Continue for all contracts
```

### Step 4: Deploy Governance

```bash
npx hardhat run scripts/deploy-governance.ts --network optimism
```

### Step 5: Transfer Ownership

Transfer ownership to GovernanceTimelock:

```bash
# For each Ownable contract:
cast send $ILRM_ADDRESS "transferOwnership(address)" $TIMELOCK_ADDRESS --rpc-url $OPTIMISM_RPC_URL --private-key $DEPLOYER_PRIVATE_KEY

# Repeat for Treasury, Oracle, AssetRegistry, etc.
```

### Step 6: Accept Ownership (via Multi-sig)

Create multi-sig proposal to call `acceptOwnership()` on each contract.

---

## Contract Verification

### Automatic Verification (via Hardhat)

```bash
npx hardhat verify --network optimism CONTRACT_ADDRESS CONSTRUCTOR_ARG1 CONSTRUCTOR_ARG2 ...
```

### Manual Verification

1. Flatten source code:
   ```bash
   forge flatten contracts/ILRM.sol > ILRM.flat.sol
   ```

2. Go to block explorer → Contract → Verify
3. Upload flattened source
4. Match compiler settings: Solidity 0.8.20, 200 optimizer runs

### Sourcify Verification

```bash
# Alternative decentralized verification
forge verify-contract --chain-id 10 CONTRACT_ADDRESS ILRM --verifier sourcify
```

---

## Governance Setup

### Multi-sig Configuration

1. **Create Gnosis Safe**
   - Go to [safe.global](https://safe.global)
   - Connect wallet on target network
   - Add signers (3-5 trusted addresses)
   - Set threshold (e.g., 2-of-3)

2. **Configure Safe Roles**
   - Add all team members as signers
   - Use hardware wallets for all signers
   - Test with a small transaction first

### Timelock Configuration

Delays configured in `deploy-governance.ts`:
- `minDelay`: 2 days (standard operations)
- `emergencyDelay`: 12 hours (critical fixes)
- `longDelay`: 4 days (major changes)

### Emergency Actions

The multi-sig can execute emergency actions with reduced delay:
- Pause all contracts
- Update critical parameters
- Upgrade oracle addresses

---

## Post-Deployment Checklist

### Immediate (Day 1)

- [ ] All contract addresses recorded in `deployments/`
- [ ] All contracts verified on block explorer
- [ ] Ownership transferred to GovernanceTimelock
- [ ] Multi-sig can execute emergency pause
- [ ] Announcement posted with contract addresses

### Week 1

- [ ] Subgraph deployed for event indexing
- [ ] Monitoring alerts configured
- [ ] Runbook distributed to team
- [ ] First test dispute run successfully
- [ ] Documentation updated with addresses

### Month 1

- [ ] Gas usage analyzed and documented
- [ ] User feedback collected
- [ ] Any hotfixes applied (if needed)
- [ ] Performance metrics reviewed

---

## Deployment Addresses

### Optimism Sepolia (Testnet)

| Contract | Address | Verified |
|----------|---------|----------|
| ILRM | TBD | - |
| Treasury | TBD | - |
| Oracle | TBD | - |
| AssetRegistry | TBD | - |
| GovernanceTimelock | TBD | - |

### Optimism Mainnet

| Contract | Address | Verified |
|----------|---------|----------|
| ILRM | TBD | - |
| Treasury | TBD | - |
| Oracle | TBD | - |
| AssetRegistry | TBD | - |
| GovernanceTimelock | TBD | - |

---

## Troubleshooting

### Deployment Fails with "insufficient funds"

- Check deployer balance: `cast balance $DEPLOYER_ADDRESS`
- Add buffer (50%+) for gas price spikes
- Consider deploying during low-gas periods

### Contract Verification Fails

- Ensure exact same compiler version (0.8.20)
- Ensure exact same optimizer settings (200 runs)
- Try manual verification with flattened source
- Check constructor arguments match deployment

### Ownership Transfer Fails

- Verify you're calling from current owner
- Check GovernanceTimelock is deployed correctly
- Use Ownable2Step pattern (transfer → accept)

---

## Support

For deployment assistance:
- GitHub Issues: [ILR-module/issues](https://github.com/kase1111-hash/ILR-module/issues)
- Emergency Contact: [team contact info]

---

*Keep this document updated after each deployment.*
