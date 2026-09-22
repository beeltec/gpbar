use serde::{Deserialize, Serialize};

pub const VERSION: u32 = 9;
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
        authentication_method: AuthenticationMethod,
        identity: Option<CertificateIdentity>,
        #[serde(default)]
        certificate_only: bool,
        certificate_username: Option<String>,
        #[serde(default)]
        remember_authentication: bool,
        saved_authentication: Option<Box<SavedAuthentication>>,
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
    SubmitSignature {
        request_id: String,
        signature: Option<String>,
    },
    Cancel,
    Disconnect,
    GetSnapshot,
}

#[derive(Clone, Copy, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum AuthenticationMethod {
    Automatic,
    Saml,
    CloudIdentity,
    Password,
    Certificate,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct CertificateIdentity {
    pub certificates: Vec<String>,
    pub schemes: Vec<u16>,
}

#[derive(Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct SavedAuthentication {
    pub portal: String,
    pub username: String,
    pub computer: String,
    pub portal_cookie: Option<RetainedCookie>,
    pub gateway_cookie: Option<RetainedCookie>,
}

#[derive(Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct RetainedCookie {
    pub server: String,
    pub username: String,
    pub value: String,
    pub issued_at: u64,
    pub expires_at: u64,
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
        cloud_identity: bool,
    },
    ResourceAuthenticationRequired {
        challenge_id: &'a str,
        launch_url: &'a str,
        message: &'a str,
        expires_at_unix: u64,
    },
    ResourceAuthenticationCleared,
    ResourceAuthenticationUnavailable,
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
        login_sso_allowed: bool,
    },
    SignatureRequired {
        request_id: &'a str,
        scheme: u16,
        digest: bool,
        input: &'a str,
    },
    AuthenticationCacheChanged {
        saved_authentication: Option<&'a SavedAuthentication>,
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
