# pnv

Safely store environment variables in a public repository: encrypted YAML secrets, flavors and a `.pnvrc` config. There is a Dart tool and a Rust crate. They read and write the same files, so a secret one wrote, the other reads.

| | Dart | Rust |
| --- | --- | --- |
| Folder | [`dart/`](dart/) | [`rust/`](rust/) |
| Get it | `dart pub global activate pnv` ([pub.dev](https://pub.dev/packages/pnv)) | `cargo add pnv` or `cargo install pnv` ([crates.io](https://crates.io/crates/pnv)) |
| Use it as | a command-line tool, at dev time | a library for build scripts and run time, and a command |
| Commands | init, create/delete flavor, encrypt, decrypt, set, get, show, generate env, generate dart, to-dart-define, import, rotate, verify | init, create key, create/delete flavor, encrypt, decrypt, generate env, verify |
| Output | `.env` files, a Dart class, `--dart-define` arguments | `cargo:rustc-env` values in a build script, or an `Env` at run time |
| Read more | [`dart/README.md`](dart/README.md), [`dart/llms.txt`](dart/llms.txt) | [`rust/README.md`](rust/README.md), [`rust/llms.txt`](rust/llms.txt) |

Pick by your project's language. In a mixed repo, use either one to manage the YAML and keys, and the matching one to read them: the Rust crate needs no `.pnvrc` when `PNV_KEY_<FLAVOR>` is set (the Dart tool does not read that variable yet).

[`spec/`](spec/) holds the format and the test vectors both tools pass.

Dart releases are tagged `dart-v<version>`.
