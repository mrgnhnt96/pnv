#![cfg(feature = "cli")]

use std::fs;
use std::path::{Path, PathBuf};

use assert_cmd::Command;
use predicates::prelude::*;
use predicates::str::contains;

/// A project directory and a home directory, both temporary, so `~` in a
/// storage path never reaches the real home.
struct Sandbox {
    _root: tempfile::TempDir,
    home: PathBuf,
    project: PathBuf,
}

impl Sandbox {
    fn new() -> Self {
        let root = tempfile::tempdir().unwrap();
        let home = root.path().join("home");
        let project = root.path().join("app");
        fs::create_dir_all(&home).unwrap();
        fs::create_dir_all(&project).unwrap();
        Self {
            _root: root,
            home,
            project,
        }
    }

    /// A project already set up with `local` and `production` keys.
    fn initialized() -> Self {
        let sandbox = Self::new();
        sandbox
            .pnv(&[
                "init",
                "--storage",
                "~/.app",
                "--flavor",
                "local,production",
            ])
            .assert()
            .success();
        sandbox
    }

    fn pnv(&self, args: &[&str]) -> Command {
        let mut cmd = Command::cargo_bin("pnv").unwrap();
        cmd.current_dir(&self.project)
            .env("HOME", &self.home)
            .env("USERPROFILE", &self.home)
            .env_remove("PNV_KEY_LOCAL")
            .env_remove("PNV_KEY_PRODUCTION")
            .env_remove("PNV_KEY_CI")
            .args(args);
        cmd
    }

    fn storage(&self) -> PathBuf {
        self.home.join(".app")
    }

    fn key(&self, flavor: &str) -> String {
        fs::read_to_string(self.storage().join(format!("{flavor}.key"))).unwrap()
    }

    fn pnvrc(&self) -> serde_json::Value {
        serde_json::from_str(&self.read(".pnvrc")).unwrap()
    }

    fn read(&self, path: &str) -> String {
        fs::read_to_string(self.project.join(path)).unwrap()
    }

    fn write(&self, path: &str, text: &str) {
        let path = self.project.join(path);
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(path, text).unwrap();
    }

    fn exists(&self, path: &str) -> bool {
        self.project.join(path).exists()
    }

    fn encrypt(&self, flavor: &str, value: &str) -> String {
        let out = self
            .pnv(&["encrypt", "--flavor", flavor, value])
            .assert()
            .success()
            .get_output()
            .stdout
            .clone();
        String::from_utf8(out).unwrap().trim().to_owned()
    }
}

fn flavors(pnvrc: &serde_json::Value) -> Vec<String> {
    pnvrc["flavors"]
        .as_object()
        .unwrap()
        .keys()
        .cloned()
        .collect()
}

#[cfg(unix)]
fn mode(path: &Path) -> u32 {
    use std::os::unix::fs::PermissionsExt;
    fs::metadata(path).unwrap().permissions().mode() & 0o777
}

mod usage {
    use super::*;

    #[test]
    fn no_arguments_prints_help_and_succeeds() {
        Sandbox::new()
            .pnv(&[])
            .assert()
            .success()
            .stdout(contains("Usage: pnv"));
    }

    #[test]
    fn an_unknown_flag_exits_1_not_2() {
        Sandbox::new()
            .pnv(&["--bogus"])
            .assert()
            .code(1)
            .stderr(contains("--bogus"));
    }

    #[test]
    fn a_group_with_no_subcommand_prints_its_help() {
        Sandbox::new()
            .pnv(&["create"])
            .assert()
            .success()
            .stdout(contains("flavor"));
    }

    #[test]
    fn generate_dart_is_left_out() {
        Sandbox::new().pnv(&["generate", "dart"]).assert().code(1);
    }
}

mod create_key {
    use super::*;

    #[test]
    fn prints_a_new_key() {
        let out = Sandbox::new()
            .pnv(&["create", "key"])
            .assert()
            .success()
            .get_output()
            .stdout
            .clone();
        let key = String::from_utf8(out).unwrap();
        assert_eq!(key.trim().len(), 44);
        pnv::Key::decode(key.trim()).unwrap();
    }

    #[test]
    fn prints_the_key_even_when_quiet() {
        Sandbox::new()
            .pnv(&["--quiet", "create", "key"])
            .assert()
            .success()
            .stdout(predicate::str::is_empty().not());
    }
}

mod init {
    use super::*;

    #[test]
    fn writes_the_pnvrc_and_a_key_per_flavor() {
        let s = Sandbox::new();
        s.pnv(&[
            "init",
            "--storage",
            "~/.app",
            "--flavor",
            "local",
            "-f",
            "production,ci",
        ])
        .assert()
        .success()
        .stdout(contains("Created flavor production"));

        let pnvrc = s.pnvrc();
        assert_eq!(pnvrc["storage"], "~/.app");
        assert_eq!(flavors(&pnvrc), ["local", "production", "ci"]);
        for flavor in ["local", "production", "ci"] {
            pnv::Key::from_key_file(&s.key(flavor)).unwrap();
        }
        assert!(!s.read(".pnvrc").ends_with('\n'));
    }

    #[cfg(unix)]
    #[test]
    fn key_files_are_readable_by_their_owner_only() {
        let s = Sandbox::initialized();
        assert_eq!(mode(&s.storage().join("local.key")), 0o600);
    }

    #[test]
    fn defaults_the_storage_to_the_project_name_under_home() {
        let s = Sandbox::new();
        s.pnv(&["init"]).assert().success();
        assert_eq!(s.pnvrc()["storage"], "~/.app");
        assert!(s.storage().is_dir());
    }

    #[test]
    fn running_again_keeps_every_key() {
        let s = Sandbox::initialized();
        let local = s.key("local");

        s.pnv(&["init", "--flavor", "local,staging"])
            .assert()
            .success()
            .stdout(contains("Found flavors"));

        assert_eq!(s.key("local"), local);
        assert_eq!(flavors(&s.pnvrc()), ["local", "production", "staging"]);
    }

    #[test]
    fn keeps_an_existing_storage_and_says_so() {
        let s = Sandbox::initialized();
        s.pnv(&["init", "--storage", "~/.elsewhere"])
            .assert()
            .success()
            .stderr(contains("ignoring --storage"));
        assert_eq!(s.pnvrc()["storage"], "~/.app");
    }

    #[test]
    fn adopts_key_files_already_in_storage() {
        let s = Sandbox::new();
        fs::create_dir_all(s.storage()).unwrap();
        let key = pnv::create_key().unwrap();
        fs::write(s.storage().join("qa.key"), &key).unwrap();
        fs::write(s.storage().join("qa.key.previous"), &key).unwrap();

        s.pnv(&["init", "--storage", "~/.app"])
            .assert()
            .success()
            .stdout(contains("qa"));

        assert_eq!(flavors(&s.pnvrc()), ["qa"]);
        assert_eq!(s.key("qa"), key);
    }

    #[test]
    fn creates_the_key_a_listed_flavor_is_missing() {
        let s = Sandbox::initialized();
        fs::remove_file(s.storage().join("production.key")).unwrap();

        s.pnv(&["init"]).assert().success();

        pnv::Key::from_key_file(&s.key("production")).unwrap();
    }

    #[test]
    fn warns_when_the_storage_is_inside_the_project() {
        let s = Sandbox::new();
        s.pnv(&["init", "--storage", "keys"])
            .assert()
            .success()
            .stderr(contains("inside the project"));
    }

    #[test]
    fn refuses_an_invalid_flavor_name_and_writes_nothing() {
        let s = Sandbox::new();
        s.pnv(&["init", "--storage", "~/.app", "--flavor", "local,bad name"])
            .assert()
            .code(1)
            .stderr(contains("Invalid flavor name"));
        assert!(!s.exists(".pnvrc"));
        assert!(!s.storage().join("local.key").exists());
    }

    #[test]
    fn adds_key_patterns_to_gitignore_once() {
        let s = Sandbox::new();
        s.write(".gitignore", "target/");

        s.pnv(&["init", "--gitignore"]).assert().success();
        s.pnv(&["init", "--gitignore"]).assert().success();

        let gitignore = s.read(".gitignore");
        assert!(gitignore.starts_with("target/\n"));
        assert_eq!(gitignore.matches("*.key #").count(), 1);
        assert_eq!(gitignore.matches("*.key.previous #").count(), 1);
    }

    #[test]
    fn accepts_the_dart_tools_yes_flag() {
        Sandbox::new().pnv(&["init", "--yes"]).assert().success();
    }
}

mod create_flavor {
    use super::*;

    #[test]
    fn needs_a_pnvrc() {
        Sandbox::new()
            .pnv(&["create", "flavor", "--name", "local"])
            .assert()
            .code(1)
            .stderr(contains("pnv init"));
    }

    #[test]
    fn needs_a_name() {
        Sandbox::initialized()
            .pnv(&["create", "flavor"])
            .assert()
            .code(1)
            .stderr(contains("--name"));
    }

    #[test]
    fn adds_the_flavor_and_its_key() {
        let s = Sandbox::initialized();
        s.pnv(&["create", "flavor", "-n", "staging"])
            .assert()
            .success()
            .stdout(contains("Created flavor staging"));
        assert_eq!(flavors(&s.pnvrc()), ["local", "production", "staging"]);
        pnv::Key::from_key_file(&s.key("staging")).unwrap();
    }

    #[test]
    fn will_not_replace_a_key_without_force() {
        let s = Sandbox::initialized();
        let before = s.key("local");

        s.pnv(&["create", "flavor", "--name", "local"])
            .assert()
            .code(1)
            .stderr(contains("--force"));
        assert_eq!(s.key("local"), before);

        s.pnv(&["create", "flavor", "--name", "local", "--force"])
            .assert()
            .success();
        assert_ne!(s.key("local"), before);
        assert_eq!(flavors(&s.pnvrc()), ["local", "production"]);
    }

    #[test]
    fn will_not_replace_an_unlisted_key_file_without_force() {
        let s = Sandbox::initialized();
        fs::write(s.storage().join("old.key"), pnv::create_key().unwrap()).unwrap();
        s.pnv(&["create", "flavor", "--name", "old"])
            .assert()
            .code(1);
    }

    #[test]
    fn refuses_an_invalid_name() {
        Sandbox::initialized()
            .pnv(&["create", "flavor", "--name", "no/slashes"])
            .assert()
            .code(1)
            .stderr(contains("Invalid flavor name"));
    }
}

mod delete_flavor {
    use super::*;

    #[test]
    fn refuses_without_force_and_keeps_the_key() {
        let s = Sandbox::initialized();
        s.pnv(&["delete", "flavor", "--name", "local"])
            .assert()
            .code(1)
            .stderr(contains("--force"));
        assert!(s.storage().join("local.key").exists());
        assert_eq!(flavors(&s.pnvrc()), ["local", "production"]);
    }

    #[test]
    fn deletes_every_named_flavor_and_its_key() {
        let s = Sandbox::initialized();
        s.pnv(&["create", "flavor", "--name", "qa"])
            .assert()
            .success();

        s.pnv(&["delete", "flavor", "-n", "local,qa", "--force"])
            .assert()
            .success()
            .stdout(contains("Deleted flavor qa"));

        assert_eq!(flavors(&s.pnvrc()), ["production"]);
        assert!(!s.storage().join("local.key").exists());
        assert!(!s.storage().join("qa.key").exists());
        assert!(s.storage().join("production.key").exists());
    }

    #[test]
    fn deletes_nothing_when_one_name_is_unknown() {
        let s = Sandbox::initialized();
        s.pnv(&["delete", "flavor", "-n", "local", "-n", "nope", "-f"])
            .assert()
            .code(1)
            .stderr(contains("No such flavor: nope"));
        assert!(s.storage().join("local.key").exists());
    }

    #[test]
    fn needs_a_name() {
        Sandbox::initialized()
            .pnv(&["delete", "flavor", "--force"])
            .assert()
            .code(1)
            .stderr(contains("--name"));
    }
}

mod crypt {
    use super::*;

    #[test]
    fn round_trips_with_a_flavor_and_the_short_aliases() {
        let s = Sandbox::initialized();
        let token = s.encrypt("local", "hunter2");
        assert!(token.starts_with("SECRET;v1:"));

        s.pnv(&["d", "--flavor", "local", &token])
            .assert()
            .success()
            .stdout("hunter2\n");
    }

    #[test]
    fn works_on_every_value_given() {
        let key = pnv::create_key().unwrap();
        let s = Sandbox::new();
        let out = s
            .pnv(&["enc", "-k", &key, "one", "two"])
            .assert()
            .success()
            .get_output()
            .stdout
            .clone();
        let tokens: Vec<String> = String::from_utf8(out)
            .unwrap()
            .lines()
            .map(str::to_owned)
            .collect();
        assert_eq!(tokens.len(), 2);

        let mut args = vec!["decode", "--key", &key];
        args.extend(tokens.iter().map(String::as_str));
        s.pnv(&args).assert().success().stdout("one\ntwo\n");
    }

    #[test]
    fn reads_a_key_file() {
        let s = Sandbox::new();
        let key = pnv::create_key().unwrap();
        s.write("my.key", &format!("{key}\n"));
        let token = pnv::encrypt("x", &pnv::Key::decode(&key).unwrap()).unwrap();

        s.pnv(&["decrypt", "--key-file", "my.key", &token])
            .assert()
            .success()
            .stdout("x\n");
    }

    #[test]
    fn reads_the_key_from_the_environment_with_no_pnvrc() {
        let s = Sandbox::new();
        let key = pnv::create_key().unwrap();
        let token = pnv::encrypt("from env", &pnv::Key::decode(&key).unwrap()).unwrap();

        s.pnv(&["decrypt", "--flavor", "ci", &token])
            .env("PNV_KEY_CI", &key)
            .assert()
            .success()
            .stdout("from env\n");
    }

    #[test]
    fn resolves_an_alias_to_its_flavors_key() {
        let s = Sandbox::initialized();
        let mut pnvrc = s.pnvrc();
        pnvrc["flavors"]["production"] = serde_json::json!(["prod"]);
        s.write(".pnvrc", &pnvrc.to_string());

        let token = s.encrypt("prod", "aliased");
        s.pnv(&["decrypt", "--flavor", "production", &token])
            .assert()
            .success()
            .stdout("aliased\n");
    }

    #[test]
    fn says_when_the_key_is_wrong() {
        let s = Sandbox::initialized();
        let token = s.encrypt("local", "hunter2");
        s.pnv(&["decrypt", "--flavor", "production", &token])
            .assert()
            .code(1)
            .stderr(contains("Wrong key"));
    }

    #[test]
    fn needs_values() {
        Sandbox::initialized()
            .pnv(&["encrypt", "--flavor", "local"])
            .assert()
            .code(1)
            .stderr(contains("No values to encrypt provided."));
    }

    #[test]
    fn needs_a_key() {
        Sandbox::new()
            .pnv(&["encrypt", "x"])
            .assert()
            .code(1)
            .stderr(contains("Missing key, key file, or flavor."));
    }

    #[test]
    fn names_a_flavor_with_no_key() {
        Sandbox::initialized()
            .pnv(&["encrypt", "--flavor", "staging", "x"])
            .assert()
            .code(1)
            .stderr(contains("PNV_KEY_STAGING"));
    }
}

mod generate_env {
    use super::*;

    /// A project with one file per flavor, each holding a secret.
    fn project() -> Sandbox {
        let s = Sandbox::initialized();
        for flavor in ["local", "production"] {
            let secret = s.encrypt(flavor, &format!("{flavor}-pw"));
            s.write(
                &format!("envs/app.{flavor}.yaml"),
                &format!("db:\n  host: {flavor}.db\n  port: 5432 # int\npassword: {secret}\n"),
            );
        }
        s
    }

    #[test]
    fn writes_a_file_with_the_key_its_name_implies() {
        let s = project();
        s.pnv(&["generate", "env", "--file", "envs/app.local.yaml"])
            .assert()
            .success()
            .stdout(contains("Generated .env file at outputs/app.local.env"));

        assert_eq!(
            s.read("outputs/app.local.env"),
            "DB_HOST=\"local.db\"\nDB_PORT=5432 # int\nPASSWORD=\"local-pw\"\n"
        );
    }

    #[test]
    fn writes_every_file_in_a_directory() {
        let s = project();
        s.write("envs/README.md", "not yaml");
        s.pnv(&["generate", "env", "--dir", "envs", "-o", "out"])
            .assert()
            .success();

        assert!(s.read("out/app.local.env").contains("local-pw"));
        assert!(s.read("out/app.production.env").contains("production-pw"));
        assert!(!s.exists("out/README.env"));
    }

    #[test]
    fn a_flavor_keeps_only_its_groups_files() {
        let s = project();
        let mut pnvrc = s.pnvrc();
        pnvrc["flavors"]["production"] = serde_json::json!(["prod"]);
        s.write(".pnvrc", &pnvrc.to_string());
        let secret = s.encrypt("production", "prod-pw");
        s.write("envs/api.prod.yaml", &format!("password: {secret}\n"));

        s.pnv(&["generate", "env", "-d", "envs", "--flavor", "production"])
            .assert()
            .success();

        assert!(s.exists("outputs/app.production.env"));
        assert!(s.read("outputs/api.prod.env").contains("prod-pw"));
        assert!(!s.exists("outputs/app.local.env"));
    }

    #[test]
    fn an_unknown_flavor_is_an_error_not_every_file() {
        let s = project();
        s.pnv(&["generate", "env", "-d", "envs", "--flavor", "prodution"])
            .assert()
            .code(1)
            .stderr(contains("Known flavors: local, production"));
        assert!(!s.exists("outputs"));
    }

    #[test]
    fn writes_nothing_when_one_file_fails() {
        let s = project();
        let wrong = s.encrypt("production", "misplaced");
        s.write("envs/app.local.yaml", &format!("password: {wrong}\n"));

        s.pnv(&["generate", "env", "-d", "envs"])
            .assert()
            .code(1)
            .stderr(contains("Wrong key"));
        assert!(!s.exists("outputs"));
    }

    #[test]
    fn a_named_key_decrypts_every_file() {
        let s = project();
        let key = s.key("production");
        s.write("envs/odd-name.yaml", "plain: value\n");

        s.pnv(&[
            "generate",
            "env",
            "-i",
            "envs/app.production.yaml",
            "--key",
            key.trim(),
        ])
        .assert()
        .success();
        assert!(
            s.read("outputs/app.production.env")
                .contains("production-pw")
        );
    }

    #[test]
    fn needs_a_file_or_directory() {
        project()
            .pnv(&["generate", "env"])
            .assert()
            .code(1)
            .stderr(contains("Either --file or --directory must be provided."));
    }

    #[test]
    fn refuses_a_missing_or_non_yaml_file() {
        let s = project();
        s.pnv(&["generate", "env", "-i", "envs/nope.yaml"])
            .assert()
            .code(1)
            .stderr(contains("does not exist"));
        s.write("envs/app.local.json", "{}");
        s.pnv(&["generate", "env", "-i", "envs/app.local.json"])
            .assert()
            .code(1)
            .stderr(contains("must be a .yaml file"));
    }

    #[test]
    fn quiet_hides_progress_and_loud_shows_skips() {
        let s = project();
        s.pnv(&["generate", "env", "-d", "envs", "--quiet"])
            .assert()
            .success()
            .stdout(predicate::str::is_empty());
        s.pnv(&[
            "generate", "env", "-d", "envs", "--flavor", "local", "--loud",
        ])
        .assert()
        .success()
        .stdout(contains("Skipping file"));
    }
}

mod verify {
    use super::*;

    #[test]
    fn needs_a_pnvrc() {
        Sandbox::new()
            .pnv(&["verify"])
            .assert()
            .code(1)
            .stderr(contains("pnv init"));
    }

    #[test]
    fn passes_a_project_of_encrypted_files() {
        let s = Sandbox::initialized();
        let secret = s.encrypt("local", "pw");
        s.write("app.local.yaml", &format!("password: {secret}\n"));
        s.pnv(&["verify"])
            .assert()
            .success()
            .stdout(contains("1 file(s), 1 secret(s)"));
    }
}

/// Ported from the Dart tool's `test/e2e/set_get_command_test.dart`.
mod set {
    use super::*;

    const FILE: &str = "envs/app.local.yaml";

    fn with(text: &str) -> Sandbox {
        let s = Sandbox::initialized();
        s.write(FILE, text);
        s
    }

    #[test]
    fn encrypts_in_place_and_leaves_everything_else_byte_for_byte() {
        let s = with(
            "# a leading comment\nbase-url: http://localhost:3000   # trailing comment\napp:\n  name: demo\n  api-key: replace-me # the key\n",
        );
        s.pnv(&["set", "app.api-key", "sk-live-abc", "--file", FILE])
            .assert()
            .success()
            .stdout(contains(
                "Encrypted envs/app.local.yaml \u{2192} app.api-key",
            ));

        let result = s.read(FILE);
        let (before, token) = result.split_once("api-key: ").unwrap();
        assert_eq!(
            before,
            "# a leading comment\nbase-url: http://localhost:3000   # trailing comment\napp:\n  name: demo\n  "
        );
        assert!(token.starts_with("SECRET;v1:"));
        assert!(token.ends_with(" # the key\n"));
        assert!(!result.contains("replace-me"));
    }

    #[test]
    fn creates_missing_groups_in_block_style() {
        let s = with("app:\n  name: demo\n");
        s.pnv(&["set", "app.db.password", "hunter2", "--file", FILE])
            .assert()
            .success();
        assert!(s.read(FILE).contains("  db:\n    password: SECRET;v1:"));
    }

    #[test]
    fn seeds_an_empty_document() {
        let s = with("");
        s.pnv(&["set", "a.b.c", "v", "--file", FILE])
            .assert()
            .success();
        let result = s.read(FILE);
        assert!(result.starts_with("a:\n  b:\n    c: SECRET;v1:"));
        assert!(result.ends_with('\n'));
    }

    #[test]
    fn plain_writes_the_value_as_given() {
        let s = with("app:\n  name: demo\n");
        s.pnv(&["set", "app.region", "us-east-1", "-i", FILE, "--plain"])
            .assert()
            .success()
            .stdout(contains("Set envs/app.local.yaml"));
        assert_eq!(s.read(FILE), "app:\n  name: demo\n  region: us-east-1\n");
    }

    #[test]
    fn plain_needs_no_key() {
        let s = Sandbox::new();
        s.write("app.yaml", "a: 1\n");
        s.pnv(&["set", "b", "two", "--input", "app.yaml", "--plain"])
            .assert()
            .success();
        assert_eq!(s.read("app.yaml"), "a: 1\nb: two\n");
    }

    #[test]
    fn joins_the_words_of_the_value() {
        let s = with("a: b\n");
        s.pnv(&["set", "a", "two", "words", "--file", FILE, "--plain"])
            .assert()
            .success();
        assert_eq!(s.read(FILE), "a: two words\n");
    }

    #[test]
    fn reads_one_line_from_stdin() {
        let s = with("a: b\n");
        s.pnv(&["set", "a", "--file", FILE, "--stdin"])
            .write_stdin("from stdin\nignored\n")
            .assert()
            .success();
        s.pnv(&["get", "a", "--file", FILE])
            .assert()
            .success()
            .stdout("from stdin\n");
    }

    #[test]
    fn refuses_a_path_that_runs_through_a_scalar() {
        for text in ["app:\n  name: demo\n", "app:\n  name:\n"] {
            let s = with(text);
            s.pnv(&["set", "app.name.oops", "v", "--file", FILE])
                .assert()
                .code(1)
                .stderr(contains(
                    "\"app.name\" is a value, not a group, so \"app.name.oops\" cannot be set under it.",
                ));
            assert_eq!(s.read(FILE), text, "must not be touched");
        }
    }

    #[test]
    fn refuses_a_bad_path_before_looking_for_a_key() {
        let s = Sandbox::new();
        s.write("app.yaml", "a: b\n");
        s.pnv(&["set", "a.b", "v", "--file", "app.yaml"])
            .assert()
            .code(1)
            .stderr(contains("is a value, not a group"));
    }

    #[test]
    fn requires_a_value() {
        with("a: b\n")
            .pnv(&["set", "a", "--file", FILE])
            .assert()
            .code(1)
            .stderr(contains("Missing the value"));
    }

    #[test]
    fn requires_a_path_and_a_file() {
        let s = with("a: b\n");
        s.pnv(&["set", "--file", FILE])
            .assert()
            .code(1)
            .stderr(contains("Missing the key path"));
        s.pnv(&["set", "a", "v"])
            .assert()
            .code(1)
            .stderr(contains("--file is required."));
    }

    #[test]
    fn rejects_an_empty_path_segment() {
        with("a: b\n")
            .pnv(&["set", "app..key", "v", "--file", FILE])
            .assert()
            .code(1)
            .stderr(contains("Invalid key path"));
    }

    #[test]
    fn refuses_a_missing_or_non_yaml_file() {
        let s = Sandbox::initialized();
        s.pnv(&["set", "a", "v", "--file", "nope.yaml"])
            .assert()
            .code(1)
            .stderr(contains("Input file \"nope.yaml\" does not exist."));
        s.write("app.local.json", "{}");
        s.pnv(&["set", "a", "v", "--file", "app.local.json"])
            .assert()
            .code(1)
            .stderr(contains("must be a .yaml file"));
    }

    #[test]
    fn writes_nothing_when_the_file_has_no_key() {
        let s = Sandbox::initialized();
        s.write("app.staging.yaml", "a: b\n");
        s.pnv(&["set", "a", "v", "--file", "app.staging.yaml"])
            .assert()
            .code(1)
            .stderr(contains("implies flavor \"staging\""));
        assert_eq!(s.read("app.staging.yaml"), "a: b\n");
    }
}

/// Ported from the Dart tool's `test/e2e/set_get_command_test.dart`.
mod get {
    use super::*;

    const FILE: &str = "envs/app.local.yaml";

    fn with(text: &str) -> Sandbox {
        let s = Sandbox::initialized();
        s.write(FILE, text);
        s
    }

    #[test]
    fn round_trips_a_value_set_by_set() {
        let s = with("app:\n  name: demo\n");
        s.pnv(&["set", "app.api-key", "sk-live-abc", "--file", FILE])
            .assert()
            .success();
        s.pnv(&["get", "app.api-key", "--file", FILE])
            .assert()
            .success()
            .stdout("sk-live-abc\n");
    }

    #[test]
    fn reads_a_plain_value_back_unchanged() {
        let s = with("base-url: http://localhost:3000\nport: 0x1F\nnothing: ~\n");
        s.pnv(&["get", "base-url", "--file", FILE])
            .assert()
            .success()
            .stdout("http://localhost:3000\n");
        // Typed as the Dart tool types them.
        s.pnv(&["get", "port", "--file", FILE])
            .assert()
            .stdout("31\n");
        s.pnv(&["get", "nothing", "--file", FILE])
            .assert()
            .stdout("null\n");
    }

    #[test]
    fn plain_values_need_no_key() {
        let s = Sandbox::new();
        s.write("app.yaml", "a: 1\n");
        s.pnv(&["get", "a", "-i", "app.yaml"])
            .assert()
            .success()
            .stdout("1\n");
    }

    #[test]
    fn fails_on_a_key_that_is_not_there() {
        with("app:\n  name: demo\n")
            .pnv(&["get", "app.nope", "--file", FILE])
            .assert()
            .code(1)
            .stderr(contains(
                "No such key \"app.nope\" in \"envs/app.local.yaml\".",
            ));
    }

    #[test]
    fn fails_when_the_path_names_a_group() {
        with("app:\n  name: demo\n")
            .pnv(&["get", "app", "--file", FILE])
            .assert()
            .code(1)
            .stderr(contains("is a group, not a value"));
    }

    #[test]
    fn names_the_wrong_key_when_a_secret_came_from_another_flavor() {
        let s = with("app:\n  name: demo\n");
        s.pnv(&[
            "set",
            "app.api-key",
            "from-prod",
            "--file",
            FILE,
            "--flavor",
            "production",
        ])
        .assert()
        .success();

        s.pnv(&["get", "app.api-key", "--file", FILE])
            .assert()
            .code(1)
            .stderr(contains("encrypted with a different key"))
            .stderr(contains("envs/app.local.yaml \u{2192} app.api-key"));

        s.pnv(&[
            "get",
            "app.api-key",
            "--file",
            FILE,
            "--flavor",
            "production",
        ])
        .assert()
        .success()
        .stdout("from-prod\n");
    }
}

/// Ported from the show cases of the Dart tool's
/// `test/e2e/import_show_command_test.dart`.
mod show {
    use super::*;

    const FILE: &str = "envs/app.local.yaml";

    #[test]
    fn prints_the_file_with_secrets_decrypted() {
        let s = Sandbox::initialized();
        let secret = s.encrypt("local", "the-secret");
        s.write(FILE, &format!("app_key: {secret}\n"));

        s.pnv(&["show", FILE])
            .assert()
            .success()
            .stdout("app_key: the-secret\n");
        s.pnv(&["show", "--file", FILE])
            .assert()
            .success()
            .stdout("app_key: the-secret\n");
    }

    #[test]
    fn passes_through_a_file_with_no_secrets() {
        let s = Sandbox::new();
        for text in [
            "a: 1\nb: two\n",
            "a:   spaced   # c\n\n\n\nb: 2",
            "- a\n- b\n",
            "not: [valid\n",
            "",
        ] {
            s.write("plain.yaml", text);
            s.pnv(&["show", "plain.yaml"])
                .assert()
                .success()
                .stdout(text.to_owned());
        }
    }

    #[test]
    fn leaves_comments_and_structure_alone() {
        let s = Sandbox::initialized();
        s.write(
            FILE,
            "# a comment\napp:\n  key: replace # note\n\n  other: x\n",
        );
        s.pnv(&["set", "app.key", "v", "--file", FILE])
            .assert()
            .success();

        s.pnv(&["show", FILE])
            .assert()
            .success()
            .stdout("# a comment\napp:\n  key: v # note\n\n  other: x\n");
    }

    #[test]
    fn fails_on_a_missing_file() {
        let s = Sandbox::new();
        s.pnv(&["show", "nope.yaml"])
            .assert()
            .code(1)
            .stderr(contains("does not exist"));
        s.pnv(&["show"])
            .assert()
            .code(1)
            .stderr(contains("Name the .yaml file to show."));
    }

    #[test]
    fn works_as_a_git_textconv_driver() {
        // git runs `<driver> <file>` with nothing else to go on, so the key
        // comes from the flavor the file name implies, and nothing but the
        // file reaches stdout or stderr.
        let s = Sandbox::initialized();
        let secret = s.encrypt("local", "the-secret");
        s.write(FILE, &format!("db:\n  password: {secret} # rotated\n"));
        s.pnv(&["show", FILE])
            .assert()
            .success()
            .stdout("db:\n  password: the-secret # rotated\n")
            .stderr(predicate::str::is_empty());
    }
}
