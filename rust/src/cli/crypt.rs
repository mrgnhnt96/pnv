use clap::Args;

use super::{KeyArgs, Log, Outcome};

#[derive(Debug, Args)]
pub struct CryptArgs {
    #[command(flatten)]
    key: KeyArgs,

    /// The values to work on, each printed on its own line.
    values: Vec<String>,
}

pub fn encrypt(args: &CryptArgs, log: &Log) -> Outcome {
    let key = key_for(args, "encrypt")?;
    for value in &args.values {
        log.out(pnv::encrypt(value, &key)?);
    }
    Ok(())
}

pub fn decrypt(args: &CryptArgs, log: &Log) -> Outcome {
    let key = key_for(args, "decrypt")?;
    for value in &args.values {
        log.out(pnv::decrypt(value, &key)?);
    }
    Ok(())
}

fn key_for(args: &CryptArgs, verb: &str) -> Result<pnv::Key, super::Failure> {
    if args.values.is_empty() {
        return Err(format!("No values to {verb} provided.").into());
    }
    let lookup = args.key.lookup().unwrap_or_default();
    Ok(lookup.resolve()?.key)
}
