# Change Log

## 1.9.0 | 08.13.26

### Features

- **`pnv set` / `pnv get`** — encrypt a value straight into a `.yaml` file, and read one back. No more copying a token out of the terminal and finding the right nesting level by hand. Comments, key order and indentation are preserved; missing groups are created
- **`pnv verify`** — checks that a secrets file is actually safe to commit. Every secret decrypts under the flavor its file name implies, no value that looks like a secret sits in plaintext, and the key storage directory is not inside the project. Read-only, non-zero on failure, meant for CI and pre-commit hooks
- **`pnv rotate`** — re-encrypt a file or directory under a different key. `--to` moves to an existing flavor, `--new-key` mints a fresh one and keeps the old at `<flavor>.key.previous`. All-or-nothing, and it never deletes the old key
- **`pnv import`** — build an encrypted `.yaml` from an existing `.env`, so adopting pnv is one command rather than one `encrypt` per value
- **`pnv show`** — print a file with its secrets decrypted, for use as a git textconv driver so `git diff` on a secrets file is readable
- **`pnv init` is scriptable** — `--storage`, repeatable `--flavor`, `--yes` and `--gitignore`. It was the only command that could not run without a terminal
- Secrets are now written as `SECRET1;`, carrying a version and a four-byte key fingerprint. A secret encrypted under the wrong flavor is now reported as exactly that, rather than as a possible key problem

### Behavior Changes

- Existing `SECRET;` secrets keep decrypting; only newly written secrets use the new format
- A secret is 12 bytes smaller: the version made it possible to drop the auth tag that was written twice
- `pnv init` warns when the key storage directory is inside the project

## 1.8.0 | 08.13.26

### Behavior Changes

- Commands that cannot do what was asked now exit non-zero and name the input they could not handle. Several previously printed a success line and exited `0`
- `generate env` refuses an unrecognised `--flavor` instead of treating it as "no filter". A typo used to generate **every** environment on disk, production included
- `generate env` renders the whole batch before writing any of it, so a failure part way leaves nothing behind instead of a half-populated output directory
- `generate dart` refuses an output directory holding files it did not generate, rather than deleting them
- `generate dart` fails on an env key that cannot become a valid Dart identifier, instead of emitting a file that does not compile
- Values written to `.env` are escaped, so a value containing a quote or a newline survives intact
- `pnv create key` generates 32 random bytes instead of 12. Existing 12-byte keys keep working and existing secrets are unaffected
- Key files are created with `0600` permissions
- Errors are reported through the logger rather than `print`, so they respect `--quiet` and go to stderr
- Generated `.env` files no longer carry `# .` / `# .path` breadcrumb comments before each nested block. The key prefix already carried the full path, and they collided with the `# type` convention. Comment lines are still skipped when reading a `.env`

### Features

- Add `--per-line` to `to-dart-define`, for values containing whitespace, which cannot survive `$(...)`

### Fixes

- `to-dart-define` no longer drops values containing `=`, such as base64, and no longer leaks trailing `# type` comments into the argument
- `generate dart --directory` generates every file rather than only the first
- A type comment attaches only to its own key. A nested `db.port: # int` used to type an unrelated top-level `port:`
- `create flavor --force` overwrites without prompting, so it works where there is no terminal
- `delete flavor` fails on a flavor that does not exist instead of reporting success
- Keys that are not valid base64, or are too short, are rejected by name. Key validation measured the hash, which is always 32 bytes, so it accepted everything
- Decryption failures distinguish a corrupt value from a wrong key, and name the file and key that failed
- The CLI reports its own name as `pnv` rather than `secrets`
- `create key` terminates its output with a newline

## 1.7.2 | 12.18.25

### Fixes

- Fix issue where base64 encoded secrets were not being properly decoded when generating Dart files from `.env` files

## 1.7.1 | 10.15.25

### Features

- Disable dart format when generating Dart files from `.env` files
- Ignore lines longer than 80 characters when generating Dart files from `.env` files

## 1.6.0 | 6.7.25

### Features

- Add abililty to force types when generating Dart files from `.env` files

### Enhancements

- Update README
- Update logs

## 1.5.0 | 5.08.25

### Features

- Add ability to specify the class name when generating Dart env file
  - Applies only to the `--file` flag

### Enhancements

- Add logging when creating a flavor

### Fixes

- Identify numbers as numbers when generating Dart env files

## 1.4.2 | 5.02.25

### Features

- Add ability to create flavors during the `init` command
- Create new key when flavor exists within the config but the key does not
- Add `delete flavor` command to delete a flavor and the key associated with it

### Enhancements

- Add error handling to the `generate env` command when no input or directory is provided

### Chore

- Update README.md

## 1.3.0 | 3.13.25

### Features

- Add `generate dart` command to generate Dart files from env files

### Fixes

- Fix issue where a flavor that was included in the list of additional extensions would cause an error to be thrown

### Deprecations

- `generate-env` command has been deprecated in favor of the `generate env` command
  - Functionality remains the same

## 1.2.0 | 2.5.25

### Features

- Create a `.pnvrc` config file to handle multiple flavors and storage location to easily manage secrets
  - Add `pnv init` command to create a `.pnvrc` file
  - Point to the directory where the encryption keys are stored and the flavors will be imported automatically
- Encrypt, decrypt, and generate env files with the new `--flavor` flag
- Create a new flavor with the `create flavor` command
  - Creates a new encryption key and flavor within the configuration file

### Deprecations

These deprecations will be removed in the next major release

- `create-key` command has been deprecated in favor of the `create key` command

## 1.1.0 | 11.29.24

### Enhancements

- Instead of separated commas, `to-dart-define` formats the output space separated using the `-D` flag

## 1.0.0 | 11.15.24

- Initial release
