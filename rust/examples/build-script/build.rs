fn main() {
    // `app.demo.yaml` names the flavor `demo`, whose key is
    // `keys/demo.key` (see `.pnvrc`), or `PNV_KEY_DEMO` when that is set.
    pnv::build::Build::new("app.demo.yaml")
        .emit()
        .unwrap_or_else(|err| panic!("{err}"));
}
