use serde::{Deserialize, Serialize};

pub const VERSION: u32 = 2;
pub const MAX_FRAME_BYTES: usize = 256 * 1024;

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct CommandEnvelope {
    pub protocol_version: u32,
    pub session_id: String,
    pub command_id: String,
    pub command: Command,
}

#[derive(Deserialize)]
#[serde(tag = "type", rename_all = "snake_case", deny_unknown_fields)]
pub enum Command {
    Start {
        portal: String,
        reconnect: bool,
    },
    SubmitCallback {
        challenge_id: String,
        callback: String,
    },
    SubmitOtp {
        challenge_id: String,
        otp: String,
    },
    SubmitCredentials {
        challenge_id: String,
        username: String,
        password: String,
    },
    Cancel,
    Disconnect,
    GetSnapshot,
}

#[derive(Serialize)]
pub struct EventEnvelope<'a> {
    pub protocol_version: u32,
    pub session_id: &'a str,
    pub sequence: u64,
    pub event: Event<'a>,
}

#[derive(Serialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum Event<'a> {
    Ready {
        openconnect_version: Option<String>,
    },
    PhaseChanged {
        phase: &'a str,
        attempt: u32,
    },
    AuthenticationRequired {
        challenge_id: &'a str,
        launch_url: &'a str,
    },
    AuthenticationCompleted {
        challenge_id: &'a str,
    },
    OtpRequired {
        challenge_id: &'a str,
        message: &'a str,
        server: &'a str,
    },
    CredentialsRequired {
        challenge_id: &'a str,
        server: &'a str,
        message: &'a str,
        username_label: &'a str,
        password_label: &'a str,
    },
    Snapshot {
        snapshot: &'a AppSnapshot,
    },
    Failure {
        code: &'a str,
        message: &'a str,
        retryable: bool,
    },
    Stopped {
        cleanup: &'a str,
    },
}

#[derive(Clone, Default, Serialize, PartialEq, Eq)]
pub struct AppSnapshot {
    pub phase: String,
    pub portal: String,
    pub gateway: Option<String>,
    pub account: Option<String>,
    pub interface: Option<String>,
    pub ipv4: Option<String>,
    pub started_at_unix: Option<u64>,
    pub attempt: u32,
}

pub fn valid_id(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 64
        && value
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'-')
}
