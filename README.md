<!-- markdownlint-disable MD033 -->
# pnv (Public Environment)

**pnv** is a Dart package designed for developers to easily encrypt and decrypt secrets, manage environment files, and generate Dart Define arguments. The goal of pnv is to simplify the process of handling environment secrets and configuration securely and use those secrets in your Dart or Flutter projects.

## Features

- **Encryption & Decryption**: Securely encrypt and decrypt secrets using symmetric keys.
- **Key Management**: Generate encryption keys for secure use across environments.
- **Environment File Generation**: Generate `.env` files from `.yaml` configurations.
- **Dart Define Conversion**: Easily convert `.env` files to Dart Define arguments for configuration during builds.

## Installation

### Locally

To use pnv, add it to your Dart project's `pubspec.yaml`:

```bash
dart pub add pnv # automatically adds the latest non-conflicting version
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

- **`create-key`**: Create a new encryption key for use with pnv.
- **`encrypt`**: Encrypt a secret using a previously generated key.
- **`decrypt`**: Decrypt a secret using the correct key.
- **`generate-env`**: Generate a `.env` file from a `.yaml` file.
- **`to-dart-define`**: Convert an `.env` file to Dart Define arguments for use in a Dart build.

For more information on a specific command, run:

```bash
pnv help <command>
```

## Quick Start

### Creating an Encryption Key

To create an encryption key:

```bash
pnv create-key
```

This command will generate a new encryption key that can be used for encrypting and decrypting secrets.

> [!WARNING]
> Keep this key secure and do not share it publicly. Losing the key will make it impossible to decrypt your secrets.

### Encrypting a Secret

To encrypt a secret value:

```bash
pnv encrypt --key <key_value> "my_secret"
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
pnv decrypt --key <key_value> SECRET;<encoded_data>
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

## Env Yaml

You can organize your encrypted secrets within a YAML file for better structure and readability. pnv will generate environment variables by combining all the nested keys, separated by underscores, and converting them to uppercase. Here are examples of how you can structure your YAML file:

### Yaml File

```yaml
# env_files/local.yaml
secret: SECRET;<encoded_data>

api:
  schema: http
  host: localhost
  port: 8080
  key: SECRET;<encoded_data>
```

You can then run the `generate-env` command to create an `.env` file:

```bash
pnv generate-env --key <key_value> --input env_files/local.yaml --output env_files/outputs/
```

This would generate the following environment variable:

```dotenv
# env_files/outputs/local.env
SECRET=<decoded_data>
API_SCHEMA=http
API_HOST=localhost
API_PORT=8080
API_KEY=<decoded_data>
```

When the `generate-env` command is called, pnv will combine the keys to create flat environment variable names, which makes them compatible with most CI/CD tools and other environment management systems.

## Encryption Details

pnv uses AES-GCM for encryption and decryption, providing strong confidentiality and data integrity.

### Encryption Process

- **Algorithm**: AES (Advanced Encryption Standard) in GCM (Galois/Counter Mode).
- **Initialization Vector (IV)**: A random IV is generated for each encryption operation, ensuring that the same plaintext will produce a different ciphertext each time.
- **Authentication Tag**: AES-GCM produces an authentication tag that verifies the integrity and authenticity of the encrypted data.

### Encryption

During encryption, the plaintext value is combined with a randomly generated IV and encrypted using AES-GCM. The output includes an authentication tag, the IV, and the ciphertext.

- **Authentication Tag**: Ensures data integrity.
- **IV**: Allows proper decryption.
- **Ciphertext**: The encrypted version of the plaintext.

These components are combined and base64 encoded, producing the final secret in the format `SECRET;<encoded_data>`.

### Decryption

During decryption, the encoded secret is split to retrieve the authentication tag, IV, and encrypted data from the encoded secret. Using AES-GCM, it verifies the data integrity and then decrypts the ciphertext, producing the original plaintext.

By using a secure, random IV and verifying integrity with the authentication tag, pnv ensures robust encryption that protects against replay attacks and guarantees authenticity.
