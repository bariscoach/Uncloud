//! The `.photo-export/` folder inside a destination. Same files as the Uncloud app:
//!
//! - `exported.tsv`: one line per item, `<UUID><TAB><relative path>…`, append-only
//! - `checksums.tsv`: one line per file, `<relative path><TAB><sha256>`
//! - `run-in-progress`: present until a run finishes with nothing failed or pending
//! - `layout`: the layout the most recent run used

use anyhow::{bail, Context, Result};
use std::collections::HashSet;
use std::fs::{self, File, OpenOptions};
use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};

pub const FOLDER_NAME: &str = ".photo-export";
const JOURNAL: &str = "exported.tsv";
const CHECKSUMS: &str = "checksums.tsv";
const MARKER: &str = "run-in-progress";
const LAYOUT: &str = "layout";

#[derive(Clone, Copy, Debug, PartialEq, Eq, clap::ValueEnum)]
pub enum Layout {
    /// `2024/07/IMG_0001.HEIC`, by the date the photo was taken (local time).
    Month,
    /// `IMG_0001.HEIC`, with no subfolders. Name clashes get ` (1)`, ` (2)`, and so on.
    Flat,
}

impl Layout {
    pub fn as_str(self) -> &'static str {
        match self {
            Layout::Month => "month",
            Layout::Flat => "flat",
        }
    }

    pub fn parse(text: &str) -> Option<Self> {
        match text.trim() {
            "month" => Some(Layout::Month),
            "flat" => Some(Layout::Flat),
            _ => None,
        }
    }
}

pub fn folder_of(destination: &Path) -> PathBuf {
    destination.join(FOLDER_NAME)
}

/// Reads the UUIDs already recorded in `exported.tsv`. Doesn't create or change anything.
pub fn read_exported(destination: &Path) -> Result<HashSet<String>> {
    Ok(read_lines(&folder_of(destination).join(JOURNAL))?
        .iter()
        .filter_map(|line| line.split('\t').next().map(str::to_owned))
        .filter(|id| !id.is_empty())
        .collect())
}

/// Read and append handle for an export run.
pub struct Manifest {
    folder: PathBuf,
    exported: HashSet<String>,
    journal: File,
    checksums: File,
}

impl Manifest {
    /// Opens the manifest for a run. Creates `.photo-export/` if needed and marks the run in progress.
    pub fn open(destination: &Path, layout: Layout) -> Result<Self> {
        let folder = folder_of(destination);
        fs::create_dir_all(&folder).with_context(|| format!("creating {}", folder.display()))?;
        let exported = read_exported(destination)?;
        let manifest = Self {
            journal: append_handle(&folder.join(JOURNAL))?,
            checksums: append_handle(&folder.join(CHECKSUMS))?,
            exported,
            folder,
        };
        fs::write(manifest.folder.join(MARKER), b"").context("writing run-in-progress marker")?;
        fs::write(manifest.folder.join(LAYOUT), layout.as_str()).context("writing layout")?;
        Ok(manifest)
    }

    pub fn contains(&self, uuid: &str) -> bool {
        self.exported.contains(uuid)
    }

    /// Records an item and its files. Checksums are written first, so every journal entry has them.
    pub fn record(&mut self, uuid: &str, files: &[(String, String)]) -> Result<()> {
        let mut checksum_lines = String::new();
        for (path, sha) in files {
            checksum_lines.push_str(&format!("{path}\t{sha}\n"));
        }
        self.checksums.write_all(checksum_lines.as_bytes())?;
        self.checksums.sync_data()?;

        let mut journal_line = uuid.to_owned();
        for (path, _) in files {
            journal_line.push('\t');
            journal_line.push_str(path);
        }
        journal_line.push('\n');
        self.journal.write_all(journal_line.as_bytes())?;
        self.journal.sync_data()?;
        self.exported.insert(uuid.to_owned());
        Ok(())
    }

    /// Clears the in-progress marker when the run finished cleanly.
    pub fn finish(self, clean: bool) -> Result<()> {
        if clean {
            let marker = self.folder.join(MARKER);
            if marker.exists() {
                fs::remove_file(&marker).context("removing run-in-progress marker")?;
            }
        }
        Ok(())
    }
}

fn append_handle(path: &Path) -> Result<File> {
    OpenOptions::new()
        .create(true)
        .append(true)
        .open(path)
        .with_context(|| format!("opening {}", path.display()))
}

fn read_lines(path: &Path) -> Result<Vec<String>> {
    match File::open(path) {
        Ok(file) => BufReader::new(file)
            .lines()
            .collect::<std::io::Result<Vec<_>>>()
            .with_context(|| format!("reading {}", path.display())),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(Vec::new()),
        Err(error) => Err(error).with_context(|| format!("opening {}", path.display())),
    }
}

#[derive(Debug, Default)]
pub struct VerifyReport {
    pub checked: usize,
    pub missing: Vec<String>,
    pub changed: Vec<String>,
}

impl VerifyReport {
    pub fn is_ok(&self) -> bool {
        self.missing.is_empty() && self.changed.is_empty()
    }
}

/// Re-hashes every file in `checksums.tsv` and reports the ones that are missing or changed.
pub fn verify(destination: &Path) -> Result<VerifyReport> {
    let folder = folder_of(destination);
    let lines = read_lines(&folder.join(CHECKSUMS))?;
    if lines.is_empty() {
        bail!(
            "no checksums.tsv in {}; nothing has been exported there yet",
            folder.display()
        );
    }
    let mut report = VerifyReport::default();
    for line in lines {
        let Some((relative, expected)) = line.split_once('\t') else {
            continue;
        };
        report.checked += 1;
        let path = destination.join(relative);
        if !path.is_file() {
            report.missing.push(relative.to_owned());
            continue;
        }
        match crate::export::sha256_file(&path) {
            Ok(actual) if actual == expected => {}
            Ok(_) => report.changed.push(relative.to_owned()),
            Err(_) => report.missing.push(relative.to_owned()),
        }
    }
    Ok(report)
}

/// Prints what the destination holds.
pub fn status(destination: &Path) -> Result<()> {
    let folder = folder_of(destination);
    if !folder.is_dir() {
        println!("{} has no export yet.", destination.display());
        return Ok(());
    }
    let exported = read_exported(destination)?.len();
    let files = read_lines(&folder.join(CHECKSUMS))?.len();
    let layout = fs::read_to_string(folder.join(LAYOUT)).unwrap_or_default();
    println!("Destination:  {}", destination.display());
    println!("Items:        {exported}");
    println!("Files:        {files}");
    println!(
        "Layout:       {}",
        if layout.trim().is_empty() {
            "unknown"
        } else {
            layout.trim()
        }
    );
    if folder.join(MARKER).exists() {
        println!("Status:       incomplete (run export again to resume)");
    } else {
        println!("Status:       complete");
    }
    Ok(())
}
