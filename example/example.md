# pnv

A runnable version of this example lives next to it: [`local.yaml`](local.yaml) is the input,
[`generate_env.sh`](generate_env.sh) is the command, and [`outputs/local.env`](outputs/local.env) is
the real generated result.

Encrypted secrets and plain configuration share one committed YAML file. Only values prefixed with
`SECRET;` are decrypted; everything else is copied through.

```yaml
# local.yaml
base-url: http://localhost:3000

app:
  secret: SECRET;<encoded_data>
  run-time:
    not-secret: not
    key: SECRET;<encoded_data>
```

```bash
pnv generate env --key <key_value> --file local.yaml --output outputs
```

Nested keys are flattened with `_` and uppercased, `-` becomes `_`, and string values are quoted.
The output file is named after the input file, so `local.yaml` produces `local.env` (and
`app.local.yaml` would produce `app.local.env`).

```dotenv
# outputs/local.env
BASE_URL="http://localhost:3000"
APP_SECRET="app-secret"
APP_RUN_TIME_NOT_SECRET="not"
APP_RUN_TIME_KEY="run-time-key"
```

Instead of `--key`, pass `--flavor <name>` to look the key up from `.pnvrc`, or omit key arguments
entirely with `--file` — pnv then infers the flavor from the file name.
