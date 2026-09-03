//! `tree.rs` must not descend eagerly, and must honour `.gitignore`.
//!
//! Research 2.8 makes the stakes concrete: a large source tree (`~/src`) holds 608,597
//! files, so a walk that descends when it was not asked to is a multi-second
//! hang in the sidebar rather than a slightly slow test. The assertions here
//! are on the *number of directory reads*, not on the returned entries, because
//! a correct-looking listing produced by walking everything is exactly the bug
//! this guards against.
//!
//! The fixture is built at test time rather than committed: a committed
//! `.gitignore` inside a fixture tree would make git skip the very files the
//! ignore test needs to see.

use std::fs;
use std::path::Path;
use std::sync::{Mutex, MutexGuard};

use mark_core::tree::{self, Options};
use tempfile::TempDir;

/// `dir_reads`/`file_reads` are process-global counters, so every test in this
/// file takes this lock: a test that merely walks would otherwise inflate a
/// concurrent test's measured delta.
static COUNTERS: Mutex<()> = Mutex::new(());

fn measuring() -> MutexGuard<'static, ()> {
    COUNTERS
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

/// ```text
/// root/
///   README.md
///   notes.md
///   .hidden.md
///   .gitignore            -> "ignored/\nsecret.md\n"
///   secret.md
///   ignored/deep.md
///   docs/
///     guide.md
///     nested/
///       deeper/
///         buried.md
///   .git/config
/// ```
fn fixture() -> TempDir {
    let dir = tempfile::tempdir().expect("tempdir");
    let root = dir.path();

    let write = |path: &Path, body: &str| {
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent).expect("create fixture dirs");
        }
        fs::write(path, body).expect("write fixture file");
    };

    write(
        &root.join("README.md"),
        "# Readme\n\n- [ ] one\n- [x] two\n",
    );
    write(&root.join("notes.md"), "## Notes\n\nno tasks here\n");
    write(&root.join(".hidden.md"), "# Hidden\n");
    write(&root.join(".gitignore"), "ignored/\nsecret.md\n");
    write(&root.join("secret.md"), "# Secret\n");
    write(&root.join("ignored/deep.md"), "# Ignored\n");
    write(&root.join("docs/guide.md"), "# Guide\n");
    write(&root.join("docs/nested/deeper/buried.md"), "# Buried\n");
    write(&root.join(".git/config"), "[core]\n");
    write(&root.join("notes.txt"), "not markdown\n");

    dir
}

fn names(entries: &[tree::Entry]) -> Vec<String> {
    entries.iter().map(|e| e.name.clone()).collect()
}

#[test]
fn one_call_reads_exactly_one_directory() {
    let _serial = measuring();
    let dir = fixture();

    let before = tree::dir_reads();
    let entries = tree::list_dir(dir.path(), &Options::default()).expect("list");
    let reads = tree::dir_reads() - before;

    assert_eq!(reads, 1, "listing one level read {reads} directories");
    // `docs` is listed, but not descended into.
    assert_eq!(names(&entries), vec!["docs", "README.md", "notes.md"]);
}

#[test]
fn depth_bounds_the_number_of_directory_reads() {
    let _serial = measuring();
    let dir = fixture();

    // depth 2 sees root and `docs`, and `docs/nested` is listed but not read.
    let before = tree::dir_reads();
    let entries = tree::list_dir(
        dir.path(),
        &Options {
            max_depth: 2,
            ..Options::default()
        },
    )
    .expect("list");
    let reads = tree::dir_reads() - before;

    assert_eq!(reads, 2, "depth 2 read {reads} directories");
    assert_eq!(
        names(&entries),
        vec!["docs", "nested", "guide.md", "README.md", "notes.md"]
    );
    assert!(
        !entries.iter().any(|e| e.name == "buried.md"),
        "descended past the requested depth"
    );
}

#[test]
fn a_deep_walk_reads_each_directory_exactly_once() {
    let _serial = measuring();
    let dir = fixture();

    let before = tree::dir_reads();
    let entries = tree::list_dir(
        dir.path(),
        &Options {
            max_depth: 64,
            ..Options::default()
        },
    )
    .expect("list");
    let reads = tree::dir_reads() - before;

    // root, docs, docs/nested, docs/nested/deeper. Not `.git`, not `ignored`.
    assert_eq!(reads, 4, "deep walk read {reads} directories");
    assert!(entries.iter().any(|e| e.name == "buried.md"));
}

#[test]
fn stats_are_opt_in_and_no_file_is_opened_without_them() {
    let _serial = measuring();
    let dir = fixture();

    let before = tree::file_reads();
    let entries = tree::list_dir(dir.path(), &Options::default()).expect("list");
    assert_eq!(
        tree::file_reads() - before,
        0,
        "opened files without with_stats"
    );
    assert!(
        entries
            .iter()
            .all(|e| e.title.is_none() && e.tasks.is_none())
    );

    let before = tree::file_reads();
    let entries = tree::list_dir(
        dir.path(),
        &Options {
            with_stats: true,
            ..Options::default()
        },
    )
    .expect("list");
    // Exactly the two markdown files at depth 1.
    assert_eq!(tree::file_reads() - before, 2);

    let readme = entries
        .iter()
        .find(|e| e.name == "README.md")
        .expect("README");
    assert_eq!(readme.title.as_deref(), Some("Readme"));
    let counts = readme.tasks.expect("task counts");
    assert_eq!((counts.open, counts.total), (1, 2));
}

#[test]
fn gitignored_paths_are_skipped_and_never_descended_into() {
    let _serial = measuring();
    let dir = fixture();

    let before = tree::dir_reads();
    let entries = tree::list_dir(
        dir.path(),
        &Options {
            max_depth: 64,
            ..Options::default()
        },
    )
    .expect("list");
    let reads = tree::dir_reads() - before;

    assert!(
        !entries.iter().any(|e| e.name == "secret.md"),
        "a gitignored file was listed"
    );
    assert!(
        !entries.iter().any(|e| e.name == "ignored"),
        "a gitignored directory was listed"
    );
    assert!(
        !entries.iter().any(|e| e.name == "deep.md"),
        "descended into a gitignored directory"
    );
    // Four reads, not five: `ignored/` was never opened.
    assert_eq!(reads, 4);
}

/// Ancestor ignore rules keep their own anchoring when a subdirectory is
/// listed.
///
/// The regression: every ancestor's patterns were folded into one matcher
/// rooted at the *listed* directory, which re-anchors anything path-bearing.
/// With a repository-root `.gitignore` of `/rooted.md` + `sub/ignored.md`,
/// listing `sub/` hid `sub/rooted.md` (git keeps it — the pattern is anchored
/// at the repository root) and showed `sub/ignored.md` (git hides it). Both
/// directions wrong, both silent.
#[test]
fn ancestor_ignore_rules_keep_their_own_anchor() {
    let _serial = measuring();
    let dir = tempfile::tempdir().expect("tempdir");
    let root = dir.path();

    fs::create_dir_all(root.join(".git")).expect("fake git dir");
    fs::create_dir_all(root.join("sub/build")).expect("dirs");
    fs::write(
        root.join(".gitignore"),
        "/rooted.md\nsub/ignored.md\nbuild/\n",
    )
    .expect("gitignore");
    for name in ["rooted.md", "ignored.md", "kept.md"] {
        fs::write(root.join("sub").join(name), "# x\n").expect("write");
    }
    fs::write(root.join("rooted.md"), "# x\n").expect("write");
    fs::write(root.join("sub/build/x.md"), "# x\n").expect("write");

    let listed = |from: &Path| -> Vec<String> {
        names(
            &tree::list_dir(
                from,
                &Options {
                    max_depth: 64,
                    ..Options::default()
                },
            )
            .expect("list"),
        )
    };

    // Listing the subdirectory: `sub/ignored.md` matches the repository-root
    // pattern, `/rooted.md` does not, and `build/` is unanchored so it does.
    let sub = listed(&root.join("sub"));
    assert!(sub.contains(&"kept.md".to_owned()), "{sub:?}");
    assert!(sub.contains(&"rooted.md".to_owned()), "{sub:?}");
    assert!(!sub.contains(&"ignored.md".to_owned()), "{sub:?}");
    assert!(!sub.contains(&"build".to_owned()), "{sub:?}");

    // ...and listing the repository root reaches the same verdict per path,
    // which is the property that used to depend on where the walk started.
    let whole = tree::list_dir(
        root,
        &Options {
            max_depth: 64,
            ..Options::default()
        },
    )
    .expect("list");
    let relative: Vec<String> = whole
        .iter()
        .filter_map(|entry| entry.path.strip_prefix(root).ok())
        .map(|path| path.to_string_lossy().into_owned())
        .collect();
    assert!(!relative.contains(&"rooted.md".to_owned()), "{relative:?}");
    assert!(
        relative.contains(&"sub/rooted.md".to_owned()),
        "{relative:?}"
    );
    assert!(
        !relative.contains(&"sub/ignored.md".to_owned()),
        "{relative:?}"
    );
    assert!(relative.contains(&"sub/kept.md".to_owned()), "{relative:?}");
}

/// A relative path and an absolute path to the same directory must produce the
/// same verdicts. Ignore matching used to depend on the process's cwd, so
/// `mark ls sub` and `mark ls /abs/sub` could disagree.
#[test]
fn relative_and_absolute_roots_agree() {
    let _serial = measuring();
    let dir = fixture();
    let absolute = names(&tree::list_dir(dir.path(), &Options::default()).expect("list"));

    let previous = std::env::current_dir().expect("cwd");
    std::env::set_current_dir(dir.path()).expect("chdir");
    let relative = tree::list_dir(Path::new("."), &Options::default()).map(|e| names(&e));
    std::env::set_current_dir(previous).expect("restore cwd");

    assert_eq!(relative.expect("list"), absolute);
}

#[test]
fn dotfiles_and_git_internals_are_skipped_by_default() {
    let _serial = measuring();
    let dir = fixture();
    let entries = tree::list_dir(
        dir.path(),
        &Options {
            max_depth: 64,
            ..Options::default()
        },
    )
    .expect("list");

    assert!(!entries.iter().any(|e| e.name == ".hidden.md"));
    assert!(!entries.iter().any(|e| e.name == ".git"));
    assert!(!entries.iter().any(|e| e.name == ".gitignore"));
}

#[test]
fn hidden_files_appear_when_asked_for() {
    let _serial = measuring();
    let dir = fixture();
    let entries = tree::list_dir(
        dir.path(),
        &Options {
            hidden: true,
            ..Options::default()
        },
    )
    .expect("list");

    assert!(entries.iter().any(|e| e.name == ".hidden.md"));
    // `.git` stays out regardless: it is never a document.
    assert!(!entries.iter().any(|e| e.name == ".git"));
}

#[test]
fn non_markdown_files_are_filtered_unless_requested() {
    let _serial = measuring();
    let dir = fixture();

    let entries = tree::list_dir(dir.path(), &Options::default()).expect("list");
    assert!(!entries.iter().any(|e| e.name == "notes.txt"));

    let entries = tree::list_dir(
        dir.path(),
        &Options {
            markdown_only: false,
            ..Options::default()
        },
    )
    .expect("list");
    assert!(entries.iter().any(|e| e.name == "notes.txt"));
}

#[test]
fn a_single_file_is_its_own_target_list() {
    let _serial = measuring();
    let dir = fixture();
    let path = dir.path().join("README.md");
    let files = tree::markdown_files(&path, &Options::default()).expect("single file");
    assert_eq!(files, vec![path]);
}

#[test]
fn an_unreadable_subdirectory_does_not_fail_the_listing() {
    let _serial = measuring();
    let dir = fixture();
    let blocked = dir.path().join("docs/blocked");
    fs::create_dir_all(&blocked).expect("create");
    fs::write(blocked.join("x.md"), "# x\n").expect("write");

    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(&blocked, fs::Permissions::from_mode(0o000)).expect("chmod");
    }

    let entries = tree::list_dir(
        dir.path(),
        &Options {
            max_depth: 64,
            ..Options::default()
        },
    );

    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        // Restore before the assertion so a failure still cleans up.
        let restored = fs::set_permissions(&blocked, fs::Permissions::from_mode(0o755));
        assert!(restored.is_ok());
    }

    let entries = entries.expect("root is still listable");
    assert!(entries.iter().any(|e| e.name == "guide.md"));
}

#[test]
fn a_symlinked_directory_is_a_directory_and_is_descended_into() {
    let _serial = measuring();
    let dir = fixture();
    // `~/notes/projects -> ~/vault/projects` is the ordinary shape of a
    // notes tree kept in a dotfiles repository; the sidebar and `mark tasks`
    // both used to drop it, because `DirEntry::file_type` describes the link.
    std::os::unix::fs::symlink(dir.path().join("docs"), dir.path().join("linked"))
        .expect("symlink");

    let entries = tree::list_dir(
        dir.path(),
        &Options {
            max_depth: 64,
            ..Options::default()
        },
    )
    .expect("listing");

    let linked = entries
        .iter()
        .find(|e| e.name == "linked")
        .expect("the symlinked directory is listed");
    assert!(linked.is_dir, "a symlink to a directory is a directory");
    assert!(
        entries
            .iter()
            .any(|e| e.path == dir.path().join("linked/guide.md")),
        "its contents are listed under the link's own name: {:?}",
        names(&entries)
    );

    let files = tree::markdown_files(
        dir.path(),
        &Options {
            max_depth: 64,
            ..Options::default()
        },
    )
    .expect("files");
    assert!(files.contains(&dir.path().join("linked/guide.md")));
}

#[test]
fn a_symlink_cycle_is_listed_once_and_never_descended_into_again() {
    let _serial = measuring();
    let dir = fixture();
    // Three shapes of cycle: a link to the directory holding it, a link to
    // an ancestor, and two links pointing at each other's parents.
    std::os::unix::fs::symlink(".", dir.path().join("docs/self")).expect("symlink");
    std::os::unix::fs::symlink("..", dir.path().join("docs/nested/up")).expect("symlink");
    fs::create_dir_all(dir.path().join("x")).expect("mkdir");
    fs::create_dir_all(dir.path().join("y")).expect("mkdir");
    std::os::unix::fs::symlink("../y", dir.path().join("x/to-y")).expect("symlink");
    std::os::unix::fs::symlink("../x", dir.path().join("y/to-x")).expect("symlink");

    let before = tree::dir_reads();
    let entries = tree::list_dir(
        dir.path(),
        &Options {
            max_depth: 64,
            ..Options::default()
        },
    )
    .expect("a cyclic tree still lists");
    let reads = tree::dir_reads() - before;

    // Every real directory read once, every link listed as a directory row,
    // and `guide.md` appears exactly once rather than at sixty-four depths.
    let guides = entries.iter().filter(|e| e.name == "guide.md").count();
    assert_eq!(guides, 1, "{:?}", names(&entries));
    assert!(entries.iter().any(|e| e.name == "self" && e.is_dir));
    assert!(entries.iter().any(|e| e.name == "up" && e.is_dir));
    // root, docs, docs/nested, docs/nested/deeper, x, y — plus at most one
    // read *through* each of the two mutual links before the guard catches
    // the return trip.
    assert!(
        reads <= 8,
        "read {reads} directories for a six-directory tree"
    );
}

#[test]
fn a_dangling_symlink_is_neither_a_directory_nor_a_crash() {
    let _serial = measuring();
    let dir = fixture();
    std::os::unix::fs::symlink("nowhere", dir.path().join("gone.md")).expect("symlink");
    std::os::unix::fs::symlink("nowhere-dir", dir.path().join("gone")).expect("symlink");

    let entries = tree::list_dir(
        dir.path(),
        &Options {
            max_depth: 64,
            markdown_only: false,
            ..Options::default()
        },
    )
    .expect("listing");
    assert!(!entries.iter().any(|e| e.name == "gone" && e.is_dir));
    // A dangling `.md` link is still a name in the directory; `stats` on it
    // yields nothing rather than failing the listing.
    assert!(entries.iter().any(|e| e.name == "gone.md" && !e.is_dir));
}
