# Change Log

## 1.4.1 | 5.02.25

### Features

- Add ability to create flavors during the `init` command
- Create new key when flavor exists within the config but the key does not
- Add `delete flavor` command to delete a flavor and the key associated with it

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
