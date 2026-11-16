use std::path::Path;

/// The prefix of the environment variable that may hold a flavor's key.
pub const KEY_ENV_PREFIX: &str = "PNV_KEY_";

/// The flavor a file's name implies, following the format spec.
///
/// Only the last path component matters. `local.yaml` gives `local`, and
/// `app.local.yaml` gives `local`, taken from the second-to-last extension.
/// The result may be empty (`.env`) or not a real flavor (`app.local.json`
/// gives `local.json`); it is up to the caller to look it up.
///
/// ```
/// assert_eq!(pnv::flavor_from_path("envs/app.production.yaml"), "production");
/// assert_eq!(pnv::flavor_from_path("local.yml"), "local");
/// ```
pub fn flavor_from_path(path: impl AsRef<Path>) -> String {
    let name = file_name(&path.as_ref().to_string_lossy()).to_owned();

    let (stem, _) = split_extension(&name, 1);
    if !stem.contains('.') {
        return stem.to_owned();
    }

    let (_, extensions) = split_extension(&name, 2);
    let rest = extensions.strip_suffix(".env").unwrap_or(extensions);
    let rest = rest
        .strip_suffix(".yaml")
        .or_else(|| rest.strip_suffix(".yml"))
        .unwrap_or(rest);
    rest.strip_prefix('.').unwrap_or(rest).to_owned()
}

/// Whether `name` may be used for a new flavor: one or more letters, digits,
/// `_` or `-`.
pub fn is_valid_flavor_name(name: &str) -> bool {
    !name.is_empty()
        && name
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-')
}

/// The environment variable checked for a flavor's key before its key file:
/// `PNV_KEY_` and the flavor, uppercased, with `-` turned into `_`.
///
/// ```
/// assert_eq!(pnv::key_env_var("staging-eu"), "PNV_KEY_STAGING_EU");
/// ```
pub fn key_env_var(flavor: &str) -> String {
    let mut name = String::from(KEY_ENV_PREFIX);
    name.extend(flavor.chars().map(|c| match c {
        '-' => '_',
        c => c.to_ascii_uppercase(),
    }));
    name
}

fn is_separator(c: char) -> bool {
    c == '/' || (cfg!(windows) && c == '\\')
}

fn file_name(path: &str) -> &str {
    path.trim_end_matches(is_separator)
        .rsplit(is_separator)
        .next()
        .unwrap_or_default()
}

/// Splits `name` before its `level`-th last `.`, or before its first `.` when
/// it has fewer. A `.` that starts the name never starts an extension, so
/// `.env` has none.
fn split_extension(name: &str, level: usize) -> (&str, &str) {
    let dot = name
        .rmatch_indices('.')
        .take(level)
        .last()
        .map_or(0, |(i, _)| i);

    if dot == 0 {
        (name, "")
    } else {
        name.split_at(dot)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn env_var_names() {
        assert_eq!(key_env_var("local"), "PNV_KEY_LOCAL");
        assert_eq!(key_env_var("my_app-Prod"), "PNV_KEY_MY_APP_PROD");
    }

    #[test]
    fn flavor_names() {
        for good in ["local", "prod-eu", "a_b", "X9"] {
            assert!(is_valid_flavor_name(good), "{good}");
        }
        for bad in ["", "a b", "a.b", "a/b", "é"] {
            assert!(!is_valid_flavor_name(bad), "{bad}");
        }
    }

    #[test]
    fn trailing_separators_are_ignored() {
        assert_eq!(flavor_from_path("dir/app.local.yaml/"), "local");
    }
}
