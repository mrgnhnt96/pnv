# pnv build script example

`build.rs` decrypts `app.demo.yaml` and hands each value to the compiler, and
`src/main.rs` reads them with `env!`. Nothing is decrypted when the program
runs.

```sh
cargo run
```

The key is `keys/demo.key`, found through `.pnvrc` because the file name
`app.demo.yaml` names the flavor `demo`. It is committed only so this example
builds: never commit a real key. On a build server, set `PNV_KEY_DEMO`
instead.
