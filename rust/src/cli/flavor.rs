use clap::Args;

use super::{Log, Outcome, known_flavors, require_project};

#[derive(Debug, Args)]
pub struct CreateFlavorArgs {
    /// The flavor to create.
    #[arg(short, long)]
    name: Option<String>,

    /// Replace the key of a flavor that already exists.
    #[arg(short, long)]
    force: bool,
}

#[derive(Debug, Args)]
pub struct DeleteFlavorArgs {
    /// The flavor to delete. Repeatable, or separate names with commas.
    #[arg(short, long, value_delimiter = ',')]
    name: Vec<String>,

    /// Delete without asking. Required, since a deleted key cannot be
    /// recovered.
    #[arg(short, long)]
    force: bool,
}

pub fn create(args: &CreateFlavorArgs, log: &Log) -> Outcome {
    let name = args
        .name
        .as_deref()
        .map(str::trim)
        .filter(|name| !name.is_empty())
        .ok_or("Name the flavor to create with --name.")?;

    if !pnv::is_valid_flavor_name(name) {
        return Err(pnv::Error::InvalidFlavorName {
            name: name.to_owned(),
        }
        .into());
    }

    let (path, mut pnvrc) = require_project()?;
    let key_file = pnvrc.key_file(name)?;

    // A key file with no .pnvrc entry is still a key something may be
    // encrypted with, so it is protected the same way.
    if (pnvrc.flavor(name).is_some() || key_file.exists()) && !args.force {
        return Err(format!(
            "Flavor \"{name}\" already exists. Pass --force to replace its key; anything \
             encrypted with the old key will no longer decrypt."
        )
        .into());
    }

    pnvrc.add_flavor(name)?;
    pnv::write_key_file(&key_file, &pnv::create_key()?)?;
    pnvrc.save(&path)?;

    log.info(format!("\u{2713} Created flavor {name}"));
    log.detail(format!("  key file: {}", key_file.display()));
    Ok(())
}

pub fn delete(args: &DeleteFlavorArgs, log: &Log) -> Outcome {
    let mut names: Vec<&str> = Vec::new();
    for name in args.name.iter().map(|name| name.trim()) {
        if !name.is_empty() && !names.contains(&name) {
            names.push(name);
        }
    }

    if names.is_empty() {
        return Err("Name the flavors to delete with --name.".into());
    }

    let (path, mut pnvrc) = require_project()?;

    let missing: Vec<&str> = names
        .iter()
        .copied()
        .filter(|name| pnvrc.flavor(name).is_none())
        .collect();
    if !missing.is_empty() {
        return Err(format!(
            "No such flavor: {}. Known flavors: {}",
            missing.join(", "),
            known_flavors(&pnvrc)
        )
        .into());
    }

    if !args.force {
        return Err(format!(
            "Deleting a flavor deletes its key, and anything encrypted with it can no longer \
             be decrypted. Pass --force to delete {}.",
            names.join(", ")
        )
        .into());
    }

    for name in names {
        let key_file = pnvrc.key_file(name)?;
        match std::fs::remove_file(&key_file) {
            Ok(()) => log.detail(format!("Removed {}", key_file.display())),
            Err(err) if err.kind() == std::io::ErrorKind::NotFound => {
                log.detail(format!("{} has no key file", name));
            }
            Err(err) => {
                return Err(format!("Could not delete \"{}\": {err}", key_file.display()).into());
            }
        }

        pnvrc.remove_flavor(name);
        pnvrc.save(&path)?;
        log.info(format!("\u{2713} Deleted flavor {name}"));
    }

    Ok(())
}
