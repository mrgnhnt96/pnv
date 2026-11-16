use std::fs;
use std::path::{Path, PathBuf};

use clap::Args;

use super::{Failure, KeyArgs, Log, Outcome, known_flavors, project};

#[derive(Debug, Args)]
pub struct GenerateEnvArgs {
    #[command(flatten)]
    key: KeyArgs,

    /// The input .yaml file to generate the .env file from.
    #[arg(
        short = 'i',
        long,
        visible_alias = "input",
        value_name = "infra.local.yaml"
    )]
    file: Option<PathBuf>,

    /// The directory of .yaml files to generate .env files from.
    #[arg(short, long, visible_alias = "dir", value_name = "public")]
    directory: Option<PathBuf>,

    /// The directory to write the .env files to.
    #[arg(short, long, value_name = "output", default_value = "outputs")]
    output: PathBuf,
}

/// The flavor `--flavor` selected and every name in its group.
struct Selected {
    name: String,
    names: Vec<String>,
}

pub fn env(args: &GenerateEnvArgs, log: &Log) -> Outcome {
    if let Some(file) = &args.file {
        if !file.is_file() {
            return Err(format!("Input file \"{}\" does not exist.", file.display()).into());
        }
        if !is_yaml(file) {
            return Err(format!("Input file \"{}\" must be a .yaml file.", file.display()).into());
        }
    }
    if let Some(dir) = args.directory.as_ref().filter(|dir| !dir.is_dir()) {
        return Err(format!("Input directory \"{}\" does not exist.", dir.display()).into());
    }
    if args.file.is_none() && args.directory.is_none() {
        return Err("Either --file or --directory must be provided.".into());
    }

    let selected = select_flavor(&args.key)?;

    let mut inputs: Vec<PathBuf> = args.file.iter().cloned().collect();
    if let Some(dir) = &args.directory {
        inputs.extend(files_in(dir, selected.as_ref(), log)?);
    }

    let output = if args.output.as_os_str().is_empty() {
        PathBuf::from("outputs")
    } else {
        args.output.clone()
    };

    // Render everything before writing anything, so one bad file leaves no
    // half-populated output directory behind.
    let shared = match args.key.lookup() {
        Some(lookup) => Some(lookup.resolve()?.key),
        None => None,
    };
    let mut rendered = Vec::with_capacity(inputs.len());
    for input in &inputs {
        let key = match &shared {
            Some(key) => key.clone(),
            None => pnv::KeyLookup::new().file(input).resolve()?.key,
        };
        let env = pnv::Env::read(input, &key)?;
        if env.is_empty() {
            log.warn(format!(
                "\u{1f440} Input file \"{}\" is empty.",
                input.display()
            ));
        }
        rendered.push((output_file(input, &output), env.to_dotenv()));
    }

    for (file, content) in rendered {
        if let Some(dir) = file.parent().filter(|dir| !dir.as_os_str().is_empty()) {
            fs::create_dir_all(dir).map_err(|err| {
                Failure::Message(format!("Could not create \"{}\": {err}", dir.display()))
            })?;
        }
        fs::write(&file, content).map_err(|err| {
            Failure::Message(format!("Could not write \"{}\": {err}", file.display()))
        })?;
        log.info(format!(
            "\u{2713} Generated .env file at {}",
            file.display()
        ));
    }

    Ok(())
}

/// Resolves `--flavor` to its group. A name the `.pnvrc` does not know is
/// an error rather than "no flavor", so a typo cannot widen the run to every
/// file. With no `.pnvrc` the flavor stands alone, its key coming from
/// `PNV_KEY_<FLAVOR>`.
fn select_flavor(key: &KeyArgs) -> Result<Option<Selected>, Failure> {
    let Some(name) = key.flavor() else {
        return Ok(None);
    };

    let names = match project()? {
        Some((_, pnvrc)) => match pnvrc.group(name) {
            Some(group) => group.names().map(str::to_owned).collect(),
            None => {
                return Err(format!(
                    "Flavor \"{name}\" is not in .pnvrc. Known flavors: {}",
                    known_flavors(&pnvrc)
                )
                .into());
            }
        },
        None => vec![name.to_owned()],
    };

    Ok(Some(Selected {
        name: name.to_owned(),
        names,
    }))
}

/// The .yaml files directly in `dir`, sorted, keeping only the selected
/// flavor's when there is one.
fn files_in(dir: &Path, selected: Option<&Selected>, log: &Log) -> Result<Vec<PathBuf>, Failure> {
    let entries = fs::read_dir(dir)
        .map_err(|err| Failure::Message(format!("Could not read \"{}\": {err}", dir.display())))?;

    let mut files: Vec<PathBuf> = entries
        .filter_map(Result::ok)
        .map(|entry| entry.path())
        .filter(|path| path.is_file())
        .collect();
    files.sort();

    let mut kept = Vec::new();
    for file in files {
        if !is_yaml(&file) {
            log.detail(format!(
                "Skipping \"{}\": not a .yaml file.",
                file.display()
            ));
            continue;
        }
        if let Some(selected) = selected {
            let flavor = pnv::flavor_from_path(&file);
            if !selected.names.contains(&flavor) {
                log.detail(format!(
                    "Skipping file \"{}\", flavor \"{flavor}\" does not match \"{}\".",
                    file.display(),
                    selected.name
                ));
                continue;
            }
        }
        kept.push(file);
    }
    Ok(kept)
}

pub(super) fn is_yaml(path: &Path) -> bool {
    path.extension()
        .is_some_and(|ext| ext == "yaml" || ext == "yml")
}

/// `<output>/<input file name without its last extension>.env`.
fn output_file(input: &Path, output: &Path) -> PathBuf {
    let stem = input
        .file_stem()
        .map(|stem| stem.to_string_lossy().into_owned())
        .unwrap_or_default();
    output.join(format!("{stem}.env"))
}
