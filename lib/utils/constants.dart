const secretAlg = 'aes-256-gcm';
const secretHashAlg = 'sha256';
const algKeyLength = 32;
const algIvLength = 12;
const algAuthTagLength = 16;

/// The number of random bytes behind a newly created key.
///
/// Keys are hashed to [algKeyLength] before use, so this is the real entropy
/// of a secret, not the size of the AES key. It was 12 (96 bits) historically.
const newKeyLength = 32;

/// The shortest key that will be accepted.
///
/// Keys created before [newKeyLength] was raised are 12 bytes, so this cannot
/// move up without invalidating them.
const minKeyLength = 12;
