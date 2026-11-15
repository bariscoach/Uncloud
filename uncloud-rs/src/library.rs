//! Read-only access to a `Photos Library.photoslibrary` bundle.
//!
//! The library database is copied (with its write-ahead log) to a temporary folder before it's
//! opened, so reading never locks or changes the live library.

use anyhow::{ensure, Context, Result};
use chrono::{DateTime, TimeZone, Utc};
use rusqlite::{Connection, OpenFlags};
use std::cell::RefCell;
use std::collections::{HashMap, HashSet};
use std::fs;
use std::path::{Path, PathBuf};
use tempfile::TempDir;

/// Seconds from 1970-01-01 to Core Data's reference date, 2001-01-01 UTC.
const CORE_DATA_EPOCH_OFFSET: i64 = 978_307_200;

/// Photos stores -180 as "no location".
const NO_COORDINATE: f64 = -180.0;

/// Extensions Photos uses for rendered edits (`resources/renders/<c>/<UUID>_1_201_a.<ext>`).
const EDITED_IMAGE_EXTENSIONS: [&str; 3] = ["jpeg", "heic", "png"];
const EDITED_VIDEO_EXTENSIONS: [&str; 2] = ["mp4", "mov"];

#[derive(Debug, Clone)]
pub struct Asset {
    pub uuid: String,
    /// The original file's name, such as `IMG_0001.HEIC`.
    pub filename: String,
    /// The original's folder inside `originals/`, a single character such as `A`.
    pub directory: String,
    pub created: Option<DateTime<Utc>>,
    pub modified: Option<DateTime<Utc>>,
    pub favorite: bool,
    pub hidden: bool,
    pub is_video: bool,
    pub latitude: Option<f64>,
    pub longitude: Option<f64>,
}

pub struct Library {
    root: PathBuf,
    db: Connection,
    /// Keeps the copied database alive for as long as the library is open.
    _copy: TempDir,
    /// File names per original folder, so companion lookups don't re-list the folder for every item.
    dir_cache: RefCell<HashMap<PathBuf, Vec<String>>>,
}

impl Library {
    pub fn open(root: &Path) -> Result<Self> {
        let db_source = root.join("database").join("Photos.sqlite");
        ensure!(
            db_source.is_file(),
            "{} has no database/Photos.sqlite, so it isn't a Photos library",
            root.display()
        );

        let copy =
            tempfile::tempdir().context("creating a temporary folder for the library database")?;
        for name in ["Photos.sqlite", "Photos.sqlite-wal"] {
            let source = db_source.with_file_name(name);
            if source.is_file() {
                fs::copy(&source, copy.path().join(name))
                    .with_context(|| format!("copying {}", source.display()))?;
            }
        }
        let db = Connection::open_with_flags(
            copy.path().join("Photos.sqlite"),
            OpenFlags::SQLITE_OPEN_READ_ONLY,
        )
        .context("opening the copied Photos database")?;

        Ok(Self {
            root: root.to_path_buf(),
            db,
            _copy: copy,
            dir_cache: RefCell::new(HashMap::new()),
        })
    }

    /// Every library item that isn't in the Recently Deleted folder, oldest first.
    pub fn assets(&self) -> Result<Vec<Asset>> {
        let mut statement = self.db.prepare(
            "SELECT ZUUID, ZFILENAME, ZDIRECTORY, ZDATECREATED, ZMODIFICATIONDATE,
                    ZFAVORITE, ZHIDDEN, ZKIND, ZLATITUDE, ZLONGITUDE
             FROM ZASSET
             WHERE ZTRASHEDSTATE = 0 AND ZUUID IS NOT NULL
               AND ZFILENAME IS NOT NULL AND ZDIRECTORY IS NOT NULL
             ORDER BY ZDATECREATED, Z_PK",
        )?;
        let rows = statement.query_map([], |row| {
            let latitude: Option<f64> = row.get(8)?;
            let longitude: Option<f64> = row.get(9)?;
            let located =
                |value: Option<f64>| value.filter(|v| v.is_finite() && *v != NO_COORDINATE);
            Ok(Asset {
                uuid: row.get(0)?,
                filename: row.get(1)?,
                directory: row.get(2)?,
                created: core_data_date(row.get(3)?),
                modified: core_data_date(row.get(4)?),
                favorite: row.get::<_, Option<i64>>(5)?.unwrap_or(0) != 0,
                hidden: row.get::<_, Option<i64>>(6)?.unwrap_or(0) != 0,
                is_video: row.get::<_, Option<i64>>(7)?.unwrap_or(0) == 1,
                latitude: located(latitude),
                longitude: located(longitude),
            })
        })?;
        rows.collect::<rusqlite::Result<Vec<_>>>()
            .context("reading the library's items")
    }

    /// Where the original of `asset` lives. It may be missing when the item is only in iCloud.
    pub fn original_path(&self, asset: &Asset) -> PathBuf {
        self.root
            .join("originals")
            .join(&asset.directory)
            .join(&asset.filename)
    }

    /// The rendered edit of `asset`, if it has one on this Mac.
    pub fn edited_path(&self, asset: &Asset) -> Option<PathBuf> {
        let folder = self
            .root
            .join("resources")
            .join("renders")
            .join(asset.uuid.chars().next()?.to_string());
        let candidates = EDITED_IMAGE_EXTENSIONS
            .iter()
            .map(|ext| format!("{}_1_201_a.{ext}", asset.uuid))
            .chain(
                EDITED_VIDEO_EXTENSIONS
                    .iter()
                    .map(|ext| format!("{}_2_201_a.{ext}", asset.uuid)),
            );
        candidates
            .map(|name| folder.join(name))
            .find(|path| path.is_file())
    }

    /// Files in the original's folder that share its name, such as a RAW's JPEG or a Live Photo's
    /// movie. Other items' originals are never returned, even when they share the name.
    pub fn companions(
        &self,
        asset: &Asset,
        all_originals: &HashSet<PathBuf>,
    ) -> Result<Vec<PathBuf>> {
        let primary = self.original_path(asset);
        let (Some(folder), Some(stem)) = (primary.parent(), primary.file_stem()) else {
            return Ok(Vec::new());
        };
        let names = self.list_folder(folder)?;
        Ok(names
            .into_iter()
            .filter(|name| !name.starts_with('.') && *name != asset.filename)
            .map(|name| folder.join(name))
            .filter(|path| path.file_stem() == Some(stem) && !all_originals.contains(path))
            .collect())
    }

    fn list_folder(&self, folder: &Path) -> Result<Vec<String>> {
        if let Some(names) = self.dir_cache.borrow().get(folder) {
            return Ok(names.clone());
        }
        let names: Vec<String> = match fs::read_dir(folder) {
            Ok(entries) => entries
                .filter_map(|entry| entry.ok()?.file_name().into_string().ok())
                .collect(),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Vec::new(),
            Err(error) => {
                return Err(error).with_context(|| format!("listing {}", folder.display()))
            }
        };
        self.dir_cache
            .borrow_mut()
            .insert(folder.to_path_buf(), names.clone());
        Ok(names)
    }
}

fn core_data_date(seconds: Option<f64>) -> Option<DateTime<Utc>> {
    let seconds = seconds?;
    if !seconds.is_finite() {
        return None;
    }
    let whole = seconds.floor() as i64 + CORE_DATA_EPOCH_OFFSET;
    let nanos = ((seconds - seconds.floor()) * 1e9) as u32;
    Utc.timestamp_opt(whole, nanos).single()
}
