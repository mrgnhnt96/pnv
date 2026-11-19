# pnv for Rust

Read encrypted secrets from YAML files that are safe to commit, in a build script or when your program runs. Secrets are stored as `SECRET;` tokens, keys live outside the project, and a `.pnvrc` maps flavors to keys, as described in the [format spec](../spec/format.md).

## Install

Add the crate to a project, or install the command:

```sh
cargo add pnv                          # the library, plus the `pnv` command's code
cargo add --build pnv --no-default-features   # for a build script: the library only
cargo install pnv                      # the `pnv` command
```

The `cli` feature builds the `pnv` command and is on by default. Turn it off with `default-features = false` when you only need the library. The minimum Rust version is 1.88.

## Keep secrets in YAML

A secret is a value that starts with `SECRET;v1:`, followed by the encrypted text. Everything else in the file is plain text. The file is committed; the key is not.

```yaml
# app.production.yaml
app-name: my-app
database:
  url: SECRET;v1:ikceywABAgMEBQYHCAkKCyLDfmHplmR3TDvBmf48BQQ9Ry9u/Zx9DFyk6Ao=
server:
  port: 8080
```

Nested keys flatten into one name each: `database.url` becomes `DATABASE_URL`. Lists are refused. See the [format spec](../spec/format.md) for the exact rules.

Make a key with the command, and keep it out of the repository. Then put secrets in the file with `pnv set`, which edits it in place and keeps its comments, order and layout:

```sh
pnv create key > ~/.my_project/production.key
pnv set database.url "postgres://..." --file app.production.yaml
pnv show app.production.yaml           # the whole file, decrypted
```

## Find the key

Both ways of reading a file find its key the same way. The first match wins:

1. The `PNV_KEY_<FLAVOR>` environment variable: the flavor in capitals, with `-` turned into `_` (`production` gives `PNV_KEY_PRODUCTION`). It is trimmed, and a blank one counts as unset. It needs no `.pnvrc`.
2. `<storage>/<flavor>.key`, from the nearest `.pnvrc` in the current directory or above it.
3. For a flavor that lists the name as an alias, steps 1 and 2 again for that flavor.

The flavor comes from the file name: `app.production.yaml` is `production`, and `local.yaml` is `local`. The `.pnvrc` is a small JSON file (`{"storage":"keys","flavors":{"production":["ci"]}}`) that `pnv init` writes, and is only read when a flavor needs it. On a build server, set `PNV_KEY_PRODUCTION` and ship no key file.

To choose the key yourself, use `pnv::KeyLookup` (`.key`, `.key_file`, `.flavor`, `.file`, then `.resolve()`).

## Read secrets in a build script

A build script decrypts the file and hands each value to the compiler, so the program carries its configuration and reads no file when it runs.

Add the crate as a build dependency:

```toml
# Cargo.toml
[build-dependencies]
pnv = { version = "0.1", default-features = false }
```

Call it from `build.rs`:

```rust
// build.rs
fn main() {
    pnv::build::Build::new("app.production.yaml")
        .emit()
        .unwrap_or_else(|err| panic!("{err}"));
}
```

The program then reads each value at compile time:

```rust
// src/main.rs
const DATABASE_URL: &str = env!("DATABASE_URL");
```

`Build::new` takes a path from the package root. `.flavor("staging")` picks another flavor's key, and `.key_file("path")` reads the key from a file. `.emit()` prints the cargo instructions and returns the values; `.instructions()` returns the lines without printing them.

The instructions are:

- `cargo:rerun-if-changed=` for the YAML file, the `.pnvrc` and the key file, when they exist.
- `cargo:rerun-if-env-changed=` for each `PNV_KEY_<FLAVOR>` variable the lookup read.
- `cargo:rustc-env=NAME=value` for each value. Strings are passed unquoted, and null is passed as nothing. Parse numbers yourself: `env!("SERVER_PORT").parse::<u16>()`.

[`examples/build-script/`](examples/build-script/) is a crate you can run with `cargo run`.

> [!WARNING]
> The decrypted values are compiled into the program, and cargo keeps the build script's output under `target/`. Anyone with the binary or the build directory can read them.

### Values cannot hold line breaks

Cargo reads each instruction as one line, so a value that holds a line break, such as a PEM key, fails the build with `Error::LineBreak`. A key whose name is empty or holds `=`, a NUL or a line break fails with `Error::InvalidEnvName`. Read such a file at run time instead.

## Read secrets at run time

Load the file where the program starts:

```rust
let env = pnv::Env::load("config/app.production.yaml")?;
let url = env.get("DATABASE_URL").expect("DATABASE_URL is set");
println!("connecting to {url}");
```

`Env::load` finds the key as above. `Env::read(path, &key)` and `Env::parse(yaml, &key)` take a key you already have, and `env.to_dotenv()` gives the same text `pnv generate env` writes. Nothing is put in the process environment: that is unsafe in Rust once threads run, so what to do with the values is up to you.

Values are typed by the YAML core schema: `Value::String`, `Int`, `Float`, `Bool` or `Null`. A decrypted secret is always a string. `Value` implements `Display`, which gives the plain text a build script passes on.

To read or change one value without touching the rest of the file, use `pnv::Document`: `get("database.url")`, `set("database.url", token)` (which keeps comments, order and layout), and `decrypted(&key)` for the whole file with its secrets decrypted.

The other pieces are public too: `encrypt` and `decrypt`, `Key`, `create_key`, `Pnvrc`, `flavor_from_path` and `verify`. Read them on [docs.rs](https://docs.rs/pnv).

## The `pnv` command

Every subcommand takes its input as flags and never prompts, so it runs the same on a laptop and on a build server. It exits `0` on success and `1` on any error, including a bad flag.

```sh
pnv init [-s, --storage <~/.my_project>] [-f, --flavor <name>]... [--gitignore]
pnv create key                                  # print a new key
pnv create flavor -n, --name <name> [--force]
pnv delete flavor -n, --name <name>... --force
pnv encrypt [KEY] <value>...                    # aliases: enc, e, encode
pnv decrypt [KEY] <value>...                    # aliases: dec, d, decode
pnv set <key.path> (<value>... | --stdin) -i, --file <x.yaml> [--plain] [KEY]
pnv get <key.path> -i, --file <x.yaml> [KEY]
pnv show <x.yaml> [KEY]                         # or --file <x.yaml>
pnv generate env (-i, --file <x.yaml> | -d, --directory <dir>) [-o, --output <outputs>] [KEY]
pnv verify [-d, --directory <envs>]
```

`KEY` is one of `-k, --key <key>`, `-f, --key-file <path>` or `--flavor <name>`. A flavor's key is found as above, so `PNV_KEY_<FLAVOR>` works without a `.pnvrc`. `--quiet` prints only errors and what was asked for (a key, an encrypted value); `--loud` prints every step and wins over `--quiet`.

- **`init`** writes a `.pnvrc` in the current directory, or uses the nearest one above it. Storage defaults to `~/.<project directory name>`. It adds key files already in storage as flavors, makes a key for each flavor that has none, then makes each `--flavor`. `--flavor` takes several names, repeated or comma-separated. Running it again never replaces a key. `--gitignore` adds `*.key` and `*.key.previous` to `.gitignore` once.
- **`create flavor`** refuses a flavor that already exists, or whose key file is already in storage, unless you pass `--force`. Anything encrypted with the old key will no longer decrypt.
- **`delete flavor`** deletes each flavor's key file and its `.pnvrc` entry. It refuses without `--force`, and deletes nothing if any name is unknown.
- **`set`** encrypts the value and writes it at the dotted key path, in place: comments, key order, blank lines and the rest of the file stay byte for byte as they were. Missing groups are created. A path through a value that is not a group (`app.name.oops` when `app.name` is a value, even an empty one) is refused, and on any error nothing is written. `--stdin` reads one line instead of an argument; `--plain` writes the value unencrypted and needs no key. Without a key option, the key comes from the file name's flavor.
- **`get`** prints one value, decrypted when it is a secret. A plain value prints as it is; a group is an error.
- **`show`** prints the whole file with its secrets decrypted, and nothing else. A file with no secrets, even one that is not valid YAML, prints exactly as it is. It takes the file bare, so it works as a git textconv driver: `git config diff.pnv.textconv "pnv show"` and `*.yaml diff=pnv` in `.gitattributes`.
- **`generate env`** writes `<output>/<file name>.env` for each `.yaml` or `.yml` file. With a key option, that one key decrypts every file; otherwise each file's flavor comes from its name. `--flavor` with `--directory` keeps only that flavor's files, aliases included. Every file is decrypted before any is written, so one bad file leaves nothing half done.

`pnv verify` checks that the YAML files are safe to publish, and needs a `.pnvrc` in the current directory or above it. It checks every `.yaml` and `.yml` file under the directory (default: the `.pnvrc` directory), and every document in a file with several `---` documents. In a git repo that means the files git tracks or would track, so gitignored files are skipped; elsewhere it walks the directory, skipping `.git`, `target`, `build`, `node_modules` and other build directories. It reports:

- a secret that does not decrypt with its flavor's key;
- a value that looks like a secret but is not encrypted;
- a key storage directory inside the project.

It exits `0` when nothing is wrong and `1` otherwise. A file only needs a key if it holds a secret.

## What is left out, and why

- **Prompts.** The command never asks for what you leave out; it fails and says which flag to pass. `delete flavor` needs `--force`.
- **Lists in YAML.** A list has no flat name, so it is refused.
- **Values with line breaks in a build script.** Cargo cannot pass them on, as above.
- **Writing to the process environment.** It is unsafe in Rust once threads run.
