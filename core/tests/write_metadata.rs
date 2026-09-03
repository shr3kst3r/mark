//! `write_atomically` replaces the inode, and everything that lived on the old
//! one — Finder tags, every other extended attribute, the ACL — has to be moved
//! onto the new one or it is silently gone after the first checkbox tick. The
//! bytes are property-tested elsewhere; this file is about what is *around*
//! the bytes.

#![cfg(target_os = "macos")]

use std::ffi::CString;
use std::fs;
use std::os::unix::ffi::OsStrExt;
use std::path::Path;

use mark_core::tasks::{self, Action};

const TAGS: &str = "com.apple.metadata:_kMDItemUserTags";

fn set_xattr(path: &Path, name: &str, value: &[u8]) {
    let path = CString::new(path.as_os_str().as_bytes()).unwrap();
    let name = CString::new(name).unwrap();
    let result = unsafe {
        libc::setxattr(
            path.as_ptr(),
            name.as_ptr(),
            value.as_ptr().cast(),
            value.len(),
            0,
            0,
        )
    };
    assert_eq!(result, 0, "setxattr: {}", std::io::Error::last_os_error());
}

fn get_xattr(path: &Path, name: &str) -> Option<Vec<u8>> {
    let cpath = CString::new(path.as_os_str().as_bytes()).unwrap();
    let cname = CString::new(name).unwrap();
    let size = unsafe {
        libc::getxattr(
            cpath.as_ptr(),
            cname.as_ptr(),
            std::ptr::null_mut(),
            0,
            0,
            0,
        )
    };
    if size < 0 {
        return None;
    }
    let mut buffer = vec![0u8; size as usize];
    let read = unsafe {
        libc::getxattr(
            cpath.as_ptr(),
            cname.as_ptr(),
            buffer.as_mut_ptr().cast(),
            buffer.len(),
            0,
            0,
        )
    };
    assert!(read >= 0);
    buffer.truncate(read as usize);
    Some(buffer)
}

#[test]
fn extended_attributes_survive_a_write() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("tagged.md");
    fs::write(&path, "# Tagged\n\n- [ ] one\n").unwrap();
    // A Finder tag is a binary plist in this xattr; the bytes are opaque to
    // us and only have to come back identical.
    set_xattr(&path, TAGS, b"bplist00\x00fake-tag-payload");
    set_xattr(&path, "dev.mark.test", b"kept");

    tasks::write_atomically(&path, "# Tagged\n\n- [x] one\n").unwrap();

    assert_eq!(
        fs::read_to_string(&path).unwrap(),
        "# Tagged\n\n- [x] one\n"
    );
    assert_eq!(
        get_xattr(&path, TAGS).as_deref(),
        Some(&b"bplist00\x00fake-tag-payload"[..]),
        "the Finder tag was lost with the old inode"
    );
    assert_eq!(
        get_xattr(&path, "dev.mark.test").as_deref(),
        Some(&b"kept"[..])
    );
}

#[test]
fn a_checkbox_tick_keeps_the_tag_too() {
    // The path every click and every `mark check` takes.
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("t.md");
    fs::write(&path, "- [ ] a\n").unwrap();
    set_xattr(&path, "dev.mark.test", b"still here");

    tasks::toggle_file(&path, 0, Action::On).unwrap();

    assert_eq!(fs::read_to_string(&path).unwrap(), "- [x] a\n");
    assert_eq!(
        get_xattr(&path, "dev.mark.test").as_deref(),
        Some(&b"still here"[..])
    );
}

#[test]
fn a_new_file_with_nothing_to_inherit_is_still_written() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("fresh.md");
    tasks::write_atomically(&path, "# Fresh\n").unwrap();
    assert_eq!(fs::read_to_string(&path).unwrap(), "# Fresh\n");
    assert!(get_xattr(&path, "dev.mark.test").is_none());
}
