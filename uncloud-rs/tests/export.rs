//! End-to-end checks against a fake Photos library: a SQLite database plus `originals/` and
//! `resources/renders/` folders laid out the way Photos stores them.

use rusqlite::{params, Connection};
use std::fs;
use std::path::{Path, PathBuf};
use uncloud_rs::{export, manifest, Layout, Options};

struct FakeLibrary {
    root: PathBuf,
}

impl FakeLibrary {
    fn new(base: &Path) -> Self {
        let root = base.join("Photos Library.photoslibrary");
        fs::create_dir_all(root.join("database")).unwrap();
        fs::create_dir_all(root.join("originals/A")).unwrap();
        fs::create_dir_all(root.join("originals/B")).unwrap();
        fs::create_dir_all(root.join("resources/renders/A")).unwrap();
        let db = Connection::open(root.join("database/Photos.sqlite")).unwrap();
        db.execute_batch(
            "CREATE TABLE ZASSET (
                Z_PK INTEGER PRIMARY KEY, ZUUID TEXT, ZFILENAME TEXT, ZDIRECTORY TEXT,
                ZDATECREATED REAL, ZMODIFICATIONDATE REAL, ZFAVORITE INTEGER, ZHIDDEN INTEGER,
                ZKIND INTEGER, ZLATITUDE REAL, ZLONGITUDE REAL, ZTRASHEDSTATE INTEGER);",
        )
        .unwrap();
        Self { root }
    }

    /// `created` is in Core Data seconds since 2001-01-01 UTC.
    #[allow(clippy::too_many_arguments)]
    fn insert(
        &self,
        pk: i64,
        uuid: &str,
        filename: &str,
        dir: &str,
        created: f64,
        favorite: i64,
        trashed: i64,
    ) {
        let db = Connection::open(self.root.join("database/Photos.sqlite")).unwrap();
        db.execute(
            "INSERT INTO ZASSET VALUES (?1, ?2, ?3, ?4, ?5, ?5, ?6, 0, 0, 48.8566, 2.3522, ?7)",
            params![pk, uuid, filename, dir, created, favorite, trashed],
        )
        .unwrap();
    }

    fn write_original(&self, dir: &str, name: &str, contents: &[u8]) {
        fs::write(self.root.join("originals").join(dir).join(name), contents).unwrap();
    }
}

/// 2023-03-07 12:00 UTC, as seconds since 2001-01-01 (noon keeps the month right in any time zone).
const MARCH_2023: f64 = 699_883_200.0;

fn options(layout: Layout) -> Options {
    Options {
        layout,
        write_xmp: false,
        dry_run: false,
    }
}

#[test]
fn month_export_resumes_and_verifies() {
    let base = tempfile::tempdir().unwrap();
    let library = FakeLibrary::new(base.path());
    library.insert(1, "AAAA-1111", "IMG_0001.HEIC", "A", MARCH_2023, 1, 0);
    library.insert(
        2,
        "BBBB-2222",
        "IMG_0002.HEIC",
        "B",
        MARCH_2023 + 60.0,
        0,
        0,
    ); // only in iCloud
    library.insert(
        3,
        "CCCC-3333",
        "IMG_0003.JPG",
        "A",
        MARCH_2023 + 120.0,
        0,
        1,
    ); // trashed
    library.write_original("A", "IMG_0001.HEIC", b"heic-bytes");
    library.write_original("A", "IMG_0001.MOV", b"live-movie");
    fs::write(
        library
            .root
            .join("resources/renders/A/AAAA-1111_1_201_a.jpeg"),
        b"edited",
    )
    .unwrap();

    let destination = base.path().join("out");
    let first = export::run(&library.root, &destination, options(Layout::Month)).unwrap();
    assert_eq!(first.exported, 1);
    assert_eq!(first.not_downloaded, 1);
    assert!(first.failed.is_empty());

    let photo = destination.join("2023/03/IMG_0001.HEIC");
    assert_eq!(fs::read(&photo).unwrap(), b"heic-bytes");
    assert_eq!(
        fs::read(destination.join("2023/03/IMG_0001.MOV")).unwrap(),
        b"live-movie"
    );
    assert_eq!(
        fs::read(destination.join("2023/03/IMG_0001-edited.jpeg")).unwrap(),
        b"edited"
    );
    assert!(
        !destination.join("2023/03/IMG_0003.JPG").exists(),
        "trashed items are skipped"
    );
    assert!(
        destination.join(".photo-export/run-in-progress").exists(),
        "marker stays while an item is still only in iCloud"
    );

    let second = export::run(&library.root, &destination, options(Layout::Month)).unwrap();
    assert_eq!(second.exported, 0);
    assert_eq!(second.skipped, 1);
    assert_eq!(second.not_downloaded, 1);

    // Once the iCloud-only original shows up, the next run picks it up.
    library.write_original("B", "IMG_0002.HEIC", b"second");
    let third = export::run(&library.root, &destination, options(Layout::Month)).unwrap();
    assert_eq!(third.exported, 1);
    assert!(!destination.join(".photo-export/run-in-progress").exists());

    let report = manifest::verify(&destination).unwrap();
    assert_eq!(report.checked, 4);
    assert!(report.is_ok(), "{report:?}");

    fs::write(&photo, b"tampered").unwrap();
    let report = manifest::verify(&destination).unwrap();
    assert_eq!(report.changed, vec!["2023/03/IMG_0001.HEIC".to_owned()]);
}

#[test]
fn flat_layout_numbers_clashing_names_and_keeps_identical_files() {
    let base = tempfile::tempdir().unwrap();
    let library = FakeLibrary::new(base.path());
    library.insert(1, "AAAA-1111", "IMG_0001.HEIC", "A", MARCH_2023, 0, 0);
    library.insert(
        2,
        "BBBB-2222",
        "IMG_0001.HEIC",
        "B",
        MARCH_2023 + 10.0,
        0,
        0,
    );
    library.write_original("A", "IMG_0001.HEIC", b"one");
    library.write_original("B", "IMG_0001.HEIC", b"two");

    let destination = base.path().join("flat");
    let summary = export::run(&library.root, &destination, options(Layout::Flat)).unwrap();
    assert_eq!(summary.exported, 2);
    assert_eq!(fs::read(destination.join("IMG_0001.HEIC")).unwrap(), b"one");
    assert_eq!(
        fs::read(destination.join("IMG_0001 (1).HEIC")).unwrap(),
        b"two"
    );

    // A run that stopped before recording an item leaves its file behind. Re-exporting that item
    // must reuse the identical file, not write a second copy.
    library.insert(
        3,
        "CCCC-3333",
        "IMG_0002.HEIC",
        "A",
        MARCH_2023 + 20.0,
        0,
        0,
    );
    library.write_original("A", "IMG_0002.HEIC", b"three");
    fs::write(destination.join("IMG_0002.HEIC"), b"three").unwrap();
    let summary = export::run(&library.root, &destination, options(Layout::Flat)).unwrap();
    assert_eq!(summary.exported, 1);
    assert!(!destination.join("IMG_0002 (1).HEIC").exists());
}

#[test]
fn dry_run_writes_nothing() {
    let base = tempfile::tempdir().unwrap();
    let library = FakeLibrary::new(base.path());
    library.insert(1, "AAAA-1111", "IMG_0001.HEIC", "A", MARCH_2023, 0, 0);
    library.write_original("A", "IMG_0001.HEIC", b"x");
    let destination = base.path().join("dry");
    let summary = export::run(
        &library.root,
        &destination,
        Options {
            layout: Layout::Month,
            write_xmp: false,
            dry_run: true,
        },
    )
    .unwrap();
    assert_eq!(summary.exported, 1);
    assert!(!destination.exists());
}

#[test]
fn xmp_sidecar_is_written_next_to_the_photo() {
    let base = tempfile::tempdir().unwrap();
    let library = FakeLibrary::new(base.path());
    library.insert(1, "AAAA-1111", "IMG_0001.HEIC", "A", MARCH_2023, 1, 0);
    library.write_original("A", "IMG_0001.HEIC", b"x");
    let destination = base.path().join("xmp");
    export::run(
        &library.root,
        &destination,
        Options {
            layout: Layout::Month,
            write_xmp: true,
            dry_run: false,
        },
    )
    .unwrap();
    let sidecar = fs::read_to_string(destination.join("2023/03/IMG_0001.HEIC.xmp")).unwrap();
    assert!(sidecar.contains("xmp:Rating=\"5\""));
    assert!(sidecar.contains("exif:GPSLatitude=\"48,"));
    assert!(sidecar.contains("xmp:CreateDate=\"2023-03-"));
}

#[test]
fn rejects_a_folder_that_is_not_a_library() {
    let base = tempfile::tempdir().unwrap();
    let error = export::run(
        base.path(),
        &base.path().join("out"),
        options(Layout::Month),
    )
    .unwrap_err();
    assert!(format!("{error:#}").contains("Photos.sqlite"));
}
