//! The export run: copies every library item that isn't in the destination yet.
//!
//! Each file is streamed to a hidden `.partial` file while it's hashed, then renamed into place and
//! re-hashed to confirm the copy. An item is recorded only after all of its files are in place. If one
//! of its files fails, the files this run created for it are removed and it's retried on the next run.
//! A full disk stops the run, since every later item would fail the same way.

use crate::library::{Asset, Library};
use crate::manifest::{self, Layout, Manifest};
use crate::xmp;
use anyhow::{bail, Context, Result};
use chrono::Local;
use sha2::{Digest, Sha256};
use std::collections::HashSet;
use std::fmt;
use std::fs::{self, File};
use std::io::{self, Read, Write};
use std::path::{Path, PathBuf};

#[derive(Debug, Clone, Copy)]
pub struct Options {
    pub layout: Layout,
    pub write_xmp: bool,
    pub dry_run: bool,
}

#[derive(Debug, Default)]
pub struct Summary {
    pub exported: usize,
    pub skipped: usize,
    /// Items whose original isn't on this Mac (iCloud-only). They're picked up by a later run.
    pub not_downloaded: usize,
    /// `(file name, reason)` for items that failed. They're retried on the next run.
    pub failed: Vec<(String, String)>,
    pub bytes: u64,
    pub dry_run: bool,
}

impl fmt::Display for Summary {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let verb = if self.dry_run {
            "would export"
        } else {
            "exported"
        };
        writeln!(
            f,
            "{verb}: {} items ({})",
            self.exported,
            human_bytes(self.bytes)
        )?;
        writeln!(f, "already in destination: {}", self.skipped)?;
        if self.not_downloaded > 0 {
            writeln!(
                f,
                "only in iCloud on this Mac: {} (download them in Photos, then run again)",
                self.not_downloaded
            )?;
        }
        if !self.failed.is_empty() {
            writeln!(f, "failed: {} (run again to retry)", self.failed.len())?;
            for (name, reason) in self.failed.iter().take(20) {
                writeln!(f, "  {name}: {reason}")?;
            }
        }
        Ok(())
    }
}

/// Runs an export from the Photos library at `library` into `destination`.
pub fn run(library: &Path, destination: &Path, options: Options) -> Result<Summary> {
    let library = Library::open(library)?;
    let assets = library.assets()?;
    let all_originals: HashSet<PathBuf> = assets.iter().map(|a| library.original_path(a)).collect();
    let exported = manifest::read_exported(destination)?;
    let mut summary = Summary {
        dry_run: options.dry_run,
        ..Summary::default()
    };

    if options.dry_run {
        for asset in &assets {
            let original = library.original_path(asset);
            if exported.contains(&asset.uuid) {
                summary.skipped += 1;
            } else if original.is_file() {
                summary.exported += 1;
                summary.bytes += fs::metadata(&original).map_or(0, |m| m.len());
            } else {
                summary.not_downloaded += 1;
            }
        }
        return Ok(summary);
    }

    fs::create_dir_all(destination)
        .with_context(|| format!("creating destination {}", destination.display()))?;
    let mut manifest = Manifest::open(destination, options.layout)?;

    for asset in &assets {
        if manifest.contains(&asset.uuid) {
            summary.skipped += 1;
            continue;
        }
        if !destination.is_dir() {
            bail!(
                "the destination {} is no longer available. Reconnect the drive, then run again.",
                destination.display()
            );
        }
        if !library.original_path(asset).is_file() {
            summary.not_downloaded += 1;
            continue;
        }
        match export_item(
            &library,
            asset,
            destination,
            options,
            &all_originals,
            &mut manifest,
        ) {
            Ok(bytes) => {
                summary.exported += 1;
                summary.bytes += bytes;
            }
            Err(error) if is_disk_full(&error) => {
                // The marker stays, so the next run resumes from here.
                return Err(error.context("the destination is full; free up space, then run again"));
            }
            Err(error) => summary
                .failed
                .push((asset.filename.clone(), format!("{error:#}"))),
        }
    }

    let clean = summary.failed.is_empty() && summary.not_downloaded == 0;
    manifest.finish(clean)?;
    Ok(summary)
}

/// Writes every file of one item and records it. Returns the bytes written.
fn export_item(
    library: &Library,
    asset: &Asset,
    destination: &Path,
    options: Options,
    all_originals: &HashSet<PathBuf>,
    manifest: &mut Manifest,
) -> Result<u64> {
    let mut placed: Vec<Placed> = Vec::new();
    if let Err(error) = place_item(
        library,
        asset,
        destination,
        options,
        all_originals,
        &mut placed,
    ) {
        for file in placed.iter().filter(|file| file.created) {
            let _ = fs::remove_file(&file.absolute);
        }
        return Err(error);
    }

    let files: Vec<(String, String)> = placed
        .iter()
        .map(|f| (f.relative.clone(), f.sha.clone()))
        .collect();
    manifest.record(&asset.uuid, &files)?;
    Ok(placed.iter().map(|f| f.bytes).sum())
}

fn place_item(
    library: &Library,
    asset: &Asset,
    destination: &Path,
    options: Options,
    all_originals: &HashSet<PathBuf>,
    placed: &mut Vec<Placed>,
) -> Result<()> {
    let folder = match options.layout {
        Layout::Month => asset
            .created
            .map(|date| date.with_timezone(&Local).format("%Y/%m").to_string())
            .unwrap_or_else(|| "Unknown Date".to_owned()),
        Layout::Flat => String::new(),
    };
    let original = library.original_path(asset);
    let mut sources = vec![(original.clone(), safe_name(&asset.filename, &asset.uuid))];
    for companion in library.companions(asset, all_originals)? {
        if let Some(name) = companion
            .file_name()
            .map(|n| n.to_string_lossy().into_owned())
        {
            sources.push((companion, safe_name(&name, &asset.uuid)));
        }
    }
    if let Some(edited) = library.edited_path(asset) {
        let stem = Path::new(&asset.filename)
            .file_stem()
            .map(|s| s.to_string_lossy().into_owned())
            .unwrap_or_else(|| asset.uuid.clone());
        let extension = edited
            .extension()
            .map(|e| e.to_string_lossy().into_owned())
            .unwrap_or_default();
        sources.push((edited, format!("{stem}-edited.{extension}")));
    }

    let mut primary_name = None;
    for (source, name) in sources {
        let file = place(destination, &folder, &name, Source::File(source))?;
        primary_name.get_or_insert_with(|| file.name.clone());
        placed.push(file);
    }

    if options.write_xmp {
        if let Some(name) = primary_name {
            let sidecar = xmp::sidecar(asset).into_bytes();
            placed.push(place(
                destination,
                &folder,
                &format!("{name}.xmp"),
                Source::Bytes(sidecar),
            )?);
        }
    }
    Ok(())
}

enum Source {
    File(PathBuf),
    Bytes(Vec<u8>),
}

/// One file in the destination, as written by this item.
struct Placed {
    absolute: PathBuf,
    relative: String,
    name: String,
    sha: String,
    bytes: u64,
    /// False when an identical file was already there, so cleanup must leave it alone.
    created: bool,
}

/// Copies `source` into `destination/folder`, under `name` or, when a different file already has that
/// name, under ` (1)`, ` (2)` and so on. An identical file already there is reused, not duplicated.
fn place(destination: &Path, folder: &str, name: &str, source: Source) -> Result<Placed> {
    let directory = if folder.is_empty() {
        destination.to_path_buf()
    } else {
        destination.join(folder)
    };
    fs::create_dir_all(&directory).with_context(|| format!("creating {}", directory.display()))?;
    let partial = directory.join(format!(".{name}.partial"));

    let streamed = match &source {
        Source::File(path) => File::open(path)
            .map_err(anyhow::Error::from)
            .and_then(|input| copy_hashed(input, &partial)),
        Source::Bytes(data) => copy_hashed(&data[..], &partial),
    };
    let (bytes, sha) = match streamed {
        Ok(result) => result,
        Err(error) => {
            let _ = fs::remove_file(&partial);
            return Err(error.context(format!("copying {name}")));
        }
    };

    let result = (|| -> Result<(PathBuf, bool)> {
        for attempt in 0..10_000usize {
            let candidate = if attempt == 0 {
                name.to_owned()
            } else {
                numbered(name, attempt)
            };
            let target = directory.join(&candidate);
            if !target.exists() {
                fs::rename(&partial, &target).with_context(|| format!("placing {candidate}"))?;
                if sha256_file(&target)? != sha {
                    let _ = fs::remove_file(&target);
                    bail!("{candidate} doesn't match what was copied");
                }
                return Ok((target, true));
            }
            if sha256_file(&target)? == sha {
                fs::remove_file(&partial)?;
                return Ok((target, false));
            }
        }
        bail!("no free name for {name}");
    })();

    match result {
        Ok((absolute, created)) => {
            let file_name = absolute
                .file_name()
                .map(|n| n.to_string_lossy().into_owned())
                .unwrap_or_default();
            let relative = if folder.is_empty() {
                file_name.clone()
            } else {
                format!("{folder}/{file_name}")
            };
            Ok(Placed {
                absolute,
                relative,
                name: file_name,
                sha,
                bytes,
                created,
            })
        }
        Err(error) => {
            let _ = fs::remove_file(&partial);
            Err(error)
        }
    }
}

/// Streams `input` to `to`, returning the byte count and its SHA-256.
fn copy_hashed(mut input: impl Read, to: &Path) -> Result<(u64, String)> {
    let mut output = File::create(to).with_context(|| format!("creating {}", to.display()))?;
    let mut hasher = Sha256::new();
    let mut buffer = vec![0u8; 1 << 20];
    let mut total = 0u64;
    loop {
        let read = match input.read(&mut buffer) {
            Ok(0) => break,
            Ok(read) => read,
            Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
            Err(error) => return Err(error.into()),
        };
        hasher.update(&buffer[..read]);
        output.write_all(&buffer[..read])?;
        total += read as u64;
    }
    output.sync_all()?;
    Ok((total, format!("{:x}", hasher.finalize())))
}

pub fn sha256_file(path: &Path) -> Result<String> {
    let mut input = File::open(path).with_context(|| format!("opening {}", path.display()))?;
    let mut hasher = Sha256::new();
    io::copy(&mut input, &mut hasher)?;
    Ok(format!("{:x}", hasher.finalize()))
}

/// `IMG_0001.HEIC` → `IMG_0001 (1).HEIC`.
fn numbered(name: &str, number: usize) -> String {
    match name.rfind('.') {
        Some(dot) if dot > 0 => format!("{} ({number}){}", &name[..dot], &name[dot..]),
        _ => format!("{name} ({number})"),
    }
}

/// Keeps a file name usable as a single path component on macOS.
fn safe_name(name: &str, fallback: &str) -> String {
    let cleaned: String = name
        .chars()
        .map(|c| {
            if c == '/' || c == ':' || c.is_control() {
                '_'
            } else {
                c
            }
        })
        .collect();
    if cleaned.trim().is_empty() {
        fallback.to_owned()
    } else {
        cleaned
    }
}

fn is_disk_full(error: &anyhow::Error) -> bool {
    error.chain().any(|cause| {
        cause
            .downcast_ref::<io::Error>()
            .is_some_and(|e| e.kind() == io::ErrorKind::StorageFull)
    })
}

fn human_bytes(bytes: u64) -> String {
    const UNITS: [&str; 5] = ["B", "KB", "MB", "GB", "TB"];
    let mut value = bytes as f64;
    let mut unit = 0;
    while value >= 1024.0 && unit < UNITS.len() - 1 {
        value /= 1024.0;
        unit += 1;
    }
    if unit == 0 {
        format!("{bytes} B")
    } else {
        format!("{value:.1} {}", UNITS[unit])
    }
}
