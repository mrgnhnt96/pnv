use std::fmt::Display;

/// How much a command prints.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum Level {
    /// Errors and the command's own output only (`--quiet`).
    Quiet,
    /// Progress too: what was created, written or found.
    Info,
    /// Every step (`--loud`).
    Loud,
}

/// Where a command's messages go.
///
/// The command's own output, such as an encrypted value, goes to stdout at
/// every level so it can be piped. Errors go to stderr at every level too.
#[derive(Debug, Clone, Copy)]
pub struct Log {
    level: Level,
}

impl Log {
    pub fn new(level: Level) -> Self {
        Self { level }
    }

    /// What the command was asked for, such as a key or a decrypted value.
    pub fn out(&self, message: impl Display) {
        println!("{message}");
    }

    pub fn info(&self, message: impl Display) {
        if self.level >= Level::Info {
            println!("{message}");
        }
    }

    pub fn detail(&self, message: impl Display) {
        if self.level >= Level::Loud {
            println!("{message}");
        }
    }

    pub fn warn(&self, message: impl Display) {
        if self.level >= Level::Info {
            eprintln!("{message}");
        }
    }

    pub fn err(&self, message: impl Display) {
        eprintln!("{message}");
    }
}
