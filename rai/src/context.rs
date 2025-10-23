use std::collections::VecDeque;
use std::env;
use std::fmt::Write;
use std::fs::File;
use std::io::{BufRead, BufReader};
use std::path::{Path, PathBuf};

use anyhow::{Result, anyhow};
use chrono::Local;
use whoami::fallible;

const MAX_DIR_ENTRIES: usize = 20;
const HISTORY_LIMIT: usize = 10;

pub fn compose_prompt(user_prompt: &str) -> String {
    let mut result = String::new();
    let trimmed = user_prompt.trim();
    if trimmed.is_empty() {
        result.push_str(user_prompt);
    } else {
        result.push_str(trimmed);
    }

    result.push_str("\n\n---\n");

    let snapshot = ContextSnapshot::capture();
    result.push_str(&snapshot.render());

    result
}

struct ContextSnapshot {
    cwd: Option<PathBuf>,
    directory: Option<DirectoryListing>,
    history: Option<Vec<String>>,
    system: SystemInfo,
    warnings: Vec<String>,
}

impl ContextSnapshot {
    fn capture() -> Self {
        let mut warnings = Vec::new();

        let cwd = match env::current_dir() {
            Ok(path) => Some(path),
            Err(err) => {
                warnings.push(format!("current directory unavailable: {err}"));
                None
            }
        };

        let directory = cwd.as_ref().and_then(|path| {
            match DirectoryListing::from_path(path, MAX_DIR_ENTRIES) {
                Ok(listing) => Some(listing),
                Err(err) => {
                    warnings.push(format!("could not list directory entries: {err}"));
                    None
                }
            }
        });

        let history = match capture_history(HISTORY_LIMIT) {
            Ok(history) => history,
            Err(err) => {
                warnings.push(format!("could not read shell history: {err}"));
                None
            }
        };

        let system = SystemInfo::collect();

        Self {
            cwd,
            directory,
            history,
            system,
            warnings,
        }
    }

    fn render(&self) -> String {
        let mut out = String::new();
        writeln!(&mut out, "Context:").ok();

        writeln!(&mut out, "- Timestamp: {}", self.system.timestamp).ok();
        writeln!(
            &mut out,
            "- User: {}",
            format!("{}@{}", self.system.username, self.system.hostname)
        )
        .ok();
        writeln!(
            &mut out,
            "- OS: {} ({})",
            self.system.distro, self.system.platform
        )
        .ok();
        if let Some(shell) = &self.system.shell {
            writeln!(&mut out, "- Shell: {shell}").ok();
        }

        if let Some(cwd) = &self.cwd {
            writeln!(&mut out, "- Current directory: {}", cwd.display()).ok();
        } else {
            writeln!(&mut out, "- Current directory: unavailable").ok();
        }

        if let Some(listing) = &self.directory {
            writeln!(
                &mut out,
                "- Directory entries (total {}, showing {}):",
                listing.total,
                listing.entries.len()
            )
            .ok();
            for (idx, entry) in listing.entries.iter().enumerate() {
                writeln!(
                    &mut out,
                    "  {}. [{}] {}{}",
                    idx + 1,
                    entry.kind.label(),
                    entry.name,
                    if entry.hidden { " (hidden)" } else { "" }
                )
                .ok();
            }
            if listing.truncated {
                writeln!(&mut out, "  …").ok();
            }
        } else {
            writeln!(&mut out, "- Directory entries: unavailable").ok();
        }

        if let Some(history) = &self.history {
            writeln!(&mut out, "- Recent commands (last {}):", history.len()).ok();
            for (idx, entry) in history.iter().enumerate() {
                writeln!(&mut out, "  {}. {}", idx + 1, entry).ok();
            }
        } else {
            writeln!(&mut out, "- Recent commands: unavailable").ok();
        }

        if !self.warnings.is_empty() {
            writeln!(&mut out, "- Warnings:").ok();
            for warning in &self.warnings {
                writeln!(&mut out, "  • {}", warning).ok();
            }
        }

        out.trim_end().to_string()
    }
}

struct DirectoryListing {
    entries: Vec<DirectoryEntry>,
    total: usize,
    truncated: bool,
}

impl DirectoryListing {
    fn from_path(path: &Path, limit: usize) -> Result<Self> {
        let mut entries = Vec::new();
        let mut total = 0usize;

        for entry in path.read_dir()? {
            let entry = entry?;
            total += 1;

            let name = entry.file_name().to_string_lossy().into_owned();
            let file_type = entry.file_type().ok();
            let kind = match file_type {
                Some(ft) if ft.is_dir() => EntryKind::Directory,
                Some(ft) if ft.is_symlink() => EntryKind::Symlink,
                Some(ft) if ft.is_file() => EntryKind::File,
                _ => EntryKind::Other,
            };
            let hidden = name.starts_with('.');

            entries.push(DirectoryEntry { name, kind, hidden });
        }

        entries.sort_by(|a, b| a.name.to_lowercase().cmp(&b.name.to_lowercase()));

        let truncated = entries.len() > limit;
        let entries = entries.into_iter().take(limit).collect();

        Ok(Self {
            entries,
            total,
            truncated,
        })
    }
}

#[derive(Clone)]
struct DirectoryEntry {
    name: String,
    kind: EntryKind,
    hidden: bool,
}

#[derive(Clone, Copy)]
enum EntryKind {
    Directory,
    File,
    Symlink,
    Other,
}

impl EntryKind {
    fn label(self) -> &'static str {
        match self {
            EntryKind::Directory => "DIR",
            EntryKind::File => "FIL",
            EntryKind::Symlink => "LNK",
            EntryKind::Other => "OTH",
        }
    }
}

struct SystemInfo {
    timestamp: String,
    username: String,
    hostname: String,
    distro: String,
    platform: String,
    shell: Option<String>,
}

impl SystemInfo {
    fn collect() -> Self {
        let timestamp = Local::now().format("%Y-%m-%d %H:%M:%S %Z").to_string();
        let username = fallible::username().unwrap_or_else(|_| "unknown-user".to_string());
        let hostname = fallible::hostname().unwrap_or_else(|_| "unknown-host".to_string());
        let distro = fallible::distro().unwrap_or_else(|_| "unknown-os".to_string());
        let platform = format!("{}-{}", env::consts::OS, env::consts::ARCH);
        let shell = env::var("SHELL").ok();

        Self {
            timestamp,
            username,
            hostname,
            distro,
            platform,
            shell,
        }
    }
}

fn capture_history(limit: usize) -> Result<Option<Vec<String>>> {
    let hist_path = history_file_path().ok_or_else(|| anyhow!("history file not configured"))?;
    let file = File::open(hist_path)?;
    let mut reader = BufReader::new(file);
    let mut buffer = VecDeque::with_capacity(limit);
    let mut line = Vec::with_capacity(256);

    loop {
        line.clear();
        let bytes = reader.read_until(b'\n', &mut line)?;
        if bytes == 0 {
            break;
        }

        // Remove trailing newline if present.
        if let Some(b'\n') = line.last() {
            line.pop();
        }
        if let Some(b'\r') = line.last() {
            line.pop();
        }

        let command = parse_history_line(&line);
        if command.is_empty() {
            continue;
        }

        if buffer.len() == limit {
            buffer.pop_front();
        }
        buffer.push_back(command);
    }

    if buffer.is_empty() {
        Ok(None)
    } else {
        Ok(Some(buffer.into_iter().collect()))
    }
}

fn history_file_path() -> Option<PathBuf> {
    if let Ok(path) = env::var("HISTFILE") {
        return Some(PathBuf::from(path));
    }

    let home = env::var("HOME").ok()?;
    let mut path = PathBuf::from(home);
    path.push(".zsh_history");
    Some(path)
}

fn parse_history_line(line: &[u8]) -> String {
    let text = String::from_utf8_lossy(line);
    if let Some(idx) = text.find(';') {
        text[idx + 1..].trim().to_string()
    } else {
        text.trim().to_string()
    }
}
