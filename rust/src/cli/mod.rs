//! The `pnv` command: flags, output and the commands themselves.
//!
//! Every command takes all of its input as flags and never prompts, so it
//! runs the same on a laptop and on a build server.

mod crypt;
mod edit;
mod flavor;
mod generate;
mod init;
mod log;
mod verify;

use std::fmt;
use std::path::PathBuf;

use clap::{Args, Parser, Subcommand};

pub use log::{Level, Log};

/// Encrypt and decrypt secrets.
#[derive(Debug, Parser)]
#[command(name = "pnv", version, arg_required_else_help = true)]
pub struct Cli {
    /// Print only errors and what the command was asked for.
    #[arg(long, global = true)]
    pub quiet: bool,

    /// Print extra detail about each step. Wins over --quiet.
    #[arg(long, global = true)]
    pub loud: bool,

    #[command(subcommand)]
    pub command: Command,
}

impl Cli {
    /// How much to print.
    pub fn level(&self) -> Level {
        if self.loud {
            Level::Loud
        } else if self.quiet {
            Level::Quiet
        } else {
            Level::Info
        }
    }
}

#[derive(Debug, Subcommand)]
pub enum Command {
    /// Initialize a new environment.
    Init(init::InitArgs),
    /// Create new entities for your environment.
    #[command(subcommand)]
    Create(Create),
    /// Delete commands.
    #[command(subcommand)]
    Delete(Delete),
    /// Encrypt a secret.
    #[command(visible_aliases = ["enc", "e", "encode"])]
    Encrypt(crypt::CryptArgs),
    /// Decrypt a secret.
    #[command(visible_aliases = ["dec", "d", "decode"])]
    Decrypt(crypt::CryptArgs),
    /// Encrypt a value into a .yaml file, in place.
    Set(edit::SetArgs),
    /// Read one value out of a .yaml file, decrypted.
    Get(edit::GetArgs),
    /// Print a .yaml file with its secrets decrypted.
    Show(edit::ShowArgs),
    /// Generates files for your environment.
    #[command(subcommand)]
    Generate(Generate),
    /// Check that the YAML files in the project are safe to commit publicly.
    Verify(verify::VerifyArgs),
}

#[derive(Debug, Subcommand)]
pub enum Create {
    /// Create a new encryption key.
    Key,
    /// Create a new flavor.
    Flavor(flavor::CreateFlavorArgs),
}

#[derive(Debug, Subcommand)]
pub enum Delete {
    /// Delete a flavor.
    Flavor(flavor::DeleteFlavorArgs),
}

#[derive(Debug, Subcommand)]
pub enum Generate {
    /// Generate a .env file from a .yaml file.
    Env(generate::GenerateEnvArgs),
}

/// The options shared by every command that needs a key.
#[derive(Debug, Args)]
pub struct KeyArgs {
    /// The secret key to use.
    #[arg(short, long)]
    pub key: Option<String>,

    /// The file containing the secret key to use.
    #[arg(short = 'f', long)]
    pub key_file: Option<PathBuf>,

    /// The flavor whose key to use.
    #[arg(long)]
    pub flavor: Option<String>,
}

impl KeyArgs {
    /// The lookup these options describe, or `None` when none was given.
    fn lookup(&self) -> Option<pnv::KeyLookup> {
        let mut lookup = pnv::KeyLookup::new();
        let mut any = false;
        if let Some(key) = self.key.as_deref().filter(|key| !key.trim().is_empty()) {
            lookup = lookup.key(key);
            any = true;
        }
        if let Some(path) = &self.key_file {
            lookup = lookup.key_file(path);
            any = true;
        }
        if let Some(flavor) = self.flavor() {
            lookup = lookup.flavor(flavor);
            any = true;
        }
        any.then_some(lookup)
    }

    /// The `--flavor` name, trimmed, when one was given.
    fn flavor(&self) -> Option<&str> {
        self.flavor
            .as_deref()
            .map(str::trim)
            .filter(|flavor| !flavor.is_empty())
    }
}

/// Why a command stopped.
#[derive(Debug)]
pub enum Failure {
    /// A message still to be printed.
    Message(String),
    /// The command already printed why.
    Reported,
}

impl fmt::Display for Failure {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Message(message) => f.write_str(message),
            Self::Reported => Ok(()),
        }
    }
}

impl From<pnv::Error> for Failure {
    fn from(err: pnv::Error) -> Self {
        Self::Message(err.to_string())
    }
}

impl From<String> for Failure {
    fn from(message: String) -> Self {
        Self::Message(message)
    }
}

impl From<&str> for Failure {
    fn from(message: &str) -> Self {
        Self::Message(message.to_owned())
    }
}

/// What a command returns.
pub type Outcome = Result<(), Failure>;

/// Runs a parsed command.
pub fn run(command: Command, log: &Log) -> Outcome {
    match command {
        Command::Init(args) => init::run(&args, log),
        Command::Create(Create::Key) => {
            log.out(pnv::create_key()?);
            Ok(())
        }
        Command::Create(Create::Flavor(args)) => flavor::create(&args, log),
        Command::Delete(Delete::Flavor(args)) => flavor::delete(&args, log),
        Command::Encrypt(args) => crypt::encrypt(&args, log),
        Command::Decrypt(args) => crypt::decrypt(&args, log),
        Command::Set(args) => edit::set(&args, log),
        Command::Get(args) => edit::get(&args, log),
        Command::Show(args) => edit::show(&args, log),
        Command::Generate(Generate::Env(args)) => generate::env(&args, log),
        Command::Verify(args) => verify::run(&args, log),
    }
}

fn current_dir() -> Result<PathBuf, Failure> {
    std::env::current_dir()
        .map_err(|err| Failure::Message(format!("Could not read the current directory: {err}")))
}

/// The nearest `.pnvrc` above the current directory, and where it is.
fn project() -> Result<Option<(PathBuf, pnv::Pnvrc)>, Failure> {
    Ok(pnv::Pnvrc::discover(current_dir()?)?)
}

/// As [`project`], failing when there is none.
fn require_project() -> Result<(PathBuf, pnv::Pnvrc), Failure> {
    project()?.ok_or_else(|| "No .pnvrc found. Run `pnv init` first.".into())
}

/// The flavor names in a `.pnvrc`, for an error message.
fn known_flavors(pnvrc: &pnv::Pnvrc) -> String {
    let names: Vec<_> = pnvrc.flavors().iter().map(pnv::Flavor::name).collect();
    if names.is_empty() {
        "none".to_owned()
    } else {
        names.join(", ")
    }
}
