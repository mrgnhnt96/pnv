use std::collections::BTreeSet;
use std::path::PathBuf;

use serde_json::Value;

use crate::token::encrypt_with_iv;
use crate::{Key, Pnvrc, Token, Version, decrypt, flavor_from_path};

fn load(name: &str) -> Value {
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../spec/vectors")
        .join(name);
    let text = std::fs::read_to_string(&path)
        .unwrap_or_else(|err| panic!("reading {}: {err}", path.display()));
    serde_json::from_str(&text).unwrap()
}

fn cases<'a>(file: &'a Value, field: &str) -> &'a [Value] {
    let cases = file[field].as_array().unwrap();
    assert!(!cases.is_empty(), "no {field} cases");
    cases
}

fn str_of<'a>(case: &'a Value, field: &str) -> &'a str {
    case[field]
        .as_str()
        .unwrap_or_else(|| panic!("{field} missing in {case}"))
}

fn hex_of(case: &Value, field: &str) -> Vec<u8> {
    hex::decode(str_of(case, field)).unwrap()
}

fn name_of(case: &Value) -> String {
    case["name"]
        .as_str()
        .map_or_else(|| case.to_string(), str::to_owned)
}

#[test]
fn keys() {
    let file = load("keys.json");
    for case in cases(&file, "cases") {
        let name = name_of(case);
        let result = Key::decode(str_of(case, "key"));

        if let Some(kind) = case["error"].as_str() {
            let err = result.expect_err(&name);
            assert_eq!(err.kind().as_str(), kind, "{name}");
            continue;
        }

        let key = result.unwrap_or_else(|err| panic!("{name}: {err}"));
        assert_eq!(key.bytes(), hex_of(case, "bytes"), "{name}");
        assert_eq!(key.aes_key().as_slice(), hex_of(case, "aes_key"), "{name}");
        assert_eq!(key.id().as_slice(), hex_of(case, "key_id"), "{name}");
    }
}

#[test]
fn token_decrypt() {
    let file = load("tokens.json");
    for case in cases(&file, "decrypt") {
        let name = name_of(case);
        let key = Key::decode(str_of(case, "key")).unwrap();
        let token = str_of(case, "token");
        let result = decrypt(token, &key);

        if let Some(kind) = case["error"].as_str() {
            let err = result.expect_err(&name);
            assert_eq!(err.kind().as_str(), kind, "{name}: {err}");
            continue;
        }

        assert_eq!(
            result.unwrap_or_else(|err| panic!("{name}: {err}")),
            str_of(case, "plaintext"),
            "{name}"
        );

        let parsed = Token::parse(token).unwrap();
        let version = match parsed.version() {
            Version::V0 => 0,
            Version::V1 => 1,
        };
        assert_eq!(Some(version), case["version"].as_u64(), "{name}");
        assert_eq!(parsed.iv().as_slice(), hex_of(case, "iv"), "{name}");
        match case["key_id"].as_str() {
            Some(id) => assert_eq!(parsed.key_id().map(hex::encode).as_deref(), Some(id)),
            None => assert_eq!(parsed.key_id(), None, "{name}"),
        }
    }
}

#[test]
fn token_encrypt() {
    let file = load("tokens.json");
    for case in cases(&file, "encrypt") {
        let key = Key::decode(str_of(case, "key")).unwrap();
        let iv: [u8; 12] = hex_of(case, "iv").try_into().unwrap();
        let token = encrypt_with_iv(str_of(case, "plaintext"), &key, iv);

        assert_eq!(token, str_of(case, "token"), "{case}");
    }
}

#[test]
fn flavor_from_path_cases() {
    let file = load("flavor_from_path.json");
    for case in cases(&file, "cases") {
        let path = str_of(case, "path");
        assert_eq!(flavor_from_path(path), str_of(case, "flavor"), "{path}");
    }
}

fn parse_pnvrc(value: &Value) -> crate::Result<Option<Pnvrc>> {
    Pnvrc::parse(&value.to_string())
}

#[test]
fn pnvrc_parse() {
    let file = load("pnvrc.json");
    for case in cases(&file, "parse") {
        let name = name_of(case);
        let result = parse_pnvrc(&case["pnvrc"]);

        if let Some(kind) = case["error"].as_str() {
            let err = result.expect_err(&name);
            assert_eq!(err.kind().as_str(), kind, "{name}: {err}");
            continue;
        }

        assert_eq!(case["valid"], Value::Bool(true), "{name}");
        let pnvrc = result
            .unwrap_or_else(|err| panic!("{name}: {err}"))
            .unwrap_or_else(|| panic!("{name}: read as no .pnvrc"));
        assert_eq!(pnvrc.storage(), str_of(&case["pnvrc"], "storage"), "{name}");

        let reparsed = Pnvrc::parse(&pnvrc.to_json()).unwrap().unwrap();
        assert_eq!(reparsed, pnvrc, "{name}: round trip");
    }
}

#[test]
fn pnvrc_groups() {
    let file = load("pnvrc.json");
    let groups = &file["groups"];
    let pnvrc = parse_pnvrc(&groups["pnvrc"]).unwrap().unwrap();

    for case in cases(groups, "cases") {
        let name = str_of(case, "name");
        let actual: Option<BTreeSet<&str>> =
            pnvrc.group(name).map(|flavor| flavor.names().collect());
        let expected: Option<BTreeSet<&str>> = case["group"]
            .as_array()
            .map(|names| names.iter().map(|n| n.as_str().unwrap()).collect());
        assert_eq!(actual, expected, "{name}");
    }
}

#[test]
fn plaintext_detector_values() {
    let file = load("plaintext_detector.json");
    for case in cases(&file, "values") {
        let key_path = str_of(case, "key_path");
        let value = str_of(case, "value");
        let found = crate::suspect_plaintext(key_path, value, case["comment"].as_str());

        let flagged = case["flagged"].as_bool().unwrap();
        assert_eq!(found.is_some(), flagged, "{case}");
        if flagged {
            assert_eq!(found.unwrap().reason, str_of(case, "reason"), "{case}");
        }
    }
}

#[test]
fn plaintext_detector_files() {
    let file = load("plaintext_detector.json");
    for case in cases(&file, "files") {
        let name = name_of(case);
        let leaves = crate::yaml::leaves(str_of(case, "yaml")).unwrap();

        let flagged: Vec<String> = leaves
            .iter()
            .filter(|leaf| leaf.is_string && !crate::is_secret(&leaf.text))
            .filter(|leaf| {
                crate::suspect_plaintext(&leaf.path.join("."), &leaf.text, leaf.comment.as_deref())
                    .is_some()
            })
            .map(|leaf| leaf.path.join("."))
            .collect();

        let expected: Vec<&str> = case["flagged"]
            .as_array()
            .unwrap()
            .iter()
            .map(|v| v.as_str().unwrap())
            .collect();
        assert_eq!(flagged, expected, "{name}");
    }
}
