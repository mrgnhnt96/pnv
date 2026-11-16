mod cli;

use std::process::ExitCode;

use clap::Parser;
use clap::error::ErrorKind;

use cli::{Cli, Failure, Log};

fn main() -> ExitCode {
    let cli = match Cli::try_parse() {
        Ok(cli) => cli,
        Err(err) => {
            // Asking for help is not a mistake; a bad flag is. Either way the
            // exit code is 0 or 1, as with the Dart tool, never clap's 2.
            let asked = matches!(
                err.kind(),
                ErrorKind::DisplayHelp
                    | ErrorKind::DisplayVersion
                    | ErrorKind::DisplayHelpOnMissingArgumentOrSubcommand
            );
            if asked {
                // clap sends help shown for a missing subcommand to stderr.
                print!("{err}");
                return ExitCode::SUCCESS;
            }
            let _ = err.print();
            return ExitCode::FAILURE;
        }
    };

    let log = Log::new(cli.level());

    match cli::run(cli.command, &log) {
        Ok(()) => ExitCode::SUCCESS,
        Err(Failure::Reported) => ExitCode::FAILURE,
        Err(failure) => {
            log.err(format!("\u{274c} {failure}"));
            ExitCode::FAILURE
        }
    }
}
