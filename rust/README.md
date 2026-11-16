# pnv for Rust

Read encrypted secrets from YAML files that are safe to commit, in a build script or when your program runs. This crate reads and writes the same keys, `SECRET;` tokens and `.pnvrc` as the [Dart `pnv` tool](../dart/README.md), following the shared [format spec](../spec/format.md).

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

Make a key with the command, and keep it out of the repository.

```sh
pnv create key > ~/.my_project/production.key
```

Creating and editing secrets in the YAML file is done by the Dart tool today (see [What is left out](#what-is-left-out-and-why)).

## Find the key

Both ways of reading a file find its key the same way. The first match wins:

1. The `PNV_KEY_<FLAVOR>` environment variable: the flavor in capitals, with `-` turned into `_` (`production` gives `PNV_KEY_PRODUCTION`). It is trimmed, and a blank one counts as unset. It needs no `.pnvrc`.
2. `<storage>/<flavor>.key`, from the nearest `.pnvrc` in the current directory or above it.
3. For a flavor that lists the name as an alias, steps 1 and 2 again for that flavor.

The flavor comes from the file name: `app.production.yaml` is `production`, and `local.yaml` is `local`. The `.pnvrc` is the one the Dart tool writes (`{"storage":"keys","flavors":{"production":["ci"]}}`), and is only read when a flavor needs it. On a build server, set `PNV_KEY_PRODUCTION` and ship no key file.

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

`Env::load` finds the key as above. `Env::read(path, &key)` and `Env::parse(yaml, &key)` take a key you already have, and `env.to_dotenv()` gives the text the Dart tool's `pnv generate env` writes. Nothing is put in the process environment: that is unsafe in Rust once threads run, so what to do with the values is up to you.

Values are typed by the YAML core schema: `Value::String`, `Int`, `Float`, `Bool` or `Null`. A decrypted secret is always a string. `Value` implements `Display`, which gives the plain text a build script passes on.

The other pieces are public too: `encrypt` and `decrypt`, `Key`, `create_key`, `Pnvrc`, `flavor_from_path` and `verify`. Read them on [docs.rs](https://docs.rs/pnv).

## The `pnv` command

The command has two subcommands:

```sh
pnv create key               # print a new key
pnv verify [-d, --directory <envs>]
```

`pnv verify` checks that the YAML files are safe to publish, and needs a `.pnvrc` in the current directory or above it. It walks every `.yaml` and `.yml` file under the directory (default: the `.pnvrc` directory), skipping `.git`, `target`, `build`, `node_modules` and `.dart_tool`, and reports:

- a secret that does not decrypt with its flavor's key;
- a value that looks like a secret but is not encrypted;
- a key storage directory inside the project.

It exits `0` when nothing is wrong and `1` otherwise. A file only needs a key if it holds a secret.

## What is left out, and why

- **Most commands.** The command has `create key` and `verify`. `init`, `create flavor`, `delete flavor`, `encrypt`, `decrypt`, `set`, `get`, `show` and `generate env` are not in it yet. Use the Dart tool for these: the files are the same, so each tool reads what the other wrote.
- **`generate dart` and `to-dart-define`.** They produce Dart code and Dart arguments, so they belong to the Dart tool.
- **Lists in YAML.** A list has no flat name, so it is refused, as in the Dart tool.
- **Values with line breaks in a build script.** Cargo cannot pass them on, as above.
- **Writing to the process environment.** It is unsafe in Rust once threads run.
