<!-- markdownlint-disable MD033 -->

# pnv (Public Environment)

**pnv** is a Dart package designed for developers to easily encrypt and decrypt secrets, manage environment files, and generate Dart Define arguments. The goal of pnv is to simplify the process of handling environment secrets and configuration securely and use those secrets in your Dart or Flutter projects.

> [!TIP]
> Working with an AI coding agent? Point it at [`llms.txt`](llms.txt) — a complete, verified
> reference for every command, the config format, the encryption wire format, and the footguns.

## Features

- **Encryption & Decryption**: Securely encrypt and decrypt secrets using symmetric keys.
- **In-place editing**: `pnv set` and `pnv get` work on the file directly, preserving comments and formatting.
- **Safety checks**: `pnv verify` refuses to let a plaintext secret sit in a file you are about to publish.
- **Key Management**: Generate encryption keys, and rotate them with a single command.
- **Environment File Generation**: Generate `.env` files from `.yaml` configurations.
- **Dart Define Conversion**: Easily convert `.env` files to Dart Define arguments for configuration during builds.

## Installation

### Locally

To use pnv, add it to your Dart project's dev dependencies within the `pubspec.yaml`:

```bash
dart pub add pnv --dev # automatically adds the latest non-conflicting version
```

You can run it using the following command:

```bash
dart run pnv <command> [arguments]
```

### Globally

To install pnv globally, run:

```bash
dart pub global activate pnv
```

## Usage

pnv offers several commands to manage secrets and environment configuration:

```bash
pnv <command> [arguments]
```

### Global Options

- `-h`, `--help`: Print usage information.

### Commands

Working with a secrets file:

- **`set`**: Encrypt a value straight into a `.yaml` file, in place.
- **`get`**: Read one value back out, decrypted.
- **`show`**: Print a whole file with its secrets decrypted.
- **`verify`**: Check that a file is safe to commit publicly.
- **`rotate`**: Re-encrypt a file or directory under a different key.
- **`import`**: Build an encrypted `.yaml` from an existing `.env`.

Setup and keys:

- **`init`**: Initialize a pnv configuration file.
- **`create key`**: Create a new encryption key to use with pnv.
- **`create flavor`**: Create a new flavor associated with a new encryption key.
- **`delete flavor`**: Delete a flavor.

Values and build output:

- **`encrypt`**: Encrypt a secret using a previously generated key.
- **`decrypt`**: Decrypt a secret using the correct key.
- **`generate env`**: Generate a `.env` file from a `.yaml` file.
- **`generate dart`**: Generate a `dart` file from a `.env` file.
- **`to-dart-define`**: Convert an `.env` file to Dart Define arguments for use in a Dart build.

For more information on a specific command, run:

```bash
pnv help <command>
```

## Quick Start

### Creating a Configuration File

To create a pnv configuration file:

```bash
pnv init
```

This command will prompt you for the directory you'd like to store the encryption keys. By default, they will be saved `~/.<project-name>`. These settings will be saved in a `.pnvrc` file in the root of your project (next to your `pubspec.yaml`).

> [!TIP]
> For CI, a Docker build, or a project template, pass everything up front and it will not prompt:
>
> ```bash
> pnv init --storage ~/.my_project --flavor local --flavor production --yes --gitignore
> ```
>
> `--gitignore` adds `*.key` and `*.key.previous` to `.gitignore`, which is where the leak actually happens.

### Create a Flavor

To create a new flavor:

```bash
pnv create flavor --name <flavor_name>
```

This will generate a new flavor with an encryption key. The encryption key will be saved in the directory specified during the initialization process.

```plaintext
~
└── .<project-name>
    └── <flavor_name>.key
```

> [!WARNING]
> Keep this key secure and do not share it publicly. Losing the key will make it impossible to decrypt your secrets.

The configuration file will be updated with the new flavor:

```json
{
  "storage": "~/.<project-name>",
  "flavors": {
    "<flavor_name>": []
  }
}
```

The flavor name will be used as a reference to encrypt/decrypt secrets. You can create multiple flavors to manage different sets of secrets. Each flavor will have its own encryption key.

> [!TIP]
> Notice the empty array `[]` in the flavor object. This array can be used to store additional extensions that are associated with the flavor.
>
> For Example:
>
> ```json
> {
>   "storage": "~/.pnv",
>   "flavors": {
>     "ci": ["test"]
>   }
> }
> ```
>
> This configuration will allow you to use the `ci` flavor to encrypt/decrypt secrets for files that end with `*.test.yaml`
>
> [!WARNING]
>
> All flavors and supported extensions must be unique. An error will be thrown if a flavor or extension is already in use.

### Adding a Secret

The quickest way to add a secret is to write it straight into the file:

```bash
pnv set app.api-key "my_secret" --file envs/app.local.yaml
```

The flavor comes from the file name, so `app.local.yaml` uses the `local` key. Comments, key order and indentation are left alone, and groups that do not exist yet are created. Read one back with `pnv get app.api-key --file envs/app.local.yaml`, or see the whole file decrypted with `pnv show envs/app.local.yaml`.

> [!TIP]
> For a value too long or awkward to quote, pipe it in: `pbpaste | pnv set app.api-key --file envs/app.local.yaml --stdin`

### Encrypting a Secret

To encrypt a value without writing it anywhere:

```bash
pnv encrypt "my_secret" --flavor <flavor_name>
```

This will output the encrypted version of your secret. Make sure to store the key securely. This is what your secret would look like

```plaintext
SECRET;DrQgp57CPCGY9b/0e2po3AYHIP/Svv+JbYc0+g60IKeewjwhmPW/9HtqaNw=
```

> [!TIP]
> Avoid word splitting by using double quotes, e.g. "a value with spaces"
>
> If the value is too long or hard to manage, try copying the value and using `pbpaste` directly in the command:
>
> ```bash
> pnv encrypt --key <key-value> "$(pbpaste)"
> ```

### Decrypting a Secret

To decrypt a secret value:

```bash
pnv decrypt "SECRET;<encoded_data>" --flavor <flavor_name>
```

If the key is correct, the decrypted secret will be displayed. If the key is incorrect, an error message will be shown.

### Converting Environment Variables to Dart Define

To convert environment variables in a `.env` file to Dart Define arguments:

```bash
pnv to-dart-define .env
```

This will generate arguments that can be used for `--dart-define` during a Dart or Flutter build. For example:

```dotenv
# .env
SECRET=my_secret
```

The output would be:

```bash
-DSECRET=my_secret
```

> [!WARNING]
> A value containing a space cannot survive `$(pnv to-dart-define .env)`. The shell splits the *result* of a command substitution into words, and no quoting inside that result prevents it. pnv warns and names the keys affected.
>
> Use `--per-line` with `xargs` whenever any value might contain whitespace:
>
> ```bash
> pnv to-dart-define --per-line .env | xargs flutter build apk
> ```

## Checking a File Is Safe to Publish

pnv's whole premise is that the encrypted `.yaml` can live in a public repo. `pnv verify` is what checks that premise actually holds:

```bash
pnv verify
```

It reads without writing, and exits non-zero if anything is wrong:

- a secret that does not decrypt under the flavor its file name implies — which usually means it was pasted in from another environment
- a corrupt `SECRET;` value, reported as corrupt rather than as a key problem
- a value that **looks** like a secret sitting in plaintext, matched by shape (`sk-`, `ghp_`, `AKIA`, JWTs, private key blocks, URLs carrying a password) or by a key name that promises one
- key storage inside the project directory

That makes it a natural pre-commit hook or CI step. If a value is meant to be public, say so with a trailing comment and pnv will leave it alone:

```yaml
demo-token: sk-live-not-a-real-key # plaintext, used in the public demo
```

## Rotating a Key

```bash
pnv rotate --directory envs --from production --to production-2026   # to another flavor
pnv rotate --directory envs --from production --new-key              # fresh key, same flavor
```

Everything is re-encrypted in memory before anything is written, so a run that fails part way leaves the files untouched. `--new-key` keeps the old key at `<flavor>.key.previous`; nothing deletes a key for you.

Add `--dry-run` to see what would change.

## Adopting pnv in an Existing Project

```bash
pnv import .env --output envs/app.local.yaml
```

Every value is encrypted by default, because over-encrypting is safe and under-encrypting leaks. Pass `--only-secrets` to leave plain config readable.

Keys stay flat and lowercased so they regenerate identically — `APP_RUN_TIME_KEY` becomes `app_run_time_key`, not a guess at where the nesting was. Group them by hand afterwards if you want the structure.

## Readable Diffs

A fresh IV per encryption means an unchanged value still produces a different token, so `git diff` on a secrets file is two walls of unrelated base64. `pnv show` fixes that as a textconv driver:

```gitattributes
# .gitattributes
*.local.yaml diff=pnv
```

```ini
# .git/config
[diff "pnv"]
  textconv = pnv show
```

Anyone holding the key gets a readable diff; anyone without one sees what they see today.

## Env Yaml

You can organize your encrypted secrets within a YAML file for better structure and readability. pnv will generate environment variables by combining all the nested keys, separated by underscores, and converting them to uppercase. Here are examples of how you can structure your YAML file:

### Yaml File

```yaml
# env_files/app.local.yaml
secret: SECRET;<encoded_data>

api:
  schema: http
  host: localhost
  port: 8080
  key: SECRET;<encoded_data>
```

You can then run the `generate env` command to create an `.env` file:

```bash
pnv generate env --directory env_files --output env_files/outputs
```

This would generate the following environment variable:

```dotenv
# env_files/outputs/app.local.env
SECRET="<decoded_data>"
API_SCHEMA="http"
API_HOST="localhost"
API_PORT=8080
API_KEY="<decoded_data>"
```

When the `generate env` command is called, pnv will combine the keys to create flat environment variable names, which makes them compatible with most CI/CD tools and other environment management systems.

> [!NOTE]
> The output file is named after the input file, so `app.local.yaml` produces `app.local.env`. String values are quoted; numbers and booleans are not.

> [!TIP]
>
> If you would like to generate the env file for a specific flavor, you can use the `--flavor` flag:
>
> ```bash
> pnv generate env --directory env_files --output env_files/outputs --flavor ci
> ```
>
> All file extensions associated with the flavor will be generated into `.env` files.

### Multiple Environments

In a typical project, you may have multiple environments, such as `development`, `staging`, and `production`. You can create a separate YAML file for each environment and generate the `.env` files for each environment.

```plaintext
.
└── env_files
    ├── app.development.yaml
    ├── app.staging.yaml
    └── app.production.yaml
```

Each of these files can contain the same structure but with different values. You can then generate the `.env` files for each environment:

```bash
# Generate all environments
pnv generate env --directory env_files

# Generate development environment
pnv generate env --directory env_files --flavor development

# Generate staging environment
pnv generate env --directory env_files --flavor staging

# Generate production environment
pnv generate env --directory env_files --flavor production
```

Mentioned above, you can configure the `.pnvrc` file to associate different extensions with different flavors.

```json
{
  "storage": "~/.pnv",
  "flavors": {
    "development": ["dev"],
    "staging": ["stg"],
    "production": ["prod", "ci"]
  }
}
```

## Encryption Details

pnv uses AES-GCM for encryption and decryption, providing strong confidentiality and data integrity.

### Encryption Process

- **Algorithm**: AES (Advanced Encryption Standard) in GCM (Galois/Counter Mode).
- **Initialization Vector (IV)**: A random IV is generated for each encryption operation, ensuring that the same plaintext will produce a different ciphertext each time.
- **Authentication Tag**: AES-GCM produces an authentication tag that verifies the integrity and authenticity of the encrypted data.
- **Token format**: `SECRET1;` + base64(`keyId[4]` || `iv[12]` || `ciphertext` || `tag[16]`). The key id is a domain-separated hash of the key, never of the AES key itself, so it identifies the key without revealing any part of it. Older `SECRET;` values keep decrypting.
- **Key**: `pnv create key` generates 32 random bytes from a secure source. The AES key is the SHA-256 of the decoded key, so key files created before `1.8.0` are 12 bytes and still work — rotating one gets you the full 256 bits of entropy.
- **Key files** are created readable only by their owner (`0600`).

### Encryption

During encryption, the plaintext value is combined with a randomly generated IV and encrypted using AES-GCM. The output includes an authentication tag, the IV, and the ciphertext.

- **Authentication Tag**: Ensures data integrity.
- **IV**: Allows proper decryption.
- **Ciphertext**: The encrypted version of the plaintext.

These components are combined and base64 encoded, producing the final secret in the format `SECRET;<encoded_data>`.

### Decryption

During decryption, the encoded secret is split to retrieve the authentication tag, IV, and encrypted data from the encoded secret. Using AES-GCM, it verifies the data integrity and then decrypts the ciphertext, producing the original plaintext.

By using a secure, random IV and verifying integrity with the authentication tag, pnv ensures robust encryption that protects against replay attacks and guarantees authenticity.

## Generated Dart File

Leveraging Dart's type system, pnv can generate a Dart file that contains the environment variables static values.

Lets say you have the following `.env` file:

```dotenv
# .env
MY_STRING="hello"
MY_NUM=123
MY_BOOL=true
```

You can generate a Dart file that contains the environment variables static values.

```bash
pnv generate dart --output lib/envs --file private/.env
```

> [!TIP]
>
> Run `pnv generate dart --help` to see all the options for the `generate dart` command.

```dart
class MyEnv {
  const MyEnv._();

  static const myString = String.fromEnvironment('MY_STRING');
  static const myNum = int.fromEnvironment('MY_NUM');
  static const myBool = bool.fromEnvironment('MY_BOOL');
}
```

### Force Types

Occasionally, you may have an environment variable that only exists in certain environments. For example, you have a `DB_PORT` that exists in the `development` environment but not in the `production` environment.

In cases like this, you can tell pnv to force the type of the environment variable by adding a comment after the value

```yaml
# app.yaml

db:
  port: # int
```

Which will (roughly) generate the following `.env` file:

```dotenv
DB_PORT= # int
```

This will force the type within the generated Dart file to be an `int`
