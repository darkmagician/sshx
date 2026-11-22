//! Background command executed once after a shared session is created.

use std::process::{ExitStatus, Stdio};

use anyhow::{Context, Result};
use tokio::process::Command;
use tokio::task::JoinHandle;
use tracing::error;

/// Environment variable containing the full shareable session URL.
pub const URL_ENV_VAR: &str = "SSHX_URL";

/// Spawn the user-provided callback command in the background.
///
/// The command runs through the platform shell (`sh -c` on Unix and
/// `cmd /S /C` on Windows), with the session URL exposed as `SSHX_URL`.
/// Returns `None` for an empty or whitespace-only command. Failures are logged
/// and never affect the client's exit status.
pub fn spawn(command: &str, url: &str) -> Option<JoinHandle<()>> {
    if command.trim().is_empty() {
        return None;
    }

    let command = command.to_owned();
    let url = url.to_owned();
    Some(tokio::spawn(async move {
        match run(&command, &url).await {
            Ok(status) if status.success() => (),
            Ok(status) => error!(%status, "callback command exited with non-zero status"),
            Err(err) => error!("callback command failed: {err:#}"),
        }
    }))
}

/// Run the callback to completion and return its exit status.
async fn run(command: &str, url: &str) -> Result<ExitStatus> {
    let mut cmd = shell_command(command);

    // The parent environment is inherited, so variables like `PATH` keep
    // working; only the session URL is added on top.
    cmd.env(URL_ENV_VAR, url)
        // Do not steal the terminal's stdin, and keep stdout quiet so that
        // `--quiet` mode still prints nothing but the URL. Inherit stderr so
        // that errors from the shell itself remain visible.
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::inherit())
        // Aborting the task drops the child, terminating the shell.
        .kill_on_drop(true);

    cmd.status()
        .await
        .context("failed to spawn callback command")
}

#[cfg(unix)]
fn shell_command(command: &str) -> Command {
    let mut cmd = Command::new("sh");
    cmd.arg("-c").arg(command);
    cmd
}

#[cfg(windows)]
fn shell_command(command: &str) -> Command {
    let mut cmd = Command::new("cmd");
    cmd.args(["/S", "/C"]);
    // `raw_arg` bypasses Rust's `CommandLineToArgvW`-style escaping, which
    // `cmd.exe` does not understand. With `/S`, cmd strips exactly one outer
    // quote pair and executes the remainder verbatim, preserving inner quotes,
    // pipes, `&`, and `%VAR%` expansion.
    cmd.raw_arg(format!("\"{command}\""));
    cmd
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn blank_command_is_ignored() {
        assert!(spawn("", "http://localhost:8051/s/abc#secret").is_none());
        assert!(spawn("   ", "http://localhost:8051/s/abc#secret").is_none());
    }

    #[tokio::test]
    async fn passes_sshx_url_env() {
        let url = "http://localhost:8051/s/abc#secret";

        #[cfg(unix)]
        let command = r#"test "$SSHX_URL" = "http://localhost:8051/s/abc#secret""#;
        #[cfg(windows)]
        let command =
            r#"if "%SSHX_URL%"=="http://localhost:8051/s/abc#secret" (exit 0) else (exit 1)"#;

        let status = run(command, url).await.unwrap();
        assert!(status.success());
    }

    #[cfg(unix)]
    #[test]
    fn unix_uses_sh_dash_c() {
        let cmd = shell_command("echo hi");
        let std_cmd = cmd.as_std();

        assert_eq!(std_cmd.get_program().to_string_lossy(), "sh");
        let args: Vec<_> = std_cmd
            .get_args()
            .map(|arg| arg.to_string_lossy().into_owned())
            .collect();
        assert_eq!(args, ["-c", "echo hi"]);
    }

    #[cfg(unix)]
    #[test]
    fn url_is_not_passed_as_argument() {
        let cmd = shell_command("echo hi");
        assert!(!cmd
            .as_std()
            .get_args()
            .any(|arg| arg.to_string_lossy().contains('#')));
    }
}
