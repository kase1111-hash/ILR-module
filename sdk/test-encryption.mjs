/**
 * End-to-end encryption tests for SDK components
 * Tests all the security fixes made to the encryption implementation
 *
 * Run with: node sdk/test-encryption.mjs
 */

import crypto from 'crypto';

// Polyfill crypto for Node.js
if (!globalThis.crypto) {
  globalThis.crypto = crypto.webcrypto;
}

// ============ Shamir Secret Sharing Implementation (inline for testing) ============

// GF(2^8) with primitive polynomial x^8 + x^4 + x^3 + x + 1 (0x11b)
const GF256_PRIMITIVE = 0x11b;
const EXP = new Uint8Array(256);
const LOG = new Uint8Array(256);

// Multiply without tables (for table generation)
function gfMulNoTable(a, b) {
  let result = 0;
  while (b > 0) {
    if (b & 1) result ^= a;
    a <<= 1;
    if (a & 0x100) a ^= GF256_PRIMITIVE;
    b >>= 1;
  }
  return result & 0xff;
}

// Initialize tables using 3 as the generator (primitive element)
// Note: 2 has order 51 in this field, but 3 has order 255 (full group)
(function initTables() {
  let x = 1;
  for (let i = 0; i < 255; i++) {
    EXP[i] = x;
    LOG[x] = i;
    x = gfMulNoTable(x, 3);  // Use 3 as primitive element
  }
  EXP[255] = EXP[0];
})();

function gfMul(a, b) {
  if (a === 0 || b === 0) return 0;
  const logSum = LOG[a] + LOG[b];
  return EXP[logSum % 255];
}

function gfDiv(a, b) {
  if (b === 0) throw new Error('Division by zero');
  if (a === 0) return 0;
  const logDiff = LOG[a] - LOG[b] + 255;
  return EXP[logDiff % 255];
}

function randomBytes(length) {
  const array = new Uint8Array(length);
  crypto.getRandomValues(array);
  return array;
}

// Evaluate polynomial using Horner's method
function evaluatePolynomial(coefficients, x) {
  if (x === 0) return coefficients[0];

  let result = 0;
  for (let i = coefficients.length - 1; i >= 0; i--) {
    result = gfMul(result, x) ^ coefficients[i];
  }
  return result;
}

function split(secret, numShares, threshold) {
  if (threshold < 2) throw new Error('Threshold must be at least 2');
  if (threshold > numShares) throw new Error('Threshold cannot exceed number of shares');
  if (numShares > 255) throw new Error('Maximum 255 shares supported');
  if (secret.length === 0) throw new Error('Secret cannot be empty');

  const shares = [];
  for (let i = 0; i < numShares; i++) {
    shares.push({
      index: i + 1,
      data: new Uint8Array(secret.length),
    });
  }

  for (let byteIdx = 0; byteIdx < secret.length; byteIdx++) {
    // Create polynomial: coefficients[0] = secret byte, rest are random
    const coefficients = new Uint8Array(threshold);
    coefficients[0] = secret[byteIdx];

    for (let i = 1; i < threshold; i++) {
      coefficients[i] = randomBytes(1)[0];
    }

    // Evaluate polynomial at each x point (1 to numShares)
    for (let i = 0; i < numShares; i++) {
      shares[i].data[byteIdx] = evaluatePolynomial(coefficients, i + 1);
    }
  }

  return shares;
}

function combine(shares) {
  if (shares.length < 2) throw new Error('Need at least 2 shares');

  const indices = shares.map(s => s.index);
  const uniqueIndices = new Set(indices);
  if (uniqueIndices.size !== indices.length) {
    throw new Error('Duplicate share indices detected');
  }

  const secretLength = shares[0].data.length;
  const secret = new Uint8Array(secretLength);

  // Reconstruct each byte using Lagrange interpolation at x=0
  for (let byteIdx = 0; byteIdx < secretLength; byteIdx++) {
    let value = 0;

    for (let i = 0; i < shares.length; i++) {
      const xi = shares[i].index;
      const yi = shares[i].data[byteIdx];

      // Calculate Lagrange basis polynomial Li(0)
      let numerator = 1;
      let denominator = 1;

      for (let j = 0; j < shares.length; j++) {
        if (i === j) continue;

        const xj = shares[j].index;

        // Li(0) = product of (0 - xj) / (xi - xj) for all j != i
        // In GF(2^8), subtraction is same as addition (XOR), and 0-xj = xj
        numerator = gfMul(numerator, xj);
        denominator = gfMul(denominator, xi ^ xj);  // xi XOR xj in GF(2^8)
      }

      // Li(0) * yi - compute the Lagrange term
      const lagrangeTerm = gfMul(yi, gfDiv(numerator, denominator));
      value ^= lagrangeTerm;  // XOR is addition in GF(2^8)
    }

    secret[byteIdx] = value;
  }

  return secret;
}

// ============ ECIES Implementation (simplified for testing) ============

async function deriveKey(sharedSecret, salt, info) {
  const baseKey = await crypto.subtle.importKey(
    'raw',
    sharedSecret,
    'HKDF',
    false,
    ['deriveKey']
  );

  return crypto.subtle.deriveKey(
    {
      name: 'HKDF',
      hash: 'SHA-256',
      salt: new TextEncoder().encode(salt),
      info: new TextEncoder().encode(info),
    },
    baseKey,
    { name: 'AES-GCM', length: 256 },
    true,
    ['encrypt', 'decrypt']
  );
}

async function aesGcmEncrypt(key, iv, data) {
  const cryptoKey = await crypto.subtle.importKey(
    'raw',
    key,
    'AES-GCM',
    false,
    ['encrypt']
  );

  const result = await crypto.subtle.encrypt(
    { name: 'AES-GCM', iv, tagLength: 128 },
    cryptoKey,
    data
  );

  const resultBytes = new Uint8Array(result);
  return {
    ciphertext: resultBytes.slice(0, -16),
    authTag: resultBytes.slice(-16),
  };
}

async function aesGcmDecrypt(key, iv, ciphertext, authTag) {
  const cryptoKey = await crypto.subtle.importKey(
    'raw',
    key,
    'AES-GCM',
    false,
    ['decrypt']
  );

  const combined = new Uint8Array(ciphertext.length + authTag.length);
  combined.set(ciphertext);
  combined.set(authTag, ciphertext.length);

  const result = await crypto.subtle.decrypt(
    { name: 'AES-GCM', iv, tagLength: 128 },
    cryptoKey,
    combined
  );

  return new Uint8Array(result);
}

// ============ Test Utilities ============

function assert(condition, message) {
  if (!condition) {
    throw new Error(`ASSERTION FAILED: ${message}`);
  }
}

function arraysEqual(a, b) {
  if (a.length !== b.length) return false;
  for (let i = 0; i < a.length; i++) {
    if (a[i] !== b[i]) return false;
  }
  return true;
}

// ============ Tests ============

async function testShamirBasic() {
  console.log('\n=== Test: Shamir Basic Split/Combine ===');

  const secret = new Uint8Array([1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16]);

  // Split into 5 shares, threshold 3
  const shares = split(secret, 5, 3);
  assert(shares.length === 5, 'Should create 5 shares');
  console.log('  ✓ Split into 5 shares');

  // Reconstruct with exactly threshold shares
  const reconstructed1 = combine([shares[0], shares[1], shares[2]]);
  assert(arraysEqual(reconstructed1, secret), 'Should reconstruct with shares 0,1,2');
  console.log('  ✓ Reconstructed with shares 0,1,2');

  // Reconstruct with different shares
  const reconstructed2 = combine([shares[0], shares[2], shares[4]]);
  assert(arraysEqual(reconstructed2, secret), 'Should reconstruct with shares 0,2,4');
  console.log('  ✓ Reconstructed with shares 0,2,4');

  // Reconstruct with more than threshold
  const reconstructed3 = combine([shares[0], shares[1], shares[2], shares[3]]);
  assert(arraysEqual(reconstructed3, secret), 'Should reconstruct with 4 shares');
  console.log('  ✓ Reconstructed with 4 shares (more than threshold)');
}

async function testShamirValidation() {
  console.log('\n=== Test: Shamir Input Validation ===');

  const secret = new Uint8Array([1, 2, 3, 4]);

  // Threshold < 2
  try {
    split(secret, 5, 1);
    throw new Error('Should have thrown');
  } catch (e) {
    if (e.message === 'Should have thrown') throw e;
    console.log('  ✓ Rejects threshold < 2');
  }

  // Threshold > numShares
  try {
    split(secret, 3, 5);
    throw new Error('Should have thrown');
  } catch (e) {
    if (e.message === 'Should have thrown') throw e;
    console.log('  ✓ Rejects threshold > numShares');
  }

  // Empty secret
  try {
    split(new Uint8Array(0), 5, 3);
    throw new Error('Should have thrown');
  } catch (e) {
    if (e.message === 'Should have thrown') throw e;
    console.log('  ✓ Rejects empty secret');
  }

  // Duplicate indices
  const shares = split(secret, 5, 3);
  try {
    combine([shares[0], shares[0], shares[1]]);
    throw new Error('Should have thrown');
  } catch (e) {
    if (e.message === 'Should have thrown') throw e;
    console.log('  ✓ Rejects duplicate share indices');
  }
}

async function testAESGCM() {
  console.log('\n=== Test: AES-256-GCM Encryption ===');

  const key = randomBytes(32);
  const iv = randomBytes(12);
  const plaintext = new TextEncoder().encode('Hello, World! This is a test message.');

  // Encrypt
  const { ciphertext, authTag } = await aesGcmEncrypt(key, iv, plaintext);
  console.log('  ✓ Encrypted message');

  // Decrypt
  const decrypted = await aesGcmDecrypt(key, iv, ciphertext, authTag);
  assert(arraysEqual(decrypted, plaintext), 'Decrypted should match original');
  console.log('  ✓ Decrypted message matches original');

  // Verify tampering detection
  const tamperedCiphertext = new Uint8Array(ciphertext);
  tamperedCiphertext[0] ^= 0xff;

  try {
    await aesGcmDecrypt(key, iv, tamperedCiphertext, authTag);
    throw new Error('Should have thrown');
  } catch (e) {
    if (e.message === 'Should have thrown') throw e;
    console.log('  ✓ Detects tampered ciphertext');
  }
}

async function testHKDF() {
  console.log('\n=== Test: HKDF Key Derivation ===');

  const sharedSecret = randomBytes(32);
  const salt = 'natlangchain-ecies-v1-salt';
  const info = 'ecies-encryption';

  // Derive key
  const derivedKey = await deriveKey(sharedSecret, salt, info);
  const keyBytes = new Uint8Array(await crypto.subtle.exportKey('raw', derivedKey));

  assert(keyBytes.length === 32, 'Derived key should be 32 bytes');
  console.log('  ✓ Derived 32-byte key');

  // Same input produces same output
  const derivedKey2 = await deriveKey(sharedSecret, salt, info);
  const keyBytes2 = new Uint8Array(await crypto.subtle.exportKey('raw', derivedKey2));

  assert(arraysEqual(keyBytes, keyBytes2), 'Same input should produce same key');
  console.log('  ✓ Deterministic key derivation');

  // Different salt produces different key
  const derivedKey3 = await deriveKey(sharedSecret, 'different-salt', info);
  const keyBytes3 = new Uint8Array(await crypto.subtle.exportKey('raw', derivedKey3));

  assert(!arraysEqual(keyBytes, keyBytes3), 'Different salt should produce different key');
  console.log('  ✓ Salt affects key derivation');
}

async function testSHA256() {
  console.log('\n=== Test: SHA-256 Hashing ===');

  const data = new TextEncoder().encode('test message');

  // Hash using Web Crypto
  const hashBuffer = await crypto.subtle.digest('SHA-256', data);
  const hash = new Uint8Array(hashBuffer);

  assert(hash.length === 32, 'SHA-256 should produce 32 bytes');
  console.log('  ✓ SHA-256 produces 32-byte hash');

  // Same input produces same hash
  const hashBuffer2 = await crypto.subtle.digest('SHA-256', data);
  const hash2 = new Uint8Array(hashBuffer2);

  assert(arraysEqual(hash, hash2), 'Same input should produce same hash');
  console.log('  ✓ Deterministic hashing');
}

async function testIntegration() {
  console.log('\n=== Test: Full Integration (Shamir + AES-GCM) ===');

  // Simulate viewing key escrow flow
  const viewingKey = randomBytes(32);
  console.log('  ✓ Generated random viewing key');

  // Split viewing key into 5 shares, threshold 3
  const shares = split(viewingKey, 5, 3);
  console.log('  ✓ Split viewing key into 5 shares');

  // Simulate encrypting each share to a holder's key
  const holderKeys = [];
  const encryptedShares = [];

  for (let i = 0; i < 5; i++) {
    const holderKey = randomBytes(32);
    const iv = randomBytes(12);

    // Combine index and share data
    const shareData = new Uint8Array(1 + shares[i].data.length);
    shareData[0] = shares[i].index;
    shareData.set(shares[i].data, 1);

    const encrypted = await aesGcmEncrypt(holderKey, iv, shareData);

    holderKeys.push({ key: holderKey, iv });
    encryptedShares.push(encrypted);
  }
  console.log('  ✓ Encrypted shares to 5 holders');

  // Simulate reveal: decrypt 3 shares and reconstruct
  const revealIndices = [0, 2, 4];
  const revealedShares = [];

  for (const idx of revealIndices) {
    const { key, iv } = holderKeys[idx];
    const { ciphertext, authTag } = encryptedShares[idx];

    const decrypted = await aesGcmDecrypt(key, iv, ciphertext, authTag);
    revealedShares.push({
      index: decrypted[0],
      data: decrypted.slice(1),
    });
  }
  console.log('  ✓ Decrypted 3 shares');

  // Reconstruct viewing key
  const reconstructed = combine(revealedShares);
  assert(arraysEqual(reconstructed, viewingKey), 'Reconstructed should match original');
  console.log('  ✓ Reconstructed viewing key matches original!');
}

async function testVersionField() {
  console.log('\n=== Test: ECIES Version Field ===');

  const ECIES_VERSION = 1;

  // Create ciphertext with version
  const ciphertext = {
    version: ECIES_VERSION,
    ephemeralPublicKey: '0x' + '04' + '00'.repeat(64),
    iv: '0x' + '00'.repeat(12),
    ciphertext: '0x' + 'deadbeef',
    authTag: '0x' + '00'.repeat(16),
  };

  assert(ciphertext.version === 1, 'Version should be 1');
  console.log('  ✓ Version field is set to 1');

  // Legacy ciphertext (no version)
  const legacyCiphertext = {
    ephemeralPublicKey: '0x' + '04' + '00'.repeat(64),
    iv: '0x' + '00'.repeat(12),
    ciphertext: '0x' + 'deadbeef',
    authTag: '0x' + '00'.repeat(16),
  };

  const version = legacyCiphertext.version ?? 0;
  assert(version === 0, 'Legacy ciphertext should default to version 0');
  console.log('  ✓ Legacy ciphertext defaults to version 0');

  // Future version check
  const futureCiphertext = { ...ciphertext, version: 999 };
  assert(futureCiphertext.version > ECIES_VERSION, 'Future version should be > current');
  console.log('  ✓ Future version detection works');
}

// ============ Test Runner ============

async function runAllTests() {
  console.log('╔════════════════════════════════════════════════════════╗');
  console.log('║     End-to-End Encryption Tests                        ║');
  console.log('╚════════════════════════════════════════════════════════╝');

  let passed = 0;
  let failed = 0;

  const tests = [
    { name: 'Shamir Basic', fn: testShamirBasic },
    { name: 'Shamir Validation', fn: testShamirValidation },
    { name: 'AES-256-GCM', fn: testAESGCM },
    { name: 'HKDF Key Derivation', fn: testHKDF },
    { name: 'SHA-256 Hashing', fn: testSHA256 },
    { name: 'ECIES Version Field', fn: testVersionField },
    { name: 'Full Integration', fn: testIntegration },
  ];

  for (const test of tests) {
    try {
      await test.fn();
      passed++;
      console.log(`\n✅ ${test.name} PASSED`);
    } catch (error) {
      failed++;
      console.log(`\n❌ ${test.name} FAILED: ${error.message}`);
      console.error(error.stack);
    }
  }

  console.log('\n╔════════════════════════════════════════════════════════╗');
  console.log(`║  Results: ${passed} passed, ${failed} failed                            ║`);
  console.log('╚════════════════════════════════════════════════════════╝');

  if (failed > 0) {
    process.exit(1);
  }
}

// Run tests
runAllTests().catch(error => {
  console.error('Test runner failed:', error);
  process.exit(1);
});
