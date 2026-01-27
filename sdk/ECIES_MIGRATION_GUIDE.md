# ECIES Version Migration Guide

This guide documents the versioning scheme for the ECIES (Elliptic Curve Integrated Encryption Scheme) implementation and how to handle version migrations.

## Current Version

**ECIES_VERSION: 1**

## Versioning Scheme

The ECIES ciphertext includes a `version` field that enables forward compatibility:

```typescript
interface ECIESCiphertext {
  version: number;              // Format version
  ephemeralPublicKey: string;   // Ephemeral public key
  iv: string;                   // Initialization vector
  ciphertext: string;           // Encrypted data
  authTag: string;              // Authentication tag
}
```

## Version History

### Version 0 (Legacy)
- Implicit version (no `version` field in ciphertext)
- Same cryptographic scheme as v1
- SDK treats missing version as v0

### Version 1 (Current)
- Explicit version field added
- Domain-specific HKDF salt: `natlangchain-ecies-v1-salt`
- No changes to underlying cryptography

## Decryption Compatibility

The SDK automatically handles version compatibility:

| Ciphertext Version | SDK Version 1 | Future SDK |
|--------------------|---------------|------------|
| v0 (legacy)        | Decrypts      | Decrypts   |
| v1 (current)       | Decrypts      | Decrypts   |
| v2+ (future)       | Error         | Decrypts   |

## Migration Scenarios

### Scenario 1: Decrypting Old Data

If you have ciphertext from an older SDK version:

```typescript
import { ECIES } from '@natlangchain/sdk';

const ecies = new ECIES();

// Old ciphertext (may not have version field)
const oldCiphertext = {
  // version: undefined (legacy)
  ephemeralPublicKey: '0x04...',
  iv: '0x...',
  ciphertext: '0x...',
  authTag: '0x...'
};

// SDK handles this automatically - treats as version 0
const decrypted = await ecies.decrypt(privateKey, oldCiphertext);
```

### Scenario 2: Upgrading to New SDK Version

When a new SDK version is released with ECIES_VERSION 2+:

1. **Check release notes** for breaking changes
2. **Test decryption** of existing data before upgrading in production
3. **Re-encrypt data** only if required by the new version (rare)

```typescript
// After upgrading SDK
import { ECIES, ECIES_VERSION } from '@natlangchain/sdk';

console.log(`Current ECIES version: ${ECIES_VERSION}`);

// Decrypt old data (always supported)
const ecies = new ECIES();
const decrypted = await ecies.decrypt(privateKey, oldCiphertext);

// New encryptions use current version
const newCiphertext = await ecies.encrypt(publicKey, decrypted);
console.log(`New ciphertext version: ${newCiphertext.version}`);
```

### Scenario 3: Handling Unsupported Versions

If you receive ciphertext from a newer SDK version:

```typescript
try {
  const decrypted = await ecies.decrypt(privateKey, futureCiphertext);
} catch (error) {
  if (error.message.includes('Unsupported ECIES ciphertext version')) {
    console.error('Please upgrade your SDK to decrypt this data');
    // The error message includes the required version
  }
}
```

## Best Practices

1. **Always store the full ciphertext object** including the version field
2. **Test decryption after SDK upgrades** before deploying to production
3. **Handle version errors gracefully** in your application
4. **Keep SDK updated** to support latest security improvements

## Breaking Changes Policy

We follow these principles for ECIES versioning:

- **Backward compatibility**: New SDK versions can always decrypt old ciphertext
- **Forward compatibility**: Old SDK versions reject unsupported future versions with clear error
- **Version bumps**: Only for changes to the ciphertext format, not internal improvements
- **Security fixes**: Applied to all supported versions

## Multi-Recipient Encryption

The multi-recipient encryption (`encryptMulti`) uses the same versioning:

```typescript
const { sharedCiphertext, keyShares } = await ecies.encryptMulti(
  [pubKey1, pubKey2, pubKey3],
  plaintext
);

// Both sharedCiphertext and keyShares have version field
console.log(sharedCiphertext.version); // 1
console.log(keyShares[0].version);     // 1
```

## Troubleshooting

### "Unsupported ECIES ciphertext version X"

**Cause**: Ciphertext was created with a newer SDK version

**Solution**: Upgrade your SDK to the version specified in the error message

### Missing version field

**Cause**: Legacy ciphertext from SDK < 1.0

**Solution**: No action needed - SDK handles this automatically as version 0

### Decryption fails after SDK upgrade

**Cause**: Potential breaking change or corrupted ciphertext

**Solution**:
1. Check release notes for the SDK version
2. Verify ciphertext integrity (all fields present)
3. Test with known-good test vectors
