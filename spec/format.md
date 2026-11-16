# pnv format specification

This is the contract every pnv implementation follows, so that a secret, key or `.pnvrc` written by
one can be read by any other. It covers what is stored on disk and what the tools compute from it.
It does not cover command-line flags or messages.

The Dart package in `dart/` is the reference implementation. Where this document and the Dart code
disagree, that is a bug in one of them: fix it, don't work around it.

The words MUST, MUST NOT, SHOULD and MAY are used as in RFC 2119.

## Test vectors

`spec/vectors/` holds the cases every implementation MUST pass. Each file is JSON with a
`description` field saying how to read its cases. A case may carry a `note`, which explains the case
and is not part of the check.

| File | Covers | Section |
| --- | --- | --- |
| `keys.json` | decoding a key, the AES key, the key id | [Keys](#keys) |
| `tokens.json` | parsing, decrypting and writing `SECRET;` tokens | [The `SECRET;` token](#the-secret-token) |
| `yaml_env.json` | YAML file to `.env` text | [YAML to `.env`](#yaml-to-env) |
| `flavor_from_path.json` | the flavor a file name implies | [Flavor from a file name](#flavor-from-a-file-name) |
| `pnvrc.json` | `.pnvrc` parsing, the conflict rule, alias groups | [`.pnvrc`](#pnvrc) |
| `plaintext_detector.json` | what counts as a secret left in plaintext | [Plaintext detection](#plaintext-detection) |

Byte strings in the vectors are lowercase hex. A case with an `error` field expects that kind of
failure instead of a result. The kinds are listed with the section they belong to.

The vectors are frozen. Tokens in them must keep decrypting for as long as pnv reads that version,
so an existing case is never regenerated, only added to. A change of behavior adds cases and updates
this document in the same change.

`dart/test/spec/vectors_test.dart` runs every case against the Dart package.

## Base64

pnv uses two base64 alphabets (RFC 4648):

- **Keys** are written in the URL-safe alphabet (`-` and `_`).
- **Tokens** are written in the standard alphabet (`+` and `/`).

Both are always written with `=` padding.

Every decoder, for keys and tokens alike, MUST:

- accept both alphabets, including both mixed in one string;
- require padding, so the length is a multiple of 4 (`YWI` is refused, `YWI=` is accepted);
- refuse non-zero trailing bits in the last character (`YWJ=` is refused);
- refuse whitespace, line breaks and any other character, anywhere in the string;
- refuse `=` anywhere but the last one or two positions.

An empty string decodes to zero bytes.

The Dart decoder also accepts `%3D` (a URL-encoded `=`) in place of a padding `=`. pnv never writes
it, and no vector depends on it; other decoders MAY accept it.

## Keys

A key is a random byte string, stored base64-encoded in a key file. Vectors: `keys.json`.

### Making a key

A new key is 32 bytes from a cryptographically secure random source, base64url-encoded with padding:
44 characters, the last one `=`.

Keys made before pnv 2.0 are 12 bytes (16 characters). They MUST keep working.

### Reading a key

- **From a key file**: the whole file, with leading and trailing whitespace (including line breaks)
  removed, is the key string.
- **From `--key`**: the argument as given, not trimmed. An argument that is empty or only whitespace
  counts as no key at all.

Decode the key string with the base64 rules above to get the **key bytes**. Refuse it with:

| Kind | When |
| --- | --- |
| `invalid-key` | the string is not valid base64 |
| `key-too-short` | it decodes to fewer than 12 bytes (an empty key file lands here) |

There is no upper limit on key length.

### What the key bytes give

```
aes_key = SHA-256(key_bytes)                                    32 bytes
key_id  = SHA-256(utf8("pnv:key-id:v1") || key_bytes)[0..4]     4 bytes
```

`aes_key` is the AES-256 key. The key bytes are never used as the cipher key directly, so a key's
length is its entropy, not the cipher's key size.

`key_id` is a label that shows which key encrypted a secret. The domain separator `pnv:key-id:v1`
(13 ASCII bytes, no terminator) is load-bearing: without it the key id would be the first 4 bytes of
`aes_key`, published in every committed secret. The key id is not a security boundary. The auth tag
is what rejects a wrong key.

### Key files

A key file lives at `<storage>/<flavor>.key` (see [`.pnvrc`](#pnvrc)). Writers MUST:

- write the key string with no trailing newline;
- make the file readable and writable by its owner only (mode `0600`), where the platform allows it.

`pnv rotate --new-key` copies the old key file, unchanged, to `<storage>/<flavor>.key.previous`
(mode `0600`) before it writes the new key.

## The `SECRET;` token

A token is one encrypted value, stored as a YAML string. Vectors: `tokens.json`.

### Layout

```
v1   "SECRET;v1:" + base64( key_id[4] || iv[12] || ciphertext[n] || tag[16] )
v0   "SECRET;"    + base64( tag[16]   || iv[12] || ciphertext[n] || tag[16] )
```

- `iv` is the 12-byte AES-GCM nonce.
- `ciphertext` is the UTF-8 plaintext encrypted with AES-256-GCM under `aes_key`, with no
  additional authenticated data. It is as long as the plaintext, so `n` may be 0.
- `tag` is the 16-byte GCM auth tag.
- v0 writes the tag twice. A reader uses the trailing copy and ignores the leading one.

`SECRET;` is the prefix in every version, and it is case-sensitive. People and scripts outside pnv
match on it (`SECRET;*` globs, `grep -E '^\s*key:\s*SECRET;'`), so a new version MUST keep it and
put its marker after it. The marker is unambiguous because `:` is not a base64 character, so a v0
payload can never begin with `v1:`.

### Writing a token

Writers MUST write v1 only:

1. Draw a fresh 12-byte IV from a cryptographically secure random source, for every value. Never
   reuse one. Encrypting the same value twice gives two different tokens.
2. Encrypt the UTF-8 bytes of the value with AES-256-GCM, key `aes_key`, that IV, a 128-bit tag and
   no additional data.
3. Write `SECRET;v1:` followed by the standard-alphabet base64 of `key_id || iv || ciphertext || tag`.

The `encrypt` cases in `tokens.json` fix the IV so a writer can be checked byte for byte.

### Reading a token

1. If the value does not start with `SECRET;`, it is not a secret (`not-a-secret`).
2. Take what follows. If it starts with `v1:`, it is version 1 and the payload is what follows that.
   Otherwise it is version 0 and the payload is all of it. Any other marker, `v2:` for example, is
   read as a v0 payload and fails base64 decoding.
3. Base64-decode the payload with the rules above. On failure: `malformed`.
4. The payload MUST be at least 32 bytes for v1 (4 + 12 + 16) and 44 bytes for v0 (16 + 12 + 16).
   Shorter: `malformed`.
5. Split it into its fields as laid out above.
6. **v1 only**: compare the token's key id with the key id of the key in hand. If they differ, fail
   with `wrong-key` and do not run the cipher. This holds even if the cipher would have succeeded.
7. Decrypt and verify with AES-256-GCM. If the tag does not verify, fail with `decrypt-failed`.
8. Decode the plaintext as strict UTF-8. If that fails, fail with `decrypt-failed`.

v0 tokens have no key id, so for them a wrong key is found only at step 7 and reported as
`decrypt-failed`.

| Kind | Meaning | What to tell the user |
| --- | --- | --- |
| `not-a-secret` | no `SECRET;` prefix | the value is not a pnv secret |
| `malformed` | the payload is not base64 or too short | the value is corrupt; it is not a key problem |
| `wrong-key` | v1 key id does not match the key | encrypted with a different key: check the flavor |
| `decrypt-failed` | the tag did not verify, or the plaintext is not UTF-8 | the value is well formed, so most likely the wrong key |

Known divergence: the Dart `pnv decrypt` command skips step 6 and goes straight to the cipher. Every
other Dart code path checks the key id. New implementations MUST check it everywhere.

## `.pnvrc`

The project's pnv configuration: JSON, despite the name. Vectors: `pnvrc.json`.

```json
{
  "storage": "~/.my_project",
  "flavors": {
    "local": [],
    "production": ["prod", "ci"]
  }
}
```

| Field | Type | Meaning |
| --- | --- | --- |
| `storage` | string, required | the directory holding the `<flavor>.key` files |
| `flavors` | object of string to array of strings, optional (default `{}`) | each flavor's name, mapped to its aliases |

- A `storage` that starts with `~` has that first `~` replaced with the home directory: `$HOME`, or
  `%USERPROFILE%` on Windows. Any other path is used as written. A relative path is relative to the
  current directory.
- A missing `storage`, or a field of the wrong type, makes the file invalid (`invalid`).
- Unknown fields are ignored.
- A file that is empty or only whitespace, or whose JSON is not an object, counts as no `.pnvrc`.
- A file that is not valid JSON is an error.
- New flavor names MUST match `^[a-zA-Z0-9_-]+$`.

### The conflict rule

Every name, flavor or alias, MUST be unique across the whole file. To check:

1. For each flavor, take its alias list and remove the first entry equal to the flavor's own name, if
   there is one.
2. Collect every flavor name and every remaining alias into one list.
3. If any name appears twice, the file is invalid (`conflict`).

An invalid `.pnvrc` stops every command that loads it, including `encrypt`.

### Alias groups

A name resolves to a **group**: the flavor and all of its aliases.

- If the name is a flavor, the group is that flavor and its aliases.
- Otherwise, if the name is an alias of a flavor (the first in file order), the group is that
  flavor and its aliases.
- Otherwise the name is unknown.

### Finding `.pnvrc`

1. Walk up from the current directory to the filesystem root, looking for `pubspec.yaml`. If one is
   found, `.pnvrc` is the file next to the nearest one, whether or not it exists.
2. If there is no `pubspec.yaml`, walk up from the current directory and take the nearest `.pnvrc`.
3. Otherwise there is none.

### Writing `.pnvrc`

Write `storage` first, then `flavors`, as JSON indented with two spaces, with no trailing newline.
Writers SHOULD keep flavors in their existing order and add new ones at the end, so a rewrite
changes only what changed.

## Key resolution

How a command picks the key, first match wins:

1. `--key <string>`: the key string itself.
2. `--key-file <path>`: the contents of that file, trimmed.
3. `--flavor <name>`:
   1. `<storage>/<name>.key`, if that file exists;
   2. otherwise the first flavor, in file order, whose alias list contains `<name>` and whose key
      file exists.
4. Commands that act on a file (`set`, `get`, `show`, `verify`, `rotate`, `import`,
   `generate env --file`) and were given none of the above take the flavor from the file's name (see
   [below](#flavor-from-a-file-name)) and resolve it as in step 3.

If nothing matches, the command fails and says which key it could not find.

## Flavor from a file name

The flavor a file's name implies. Only the last path component matters. Vectors:
`flavor_from_path.json`.

1. Take the file name without its last extension (`app.local.yaml` gives `app.local`). If that
   contains no `.`, it is the flavor (`local.yaml` gives `local`).
2. Otherwise take the last two extensions (`.local.yaml`), drop a trailing `.env`, then a trailing
   `.yaml` or `.yml`, then one leading `.`. What is left is the flavor (`local`).

An extension is a `.` followed by text, where the `.` is not the first character of the name. So
`.env` has no extension and `.local.yaml` has one (`.yaml`). Extension matching is case-sensitive.

The result can be empty (`.env`) or not a real flavor (`app.local.json` gives `local.json`). The
vectors pin these edge cases.

## YAML to `.env`

`pnv generate env` turns one YAML file into `.env` text. Vectors: `yaml_env.json`, where every case
uses the file key given at the top.

### The input

- An empty file, or one with only comments or a `---` marker, gives empty output.
- The top level MUST be a mapping (`not-a-map` otherwise).
- YAML is read with the YAML 1.2 core schema, and the scalar types decide the output:
  - **null**: `~`, `null`, `Null`, `NULL`, or nothing after the `:`.
  - **bool**: `true`, `True`, `TRUE`, `false`, `False`, `FALSE`. `yes`, `no`, `on` and `off` are
    strings.
  - **int**: decimal with an optional sign (`007` is 7, `+12` is 12), or `0x` hexadecimal and `0o`
    octal with no sign (`-0x1F` and `0o8` are strings). An int that does not fit in a signed 64-bit
    integer is read as a float.
  - **float**: decimals and exponents (`1.5`, `1e3`, `.5`), `.inf`, `-.inf`, `.nan` in any of their
    core-schema spellings.
  - Anything else, including dates (`2024-01-01`), `1_000` and quoted scalars, is a **string**.
- A value that is a sequence fails the whole file (`unsupported-type`). Lists are not supported.
- Anchors and aliases are resolved: an alias renders like the node it points to.

### One line per value

The file is walked depth first in document order. Each value that is not a mapping becomes one line:

```
<NAME>=<value>[ # <comment>]\n
```

**Name**: the keys on the path to the value, each turned into a string, joined with `_`, then
uppercased, then every `-` replaced with `_`. Nothing else changes, so `dotted.key` gives
`DOTTED.KEY` and `with space` gives `WITH SPACE`. A mapping only contributes its key to the names
below it. An empty mapping produces nothing.

**Value**:

| YAML type | Written as |
| --- | --- |
| string | `"` + escaped text + `"` |
| string starting with `SECRET;` | decrypted, then written like any other string |
| int | decimal digits, with `-` when negative |
| float | as described below |
| bool | `true` or `false` |
| null | nothing |

**Rendering a float**: the shortest decimal that reads back as the same 64-bit float (as in
ECMAScript `Number.prototype.toString`), with two differences: a value with no fractional part and an
absolute value below 1e21 gets `.0` appended, and negative zero keeps its sign:

| YAML | Written |
| --- | --- |
| `1.5` | `1.5` |
| `1.0`, `0.1e1` | `1.0` |
| `1e3` | `1000.0` |
| `1e20` | `100000000000000000000.0` |
| `1e21` | `1e+21` |
| `1.5e-7` | `1.5e-7` |
| `0.000001` | `0.000001` |
| `-0.0` | `-0.0` |
| `.inf`, `-.inf`, `.nan` | `Infinity`, `-Infinity`, `NaN` |

**Escaping**: every string value, decrypted or not, is escaped in this order: `\` becomes `\\`,
`"` becomes `\"`, carriage return becomes `\r`, newline becomes `\n`. Nothing else is escaped; a tab
stays a tab. So a multi-line secret, such as a PEM key, stays on one line.

**Comment**: if the value's own line has a `#` after the value, the text after the first such `#`,
trimmed, is the comment. If it is not empty, write it after the value as ` # <comment>`. The search
starts where the value ends in the source and stops at the end of that line. It never looks at other
lines, so a comment on a line of its own is never carried over. This is how `# int`, `# bool`,
`# num` and `# string` type declarations reach `generate dart`.

**Line endings**: every line ends with `\n`, whatever the input used.

**Errors**: any value that fails to decrypt fails the whole file, with the token error kinds above.
A failed file produces no output at all.

## Plaintext detection

`pnv verify` flags values that look like secrets left unencrypted. Vectors:
`plaintext_detector.json`.

### Which values are checked

Every leaf of the file, at every depth, whose YAML value is a string not starting with `SECRET;`.
Ints, floats, bools, nulls and sequences are never checked. The **key path** is the keys from the top
joined with `.`. The **comment** is found as in [YAML to `.env`](#yaml-to-env).

### The rule

For one value, with surrounding whitespace removed:

1. If the comment contains `plaintext` (any case, anywhere in the comment), it is not flagged.
2. If the value is empty, it is not flagged.
3. If the value matches a credential shape, in this order, it is flagged as that shape:

   | Shape | Pattern |
   | --- | --- |
   | an OpenAI-style API key | `^sk-[A-Za-z0-9_-]{16,}$` |
   | a GitHub token | `^(ghp\|gho\|ghu\|ghs\|ghr)_[A-Za-z0-9]{20,}$` |
   | a GitHub fine-grained token | `^github_pat_[A-Za-z0-9_]{20,}$` |
   | an AWS access key id | `^(AKIA\|ASIA)[0-9A-Z]{16}$` |
   | a Slack token | `^xox[baprs]-[A-Za-z0-9-]{10,}$` |
   | a Stripe key | `^(sk\|rk)_(live\|test)_[A-Za-z0-9]{16,}$` |
   | a Google API key | `^AIza[A-Za-z0-9_-]{35}$` |
   | a JWT | `^eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$` |
   | a private key block | `-----BEGIN [A-Z ]*PRIVATE KEY-----` (anywhere in the value) |
   | a connection string with a password | `^[a-z][a-z0-9+.-]*://[^/\s:@]+:[^/\s@]+@`, case-insensitive |

   The reason is `looks like <shape>`.
4. Otherwise take the last segment of the key path (the **leaf**). It is flagged when all of these
   hold:
   - the leaf matches the risky-name pattern, case-insensitive:
     `(^|[-_.])(key|secret|token|password|passwd|pwd|credential|credentials|auth|apikey|private|cert|signature|salt)([-_.]|$)`;
   - it does not match the public-name pattern, case-insensitive:
     `(^|[-_.])(public[-_.]?key|key[-_.]?name|key[-_.]?id|auth[-_.]?url|auth[-_.]?domain|token[-_.]?url|token[-_.]?name)([-_.]|$)`;
   - the value is at least 8 characters long;
   - the value is not a placeholder.

   The reason is `the key is named "<leaf>" but the value is not encrypted`.
5. Otherwise it is not flagged.

A value is a **placeholder** when, lowercased and with all whitespace and `_` removed, it:

- is one of `changeme`, `change-me`, `replace`, `replaceme`, `replace-me`, `placeholder`, `todo`,
  `unset`, `none`, `null`, `example`, `xxxxxxxx`; or
- starts with `<`, `${`, `your-` or `my-`.

Regular expressions here use the common syntax that Dart, Rust's `regex` crate and ECMAScript
share. `\s` is whitespace, and `[A-Z ]` contains a literal space.
