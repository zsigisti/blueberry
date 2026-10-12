//! Index signature check. bpm.index.sig is a raw 64-byte ed25519 signature
//! (`openssl pkeyutl -sign -rawin`) checked against the key in repokey.rs.
//! The index carries every package's sha256, so this covers the packages too.

use crate::repokey::REPO_PUBKEY;
use ed25519_dalek::{Signature, Verifier, VerifyingKey};

/// BPM_ALLOW_UNSIGNED is for dev only.
pub fn required() -> bool {
    std::env::var_os("BPM_ALLOW_UNSIGNED").is_none()
}

pub fn verify_index(data: &[u8], sig: &[u8]) -> bool {
    let vk = match VerifyingKey::from_bytes(&REPO_PUBKEY) {
        Ok(k) => k,
        Err(_) => return false,
    };
    let bytes: [u8; 64] = match sig.try_into() {
        Ok(b) => b,
        Err(_) => return false,
    };
    vk.verify(data, &Signature::from_bytes(&bytes)).is_ok()
}
