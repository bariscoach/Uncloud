use anyhow::{Context, Result};
use clap::{Parser, Subcommand};
use std::path::PathBuf;
use uncloud_rs::{export, manifest, Layout, Options};

/// Copies your Photos library, including originals, edits, RAW pairs and Live Photo movies,
/// into a folder. Re-running picks up where the last run stopped.
#[derive(Parser)]
#[command(name = "uncloud-rs", version)]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand)]
enum Command {
    /// Copy every library item that isn't in the destination yet.
    Export {
        /// The Photos library. Defaults to ~/Pictures/Photos Library.photoslibrary.
        #[arg(long)]
        library: Option<PathBuf>,
        /// The destination folder. Created if needed.
        #[arg(long)]
        to: PathBuf,
        /// How files are arranged in the destination.
        #[arg(long, value_enum, default_value_t = Layout::Month)]
        layout: Layout,
        /// Write an .xmp sidecar next to each exported file (dates, favorite, location).
        #[arg(long)]
        xmp: bool,
        /// Count what would be exported without copying anything.
        #[arg(long)]
        dry_run: bool,
    },
    /// Re-hash every exported file and compare it with checksums.tsv.
    Verify {
        #[arg(long)]
        to: PathBuf,
    },
    /// Show what the destination holds and whether the last run finished.
    Status {
        #[arg(long)]
        to: PathBuf,
    },
}

fn main() {
    if let Err(error) = run() {
        eprintln!("error: {error:#}");
        std::process::exit(1);
    }
}

fn run() -> Result<()> {
    match Cli::parse().command {
        Command::Export {
            library,
            to,
            layout,
            xmp,
            dry_run,
        } => {
            let library = match library {
                Some(path) => path,
                None => default_library()?,
            };
            let options = Options {
                layout,
                write_xmp: xmp,
                dry_run,
            };
            let summary = export::run(&library, &to, options)?;
            print!("{summary}");
            if !summary.failed.is_empty() {
                std::process::exit(2);
            }
        }
        Command::Verify { to } => {
            let report = manifest::verify(&to)?;
            println!("checked {} files", report.checked);
            for path in &report.missing {
                println!("missing: {path}");
            }
            for path in &report.changed {
                println!("changed: {path}");
            }
            if report.is_ok() {
                println!("all files match");
            } else {
                std::process::exit(2);
            }
        }
        Command::Status { to } => manifest::status(&to)?,
    }
    Ok(())
}

fn default_library() -> Result<PathBuf> {
    let home = std::env::var_os("HOME").context("HOME isn't set; pass --library")?;
    Ok(PathBuf::from(home)
        .join("Pictures")
        .join("Photos Library.photoslibrary"))
}
