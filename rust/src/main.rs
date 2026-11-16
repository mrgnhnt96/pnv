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
    };

    match result {
        Ok(()) => ExitCode::SUCCESS,
        Err(err) => {
            eprintln!("{err}");
            ExitCode::FAILURE
        }
    }
}
