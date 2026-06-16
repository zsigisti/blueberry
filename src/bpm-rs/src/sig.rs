//! Repository index signature verification (ed25519).
//!
//! The repo signs `bpm.index` with an ed25519 private key (`openssl pkeyutl
//! -sign -rawin`, a raw 64-byte EdDSA signature); bpm verifies it against the
//! public key baked into repokey.rs. Mandatory unless `BPM_ALLOW_UNSIGNED` is
//! set. This authenticates the index (and, via the per-package sha256 it
//! carries, every package) beyond TLS transport trust.

use crate::repokey::REPO_PUBKEY;
use ed25519_dalek::{Signature, Verifier, VerifyingKey};

/// Verification required unless the dev escape hatch is set.
pub fn required() -> bool {
    std::env::var_os("BPM_ALLOW_UNSIGNED").is_none()
}

/// True if `sig` (raw 64-byte ed25519) is valid over `data` for the baked key.
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
