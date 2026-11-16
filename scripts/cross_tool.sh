#!/usr/bin/env bash
# Cross-tool test: each pnv tool reads what the other wrote.
#
# Builds the Dart and Rust tools, then runs two rounds in a throwaway project:
#   1. Dart inits the project and sets secrets; Rust reads them
#      (get, show, generate env, verify, decrypt).
#   2. Rust inits a project and sets secrets; Dart reads them.
# In both rounds the .env files from the two tools must match byte for byte.
#
# Usage: scripts/cross_tool.sh
# Env:   PNV_DART_BIN / PNV_RUST_BIN  use a prebuilt tool instead of building.
#        DART  path of the dart executable (default: dart on PATH).
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

pass=0
fail=0
ok() { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL %s\n' "$1"; }

# expect <label> <expected> <actual>
expect() {
  if [ "$2" == "$3" ]; then ok "$1"; else
    bad "$1"
    printf '    expected: %s\n    actual:   %s\n' "$2" "$3"
  fi
}

# same_file <label> <a> <b>: byte-for-byte equal
same_file() {
  if cmp -s "$2" "$3"; then ok "$1"; else
    bad "$1"
    diff -u "$2" "$3" | sed 's/^/    /' || true
  fi
}

echo "== build"
dart_bin="${PNV_DART_BIN:-}"
if [ -z "$dart_bin" ]; then
  dart_bin="$work/pnv-dart"
  (cd "$root/dart" && "${DART:-dart}" pub get >/dev/null \
    && "${DART:-dart}" compile exe bin/pnv.dart -o "$dart_bin" >/dev/null)
fi
rust_bin="${PNV_RUST_BIN:-}"
if [ -z "$rust_bin" ]; then
  cargo build --release --quiet --manifest-path "$root/rust/Cargo.toml"
  rust_bin="$(cargo metadata --format-version 1 --no-deps \
    --manifest-path "$root/rust/Cargo.toml" \
    | sed -n 's/.*"target_directory":"\([^"]*\)".*/\1/p')/release/pnv"
fi
dart_pnv() { "$dart_bin" "$@"; }
rust_pnv() { "$rust_bin" "$@"; }
echo "  dart: $dart_bin"
echo "  rust: $rust_bin"

# The same YAML goes into both rounds: comments, order and a nested group.
seed() {
  cat >"$1" <<'YAML'
# app settings
app:
  name: demo # the name
  port: 8080
  debug: true
YAML
}

# A round: $1 writer, $2 reader, both names of the functions above.
round() {
  local writer="$1" reader="$2" dir="$work/$1-writes"
  local project="$dir/project" keys="$dir/keys" file
  mkdir -p "$project/envs" "$keys"
  file="$project/envs/app.local.yaml"
  echo "== $writer writes, $reader reads"

  # Rust never prompts and has no --yes; Dart needs it without a terminal.
  local yes=""
  [ "$writer" == dart ] && yes="--yes"
  (cd "$project" && printf 'name: demo\n' >pubspec.yaml \
    && "${writer}_pnv" init --storage "$keys" --flavor local $yes >/dev/null 2>&1)
  [ -f "$keys/local.key" ] && ok "$writer init made a key" || bad "$writer init made a key"

  seed "$file"
  : >"$project/envs/special.local.yaml"
  (cd "$project" \
    && "${writer}_pnv" set app.api-key "sk-live-abc" --file envs/app.local.yaml >/dev/null \
    && "${writer}_pnv" set db.password "hunter2" --file envs/app.local.yaml >/dev/null \
    && "${writer}_pnv" set db.url "postgres://u:p@h/d?a=1&b=2" --file envs/special.local.yaml >/dev/null \
    && "${writer}_pnv" set app.note 'quote " and $dollar and ü' --file envs/special.local.yaml >/dev/null)
  ok "$writer set secrets in two files"

  cd "$project"
  expect "$reader get app.api-key" "sk-live-abc" \
    "$("${reader}_pnv" get app.api-key --file envs/app.local.yaml)"
  expect "$reader get db.password" "hunter2" \
    "$("${reader}_pnv" get db.password --file envs/app.local.yaml)"
  expect "$reader get db.url" "postgres://u:p@h/d?a=1&b=2" \
    "$("${reader}_pnv" get db.url --file envs/special.local.yaml)"
  expect "$reader get app.note" 'quote " and $dollar and ü' \
    "$("${reader}_pnv" get app.note --file envs/special.local.yaml)"
  expect "$reader get plain app.port" "8080" \
    "$("${reader}_pnv" get app.port --file envs/app.local.yaml)"

  # show: the reader and the writer print the same plaintext file. (Only the
  # first file: for values with quotes or ":" the two tools quote the plaintext
  # differently, though both parse to the same value, which generate env checks.)
  "${reader}_pnv" show envs/app.local.yaml >"$dir/show.reader"
  "${writer}_pnv" show envs/app.local.yaml >"$dir/show.writer"
  same_file "show: $reader matches $writer" "$dir/show.writer" "$dir/show.reader"
  grep -q 'sk-live-abc' "$dir/show.reader" && ok "show decrypts" || bad "show decrypts"
  grep -q '^# app settings$' "$dir/show.reader" && grep -q 'name: demo # the name' "$dir/show.reader" \
    && ok "show keeps comments" || bad "show keeps comments"

  # generate env: both tools, byte for byte.
  "${writer}_pnv" generate env --file envs/app.local.yaml --output "$dir/out-writer" >/dev/null
  "${reader}_pnv" generate env --file envs/app.local.yaml --output "$dir/out-reader" >/dev/null
  same_file "generate env: $reader matches $writer" \
    "$dir/out-writer/app.local.env" "$dir/out-reader/app.local.env"
  # and with the key given directly rather than found from the file name
  "${reader}_pnv" generate env --file envs/app.local.yaml --key-file "$keys/local.key" \
    --output "$dir/out-reader-key" >/dev/null
  same_file "generate env --key-file: $reader matches $writer" \
    "$dir/out-writer/app.local.env" "$dir/out-reader-key/app.local.env"
  # the whole directory at once, special characters included
  "${writer}_pnv" generate env --directory envs --output "$dir/dir-writer" >/dev/null
  "${reader}_pnv" generate env --directory envs --output "$dir/dir-reader" >/dev/null
  for f in app special; do
    same_file "generate env --directory ($f): $reader matches $writer" \
      "$dir/dir-writer/$f.local.env" "$dir/dir-reader/$f.local.env"
  done

  # verify: the reader accepts what the writer wrote.
  if "${reader}_pnv" verify >"$dir/verify.out" 2>&1; then ok "$reader verify passes"; else
    bad "$reader verify passes"; sed 's/^/    /' "$dir/verify.out"
  fi

  # encrypt/decrypt tokens cross over, in both directions.
  local key token
  key="$(cat "$keys/local.key")"
  token="$("${writer}_pnv" encrypt --key "$key" "tok-1" | tail -n 1)"
  expect "$reader decrypts $writer's token" "tok-1" \
    "$("${reader}_pnv" decrypt --key "$key" "$token" | tail -n 1)"

  # The reader rejects a wrong key rather than printing garbage.
  if "${reader}_pnv" get app.api-key --file envs/app.local.yaml \
      --key "$("${reader}_pnv" create key | tail -n 1)" >/dev/null 2>&1; then
    bad "$reader refuses a wrong key"
  else ok "$reader refuses a wrong key"; fi
  cd "$root"
}

round dart rust
round rust dart

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
