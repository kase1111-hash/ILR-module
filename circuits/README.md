# ZK Identity Circuits

This directory contains Circom circuits for privacy-preserving identity proofs in the NatLangChain ILRM protocol.

## Overview

The `prove_identity.circom` circuit allows users to prove they are a party to a dispute without revealing their wallet address on-chain. This enables privacy-preserving dispute participation.

## Prerequisites

Install the required tools:

```bash
# Install Circom
curl --proto '=https' --tlsv1.2 https://sh.rustup.rs -sSf | sh
git clone https://github.com/iden3/circom.git
cd circom
cargo build --release
cargo install --path circom

# Install snarkjs
npm install -g snarkjs

# Install circomlib (for Poseidon)
npm install circomlib
```

## Compilation

### 1. Compile the circuit

```bash
cd circuits
circom prove_identity.circom --r1cs --wasm --sym -l ../node_modules
```

This generates:
- `prove_identity.r1cs` - Circuit constraints
- `prove_identity_js/` - WASM for proof generation
- `prove_identity.sym` - Debug symbols

### 2. Trusted Setup

For development/testing, use a pre-generated Powers of Tau:

```bash
# Download Powers of Tau (12 = 2^12 constraints, adjust if needed)
wget https://hermez.s3-eu-west-1.amazonaws.com/powersOfTau28_hez_final_12.ptau

# Generate proving key
snarkjs groth16 setup prove_identity.r1cs powersOfTau28_hez_final_12.ptau prove_identity_0000.zkey

# Contribute randomness (development only - use MPC for production)
snarkjs zkey contribute prove_identity_0000.zkey prove_identity.zkey --name="Dev contribution" -v

# Export verification key
snarkjs zkey export verificationkey prove_identity.zkey verification_key.json
```

### 3. Generate Solidity Verifier

```bash
snarkjs zkey export solidityverifier prove_identity.zkey IdentityVerifierGroth16.sol
```

## Circuit Details

### ProveIdentity (Basic)

**Private Inputs:**
- `identitySecret` - User's secret (hash of private key + salt)

**Public Inputs:**
- `identityManager` - On-chain hash (stored in Dispute struct)

**Constraint:**
- `Poseidon(identitySecret) === identityManager`

### ProveDisputeParty (Extended)

Includes dispute binding to prevent proof reuse:

**Private Inputs:**
- `identitySecret` - User's secret
- `role` - 0 (initiator) or 1 (counterparty)

**Public Inputs:**
- `identityManager` - On-chain hash
- `disputeId` - The dispute this proof is for
- `expectedRole` - Which role we're proving

### ProveIdentityWithNonce (Replay Protection)

Prevents proof replay with nonces:

**Private Inputs:**
- `identitySecret` - User's secret

**Public Inputs:**
- `identityManager` - On-chain hash
- `nonce` - Current nonce (incremented per use)
- `action` - Hash of action being authorized

**Output:**
- `actionCommitment` - Commitment for verification

## Testing

### Generate a proof manually:

```bash
# Create input file
echo '{"identitySecret": "12345", "identityManager": "..."}' > input.json

# Generate witness
node prove_identity_js/generate_witness.js prove_identity_js/prove_identity.wasm input.json witness.wtns

# Generate proof
snarkjs groth16 prove prove_identity.zkey witness.wtns proof.json public.json

# Verify proof
snarkjs groth16 verify verification_key.json public.json proof.json
```

### Using the SDK:

```typescript
import { IdentityProofSDK, generateRandomSalt } from '../sdk/identity-proof';

const sdk = new IdentityProofSDK(
  './circuits/prove_identity_js/prove_identity.wasm',
  './circuits/prove_identity.zkey'
);

await sdk.initialize();

const identity = await sdk.generateIdentity('my-private-key', generateRandomSalt());
const proof = await sdk.generateProof(identity.secret, identity.hash);

// Submit to contract
await ilrm.acceptProposalWithZKProof(disputeId, proof.solidityProof, identity.hashBytes32);
```

## Production Considerations

### Trusted Setup

For mainnet deployment, conduct a proper MPC (Multi-Party Computation) ceremony:

1. Use a well-audited Powers of Tau ceremony
2. Have multiple independent contributors
3. Document all participants
4. Publish ceremony transcript

### Security Audit

Before mainnet:
- Audit the Circom circuit for soundness
- Verify constraint count is correct
- Test edge cases (zero values, max values)
- Formal verification if possible

### Gas Optimization

The on-chain verifier costs approximately:
- Basic verification: ~200,000 gas
- With storage updates: ~220,000 gas

Consider batching proofs or using L2 for cost reduction.

## File Structure

```
circuits/
├── README.md                      # This file
├── prove_identity.circom          # Main circuit
├── prove_identity.r1cs            # Compiled constraints (generated)
├── prove_identity.zkey            # Proving key (generated)
├── verification_key.json          # Verification key (generated)
├── prove_identity_js/             # WASM files (generated)
│   ├── prove_identity.wasm
│   └── generate_witness.js
└── powersOfTau28_hez_final_12.ptau # Powers of Tau (downloaded)
```

## References

- [Circom Documentation](https://docs.circom.io/)
- [snarkjs Documentation](https://github.com/iden3/snarkjs)
- [Poseidon Hash](https://www.poseidon-hash.info/)
- [Powers of Tau Ceremony](https://github.com/iden3/snarkjs#7-prepare-phase-2)
