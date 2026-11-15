//! Copies a macOS Photos library into a folder: originals, edits, and companion files
//! (RAW+JPEG pairs, Live Photo movies). Writes the same `.photo-export/` manifest as
//! the Uncloud SwiftUI app, so a destination can be checked by either one.

pub mod export;
pub mod library;
pub mod manifest;
pub mod xmp;

pub use export::{run, Options, Summary};
pub use manifest::{status, verify, Layout, VerifyReport};
