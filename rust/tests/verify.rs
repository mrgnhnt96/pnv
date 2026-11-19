use std::fs;
use std::path::Path;

use pnv::{Key, Pnvrc, create_key, encrypt};

struct Project {
    dir: tempfile::TempDir,
    pnvrc: Pnvrc,
    prod: Key,
    local: Key,
}

fn project() -> Project {
    let dir = tempfile::tempdir().unwrap();
    let prod = Key::decode(&create_key().unwrap()).unwrap();
    let local = Key::decode(&create_key().unwrap()).unwrap();
    let mut pnvrc = Pnvrc::new("~/outside-the-project-for-sure");
    pnvrc.add_flavor("production").unwrap();
    pnvrc.add_flavor("local").unwrap();
    Project {
        dir,
        pnvrc,
        prod,
        local,
    }
}

fn write(root: &Path, name: &str, text: &str) {
    let path = root.join(name);
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    fs::write(path, text).unwrap();
}

/// Runs `verify` with both flavors' keys in the process environment. Every
/// test holds `LOCK`, so none sees another's variables.
fn run(p: &Project) -> pnv::VerifyReport {
    // SAFETY: the tests that touch the environment are serialized by LOCK.
    unsafe {
        std::env::set_var("PNV_KEY_PRODUCTION", p.prod.encode());
        std::env::set_var("PNV_KEY_LOCAL", p.local.encode());
    }
    pnv::verify(p.dir.path(), p.dir.path(), &p.pnvrc).unwrap()
}

static LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());

#[test]
fn a_clean_project_passes() {
    let _guard = LOCK.lock().unwrap();
    let p = project();
    let token = encrypt("hunter2hunter2", &p.prod).unwrap();
    write(
        p.dir.path(),
        "envs/app.production.yaml",
        &format!("db:\n  password: {token}\n  host: localhost\n"),
    );
    write(p.dir.path(), "envs/app.local.yaml", "name: demo\n");

    let report = run(&p);
    assert!(report.is_clean(), "{:?}", report.problems);
    assert_eq!((report.files, report.secrets), (2, 1));
}

#[test]
fn problems_are_found() {
    let _guard = LOCK.lock().unwrap();
    let p = project();
    let from_prod = encrypt("x", &p.prod).unwrap();
    let corrupt = format!("SECRET;v1:{}", "!!!");
    write(
        p.dir.path(),
        "app.local.yaml",
        &format!("crossed: {from_prod}\nbroken: {corrupt}\nplain-password: hunter2hunter2\n"),
    );
    write(
        p.dir.path(),
        "node_modules/x/leak.yaml",
        "password: hunter2hunter2\n",
    );
    write(
        p.dir.path(),
        "target/leak.yaml",
        "password: hunter2hunter2\n",
    );

    let report = run(&p);
    assert_eq!(report.files, 1, "skipped directories are not walked");
    assert_eq!(report.problems.len(), 3, "{:#?}", report.problems);
    assert!(
        report.problems[0].contains("different key")
            && report.problems[0].contains("\"production\"")
    );
    assert!(
        report.problems[1].contains("corrupt value"),
        "{}",
        report.problems[1]
    );
    assert!(report.problems[2].contains("plain-password"));
}

#[test]
fn storage_inside_the_project_is_flagged() {
    let _guard = LOCK.lock().unwrap();
    let mut p = project();
    p.pnvrc = Pnvrc::new(p.dir.path().join(".keys").to_string_lossy().into_owned());

    let report = run(&p);
    assert!(
        report
            .problems
            .iter()
            .any(|m| m.contains("inside the project")),
        "{:?}",
        report.problems
    );
}

#[test]
fn every_document_of_a_multi_document_file_is_checked() {
    let _guard = LOCK.lock().unwrap();
    let p = project();
    let token = encrypt("hunter2hunter2", &p.local).unwrap();
    write(
        p.dir.path(),
        "profiles.local.yaml",
        &format!("name: first\nkey: {token}\n---\nname: second\ndb:\n  password: hunter2hunter2\n"),
    );

    let report = run(&p);
    assert_eq!(report.secrets, 1);
    assert_eq!(report.problems.len(), 1, "{:#?}", report.problems);
    assert!(report.problems[0].contains("db.password"));
}

#[test]
fn a_clean_multi_document_file_passes() {
    let _guard = LOCK.lock().unwrap();
    let p = project();
    write(
        p.dir.path(),
        "profiles.yaml",
        "name: captcha\ndecisions:\n  - type: captcha\n---\nname: default\non_success: break\n",
    );

    let report = run(&p);
    assert!(report.is_clean(), "{:?}", report.problems);
}

fn git(dir: &Path, args: &[&str]) {
    let status = std::process::Command::new("git")
        .args(args)
        .current_dir(dir)
        .status()
        .unwrap();
    assert!(status.success(), "git {args:?}");
}

#[test]
fn in_a_git_repo_only_files_git_would_publish_are_checked() {
    let _guard = LOCK.lock().unwrap();
    let p = project();
    let root = p.dir.path();
    git(root, &["init", "--quiet"]);
    write(root, ".gitignore", "ignored/\n");
    write(root, "envs/app.yaml", "name: demo\n");
    write(
        root,
        "ignored/copy/envs/app.yaml",
        "password: hunter2hunter2\n",
    );

    let report = run(&p);
    assert!(report.is_clean(), "{:?}", report.problems);
    assert_eq!(report.files, 1, "the gitignored copy is skipped");

    // Untracked but not ignored: git would track it, so it is checked.
    write(root, "envs/new.yaml", "password: hunter2hunter2\n");
    let report = run(&p);
    assert_eq!(report.files, 2);
    assert_eq!(report.problems.len(), 1, "{:?}", report.problems);
    assert!(report.problems[0].contains("new.yaml"));
}
