use std::path::PathBuf;

use clap::Args;

use super::{Failure, Log, Outcome, require_project};

#[derive(Debug, Args)]
pub struct VerifyArgs {
    /// Where to look for .yaml files. Defaults to the .pnvrc directory.
    #[arg(short, long, alias = "dir", value_name = "envs")]
    directory: Option<PathBuf>,
}

pub fn run(args: &VerifyArgs, log: &Log) -> Outcome {
    let (path, pnvrc) = require_project()?;

    let project = path.parent().map(PathBuf::from).unwrap_or_default();
    let root = args.directory.clone().unwrap_or_else(|| project.clone());

    let report = pnv::verify(&root, &project, &pnvrc)?;

    if report.files == 0 {
        log.warn("No .yaml files found to check.");
    }

    if report.is_clean() {
        log.out(format!(
            "\u{2713} {} file(s), {} secret(s). Nothing here looks unsafe to publish.",
            report.files, report.secrets
        ));
        return Ok(());
    }

    log.err(format!("\u{274c} {} problem(s):", report.problems.len()));
    for problem in &report.problems {
        log.err(format!("   \u{2022} {problem}"));
    }
    Err(Failure::Reported)
}
