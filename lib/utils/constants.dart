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

/// Bytes of key fingerprint carried in a v1 secret.
///
/// Enough to make an accidental cross-flavor paste obvious; not a security
/// boundary, since the auth tag is what actually rejects a wrong key.
const keyIdLength = 4;

/// Domain separator for the key fingerprint, so a key id can never be a
/// prefix of the AES key itself.
const keyIdDomain = 'pnv:key-id:v1';
