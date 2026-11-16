use std::path::PathBuf;
use std::process::ExitCode;

use clap::{Parser, Subcommand};

/// Encrypted secrets in YAML files that are safe to commit.
#[derive(Debug, Parser)]
#[command(name = "pnv", version)]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

#[derive(Debug, Subcommand)]
enum Command {
    /// Create new entities for your environment.
    #[command(subcommand)]
    Create(Create),
    /// Check that the YAML files in the project are safe to commit publicly.
    Verify {
        /// Where to look for .yaml files. Defaults to the .pnvrc directory.
        #[arg(short, long, alias = "dir", value_name = "envs")]
        directory: Option<PathBuf>,
    },
}

#[derive(Debug, Subcommand)]
enum Create {
    /// Create a new encryption key.
    Key,
}

fn main() -> ExitCode {
    let cli = Cli::parse();

    let result = match cli.command {
        Command::Create(Create::Key) => pnv::create_key().map(|key| println!("{key}")),
        Command::Verify { directory } => return verify(directory),
    };

    match result {
        Ok(()) => ExitCode::SUCCESS,
        Err(err) => {
            eprintln!("{err}");
            ExitCode::FAILURE
        }
    }
}

fn verify(directory: Option<PathBuf>) -> ExitCode {
    let found = std::env::current_dir()
        .map_err(|err| err.to_string())
        .and_then(|cwd| pnv::Pnvrc::discover(cwd).map_err(|err| err.to_string()));

    let (path, pnvrc) = match found {
        Ok(Some(found)) => found,
        Ok(None) => {
            eprintln!("\u{274c} No .pnvrc found. Run `pnv init` first.");
            return ExitCode::FAILURE;
        }
        Err(err) => {
            eprintln!("\u{274c} {err}");
            return ExitCode::FAILURE;
        }
    };

    let project = path.parent().map(PathBuf::from).unwrap_or_default();
    let root = directory.unwrap_or_else(|| project.clone());

    let report = match pnv::verify(&root, &project, &pnvrc) {
        Ok(report) => report,
        Err(err) => {
            eprintln!("\u{274c} {err}");
            return ExitCode::FAILURE;
        }
    };

    if report.files == 0 {
        eprintln!("No .yaml files found to check.");
    }

    if report.is_clean() {
        println!(
            "\u{2713} {} file(s), {} secret(s). Nothing here looks unsafe to publish.",
            report.files, report.secrets
        );
        return ExitCode::SUCCESS;
    }

    eprintln!("\u{274c} {} problem(s):", report.problems.len());
    for problem in &report.problems {
        eprintln!("   \u{2022} {problem}");
    }
    ExitCode::FAILURE
}
