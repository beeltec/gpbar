use std::collections::HashSet;
use std::os::fd::{FromRawFd, OwnedFd};
use std::sync::{Arc, RwLock};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use anyhow::{bail, Context, Result};
use gp_auth::{
    saml_common::{parse_cas_callback, parse_globalprotect_callback},
    GpBar,
};
use gp_ipc::app::{self, AppSnapshot, Command, CommandEnvelope, Event, EventEnvelope};
use gp_proto::{AuthCookie, ClientOs, Credential, GatewayLoginResult, GpParams, PreloginResponse};
use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader};
use tokio::net::unix::pipe::{Receiver, Sender};
use tokio::sync::{mpsc, watch, Mutex};

mod cookies;
mod resource_mfa;
mod signing;

struct AuthenticationOptions {
    method: app::AuthenticationMethod,
    identity: Option<Arc<gp_proto::identity::ClientIdentity>>,
    certificate_only: bool,
    certificate_username: Option<String>,
    remember_authentication: bool,
    saved_authentication: Mutex<Option<app::SavedAuthentication>>,
}

impl AuthenticationOptions {
    async fn save(
        &self,
        saved: Option<app::SavedAuthentication>,
        output: &SharedOutput,
    ) -> Result<()> {
        let saved = saved.filter(|saved| cookies::valid(saved, &saved.portal, &saved.computer));
        output
            .lock()
            .await
            .send(Event::AuthenticationCacheChanged {
                saved_authentication: saved.as_ref(),
            })
            .await?;
        *self.saved_authentication.lock().await = saved;
        Ok(())
    }

    fn client(&self, params: GpParams) -> Result<GpBar> {
        Ok(match &self.identity {
            Some(identity) => GpBar::new_for_app_with_identity(params, identity.clone())?,
            None => GpBar::new_for_app(params)?,
        })
    }
}

struct Output {
    pipe: Sender,
    sequence: u64,
    session_id: String,
    snapshot: AppSnapshot,
    failure_reported: bool,
}

type SharedOutput = Arc<Mutex<Output>>;

impl Output {
    async fn send(&mut self, event: Event<'_>) -> Result<()> {
        if matches!(event, Event::Failure { .. }) {
            self.failure_reported = true;
        }
        self.sequence = self.sequence.checked_add(1).context("sequence exhausted")?;
        let mut bytes = serde_json::to_vec(&EventEnvelope {
            protocol_version: app::VERSION,
            session_id: &self.session_id,
            sequence: self.sequence,
            event,
        })?;
        if bytes.len() >= app::MAX_FRAME_BYTES {
            bail!("event too large");
        }
        bytes.push(b'\n');
        tokio::time::timeout(Duration::from_secs(5), self.pipe.write_all(&bytes)).await??;
        Ok(())
    }

    async fn phase(&mut self, phase: &str, attempt: u32) -> Result<()> {
        self.snapshot.phase = phase.into();
        self.snapshot.attempt = attempt;
        self.send(Event::PhaseChanged { phase, attempt }).await
    }

    async fn snapshot(&mut self) -> Result<()> {
        let snapshot = self.snapshot.clone();
        self.send(Event::Snapshot {
            snapshot: &snapshot,
        })
        .await
    }
}

struct Answer {
    challenge_id: String,
    value: String,
    otp: bool,
    username: Option<String>,
}

struct Authentication {
    gateway: String,
    cookie: AuthCookie,
    resource_mfa: Option<gp_proto::resource_mfa::ResourceMfaPolicy>,
}

pub async fn hip_input() -> Result<()> {
    use std::io::Read;
    super::ensure_macos_connect_privileges()?;
    let mut input = std::io::stdin().lock();
    let mut fields = Vec::with_capacity(5);
    let mut total = 0usize;
    for _ in 0..5 {
        let mut size = [0u8; 4];
        input.read_exact(&mut size)?;
        let length = u32::from_be_bytes(size) as usize;
        total = total.checked_add(length).context("HIP input too large")?;
        if total > app::MAX_FRAME_BYTES {
            bail!("HIP input too large");
        }
        let mut bytes = vec![0u8; length];
        input.read_exact(&mut bytes)?;
        fields.push(String::from_utf8(bytes)?);
    }
    if input.read(&mut [0u8; 1])? != 0 {
        bail!("unexpected HIP data");
    }
    drop(input);
    let mut fields = fields.into_iter();
    let cookie = fields.next().context("missing cookie")?;
    let address = fields.next().context("missing address")?;
    let _address6 = fields.next();
    let md5 = fields.next().context("missing HIP hash")?;
    let os = fields.next().context("missing OS")?;
    if os != "Mac" && os != "mac" {
        bail!("unexpected HIP OS");
    }
    observed_hip(cookie, address, md5).await
}

async fn fact(program: &str, arguments: &[&str]) -> Result<String> {
    let mut process = tokio::process::Command::new(program);
    process
        .args(arguments)
        .env_clear()
        .env("PATH", "/usr/bin:/bin:/usr/sbin:/sbin")
        .env("LC_ALL", "C")
        .kill_on_drop(true);
    let output = tokio::time::timeout(Duration::from_secs(3), process.output()).await??;
    if !output.status.success() || output.stdout.len() > 16384 {
        bail!("device fact unavailable");
    }
    Ok(String::from_utf8(output.stdout)?.trim().to_owned())
}

async fn observed_hip(cookie: String, address: String, md5: String) -> Result<()> {
    let username = serde_urlencoded::from_str::<Vec<(String, String)>>(&cookie)?
        .into_iter()
        .find_map(|(key, value)| (key == "user").then_some(value))
        .context("missing user")?;
    let version = fact("/usr/bin/sw_vers", &["-productVersion"]).await?;
    let mut host = gp_hip::HostInfo::detect();
    host.host_id.clear();
    let mut profile = gp_hip::HostProfile {
        hip_os: gp_hip::HipOs::Mac,
        os: format!("macOS {version}"),
        os_vendor: "Apple Inc.".into(),
        domain: String::new(),
        antivirus: Vec::new(),
        firewall: Vec::new(),
        disk_encryption: Vec::new(),
        disk_backup: Vec::new(),
    };
    if let Ok(value) = fact(
        "/usr/libexec/ApplicationFirewall/socketfilterfw",
        &["--getglobalstate"],
    )
    .await
    {
        let enabled = if value.contains("State = 1") {
            Some("yes")
        } else if value.contains("State = 0") {
            Some("no")
        } else {
            None
        };
        if let Some(enabled) = enabled {
            profile.firewall.push(gp_hip::FirewallProduct {
                vendor: "Apple Inc.".into(),
                name: "Application Firewall".into(),
                version: version.clone(),
                status: enabled.into(),
            });
        }
    }
    if let Ok(value) = fact("/usr/bin/fdesetup", &["status"]).await {
        let status = if value == "FileVault is On." {
            Some("encrypted")
        } else if value == "FileVault is Off." {
            Some("not-encrypted")
        } else {
            None
        };
        if let Some(status) = status {
            profile.disk_encryption.push(gp_hip::DiskEncryptionProduct {
                vendor: "Apple Inc.".into(),
                name: "FileVault".into(),
                version,
                drive: "/".into(),
                status: status.into(),
            });
        }
    }
    let report = gp_hip::build_report(
        md5,
        username,
        address,
        host,
        profile,
        super::gp_hip_generate_time(),
    );
    let mut output = tokio::io::stdout();
    output
        .write_all(report.to_observed_macos_xml().as_bytes())
        .await?;
    output.flush().await?;
    Ok(())
}

// Only the helper's inherited pipe descriptors are accepted in application mode.
fn inherited_fd(descriptor: i32) -> Result<OwnedFd> {
    let duplicate = unsafe { libc::fcntl(descriptor, libc::F_DUPFD_CLOEXEC, 3) };
    if duplicate < 0 {
        return Err(std::io::Error::last_os_error().into());
    }
    Ok(unsafe { OwnedFd::from_raw_fd(duplicate) })
}

pub async fn run() -> Result<()> {
    let input = Receiver::from_owned_fd(inherited_fd(libc::STDIN_FILENO)?)?;
    let pipe = Sender::from_owned_fd(inherited_fd(libc::STDOUT_FILENO)?)?;
    let output = Arc::new(Mutex::new(Output {
        pipe,
        sequence: 0,
        failure_reported: false,
        session_id: String::new(),
        snapshot: AppSnapshot::default(),
    }));
    output
        .lock()
        .await
        .send(Event::Ready {
            openconnect_version: gp_tunnel::openconnect_version(),
        })
        .await?;
    let mut input = BufReader::new(input);
    let first = tokio::time::timeout(Duration::from_secs(15), read_command(&mut input)).await??;
    let Command::Start {
        portal,
        reconnect,
        authentication_method,
        identity,
        certificate_only,
        certificate_username,
        remember_authentication,
        saved_authentication,
    } = first.command
    else {
        bail!("start required");
    };
    let portal = normalize_portal(&portal)?;
    if saved_authentication.as_ref().is_some_and(|saved| {
        !remember_authentication || !cookies::valid(saved, &portal, &saved.computer)
    }) {
        bail!("invalid saved authentication");
    }
    let saved_authentication = saved_authentication
        .map(|saved| *saved)
        .filter(|saved| saved.computer == GpParams::new(ClientOs::Mac).computer);
    if (authentication_method == app::AuthenticationMethod::Certificate) != identity.is_some()
        || (certificate_only && identity.is_none())
        || certificate_username
            .as_ref()
            .is_some_and(|name| name.len() > 1024 || name.contains(char::is_control))
    {
        bail!("invalid certificate settings");
    }
    if gp_tunnel::openconnect_version().as_deref() != Some("v9.21-gpbar2") {
        bail!("patched tunnel support required");
    }
    super::ensure_macos_connect_privileges()?;
    {
        let mut out = output.lock().await;
        out.session_id = first.session_id.clone();
        out.snapshot.portal = portal.clone();
        out.phase("preparing", 0).await?;
    }
    let (stop, _) = watch::channel(false);
    let (answers, mut answer_rx) = mpsc::channel(4);
    let (signature_answers, signature_rx) = mpsc::channel(1);
    let (identity, signer_task) = match identity {
        Some(identity) => {
            let (identity, task) =
                signing::start(identity, output.clone(), stop.subscribe(), signature_rx)?;
            (Some(identity), Some(task))
        }
        None => (None, None),
    };
    let options = AuthenticationOptions {
        method: authentication_method,
        identity,
        certificate_only,
        certificate_username,
        remember_authentication,
        saved_authentication: Mutex::new(saved_authentication),
    };
    let reader_output = output.clone();
    let reader_stop = stop.clone();
    let reader = tokio::spawn(async move {
        let mut seen = HashSet::from([first.command_id]);
        loop {
            let result = read_command(&mut input).await;
            let command = match result {
                Ok(value) => value,
                Err(_) => {
                    let _ = reader_stop.send(true);
                    return;
                }
            };
            if command.session_id != first.session_id
                || seen.len() >= 4096
                || !seen.insert(command.command_id)
            {
                let _ = reader_stop.send(true);
                return;
            }
            let response = match command.command {
                Command::Cancel | Command::Disconnect => {
                    let _ = reader_stop.send(true);
                    None
                }
                Command::GetSnapshot => {
                    if reader_output.lock().await.snapshot().await.is_err() {
                        let _ = reader_stop.send(true);
                        return;
                    }
                    None
                }
                Command::SubmitCallback {
                    challenge_id,
                    callback,
                } => Some(Answer {
                    challenge_id,
                    value: callback,
                    otp: false,
                    username: None,
                }),
                Command::SubmitOtp { challenge_id, otp } => Some(Answer {
                    challenge_id,
                    value: otp,
                    otp: true,
                    username: None,
                }),
                Command::SubmitCredentials {
                    challenge_id,
                    username,
                    password,
                } => Some(Answer {
                    challenge_id,
                    value: password,
                    otp: false,
                    username: Some(username),
                }),
                Command::SubmitSignature {
                    request_id,
                    signature,
                } => {
                    if !app::valid_id(&request_id)
                        || signature_answers
                            .try_send(signing::Answer {
                                request_id,
                                signature,
                            })
                            .is_err()
                    {
                        let _ = reader_stop.send(true);
                        return;
                    }
                    None
                }
                Command::Start { .. } => {
                    let _ = reader_stop.send(true);
                    return;
                }
            };
            if let Some(response) = response {
                if !app::valid_id(&response.challenge_id) || answers.try_send(response).is_err() {
                    let _ = reader_stop.send(true);
                    return;
                }
            }
        }
    });
    let result = run_session(
        &portal,
        reconnect,
        &output,
        &mut answer_rx,
        stop.clone(),
        &options,
    )
    .await;
    let _ = stop.send(true);
    if let Some(task) = signer_task {
        let _ = task.await;
    }
    reader.abort();
    let _ = reader.await;
    let mut out = output.lock().await;
    if result.is_err() && !out.failure_reported {
        out.send(Event::Failure {
            code: "session_failed", message: "The VPN session could not finish. Check your address, sign-in, and network access.", retryable: true,
        }).await?;
    }
    out.phase("disconnecting", 0).await?;
    let cleanup = if network_worker("--network-recover").await.is_ok() {
        "restored"
    } else {
        "unverified"
    };
    out.send(Event::Stopped { cleanup }).await?;
    Ok(())
}

async fn read_command(input: &mut BufReader<Receiver>) -> Result<CommandEnvelope> {
    let mut bytes = Vec::new();
    loop {
        let chunk = input.fill_buf().await?;
        if chunk.is_empty() {
            bail!("command pipe closed");
        }
        let newline = chunk.iter().position(|b| *b == b'\n');
        let length = newline.map_or(chunk.len(), |n| n + 1);
        if bytes.len() + length > app::MAX_FRAME_BYTES {
            bail!("command too large");
        }
        bytes.extend_from_slice(&chunk[..length]);
        input.consume(length);
        if newline.is_some() {
            break;
        }
    }
    let message: CommandEnvelope = serde_json::from_slice(&bytes)?;
    if message.protocol_version != app::VERSION
        || !app::valid_id(&message.session_id)
        || !app::valid_id(&message.command_id)
    {
        bail!("invalid protocol envelope");
    }
    Ok(message)
}

fn normalize_portal(value: &str) -> Result<String> {
    if value.len() > 2048
        || value.contains(char::is_whitespace)
        || value.contains('%')
        || value.contains('\\')
    {
        bail!("invalid portal");
    }
    let url = url::Url::parse(value)?;
    if url.scheme() != "https"
        || url.host_str().is_none()
        || !url.username().is_empty()
        || url.password().is_some()
        || url.query().is_some()
        || url.fragment().is_some()
        || url.path() != "/"
        || url.port() == Some(0)
    {
        bail!("invalid portal");
    }
    Ok(url.origin().ascii_serialization())
}

fn challenge_id() -> Result<String> {
    let mut bytes = [0u8; 24];
    getrandom::fill(&mut bytes).map_err(|_| anyhow::anyhow!("random source unavailable"))?;
    Ok(bytes.iter().map(|byte| format!("{byte:02x}")).collect())
}

async fn answer(answers: &mut mpsc::Receiver<Answer>, id: &str, otp: bool) -> Result<String> {
    let response = tokio::time::timeout(Duration::from_secs(300), answers.recv())
        .await?
        .context("answer channel closed")?;
    if response.challenge_id != id
        || response.otp != otp
        || response.username.is_some()
        || response.value.is_empty()
    {
        bail!("invalid challenge response");
    }
    if otp && (response.value.len() > 1024 || response.value.contains(char::is_control)) {
        bail!("invalid verification code");
    }
    Ok(response.value)
}

async fn authenticate(
    portal: &str,
    output: &SharedOutput,
    answers: &mut mpsc::Receiver<Answer>,
    options: &AuthenticationOptions,
) -> Result<Authentication> {
    match authenticate_once(portal, output, answers, options).await {
        Err(error) if error.is::<cookies::Expired>() => {
            options.save(None, output).await?;
            authenticate_once(portal, output, answers, options).await
        }
        result => result,
    }
}

async fn authenticate_once(
    portal: &str,
    output: &SharedOutput,
    answers: &mut mpsc::Receiver<Answer>,
    options: &AuthenticationOptions,
) -> Result<Authentication> {
    output.lock().await.phase("preparing", 0).await?;
    let params = GpParams::new(ClientOs::Mac);
    let client = options.client(params.clone())?;
    let mut prelogin = client.prelogin(portal).await?;
    validate_portal_method(&prelogin, options.method, output).await?;
    let mut saved = options.saved_authentication.lock().await.clone();
    let mut history = saved.clone();
    if let Some(saved) = &mut saved {
        saved.portal_cookie = saved.portal_cookie.take().filter(cookies::current);
        saved.gateway_cookie = saved.gateway_cookie.take().filter(cookies::current);
    }
    let cached_portal = saved
        .as_ref()
        .and_then(|saved| saved.portal_cookie.as_ref().map(cookies::credential));
    let mut allow_cached_fallback = cached_portal.is_some();
    let (mut credential, mut completed_challenge) = match cached_portal {
        Some(credential) => (credential, None),
        None => {
            let (credential, id) =
                request_credential(portal, &prelogin, output, answers, options).await?;
            (credential, Some(id))
        }
    };
    let mut portal_params = params.clone();
    let mut challenge_count = 0;
    let configuration = loop {
        cookies::check_credential(&credential, history.as_ref())?;
        let client = options.client(portal_params.clone())?;
        let result = client.portal_login_for_app(portal, &credential).await;
        drop(client);
        portal_params.otp = None;
        match result {
            Ok(gp_auth::client::PortalLoginResult::Success(config)) => break config,
            Ok(gp_auth::client::PortalLoginResult::Challenge { message, input_str }) => {
                if challenge_count == 3 {
                    bail!("too many authentication challenges");
                }
                challenge_count += 1;
                allow_cached_fallback = false;
                if let Credential::Password { password, .. } = &mut credential {
                    password.clear();
                }
                portal_params.input_str = Some(input_str);
                let (otp, challenge) = request_otp(portal, &message, output, answers).await?;
                portal_params.otp = Some(otp);
                completed_challenge = Some(challenge);
            }
            Err(_) if allow_cached_fallback => {
                options.save(None, output).await?;
                saved = None;
                allow_cached_fallback = false;
                prelogin = options.client(params.clone())?.prelogin(portal).await?;
                validate_portal_method(&prelogin, options.method, output).await?;
                let (fresh, id) =
                    request_credential(portal, &prelogin, output, answers, options).await?;
                credential = fresh;
                completed_challenge = Some(id);
            }
            Err(error) => return Err(error.into()),
        }
    };
    drop(credential);
    drop(portal_params);
    if let Some(id) = completed_challenge {
        output
            .lock()
            .await
            .send(Event::AuthenticationCompleted { challenge_id: &id })
            .await?;
    }
    if configuration.gateways.len() > 128 {
        bail!("too many gateways");
    }
    for gateway in &configuration.gateways {
        normalize_gateway(&gateway.address)?;
    }
    let gateway = normalize_gateway(
        &super::select_gateway(&configuration, prelogin.region(), None)
            .await?
            .gateway
            .address,
    )?;
    let lifetime = configuration
        .cookie_lifetime_seconds
        .filter(|_| options.remember_authentication);
    if let (Some(history), Some(lifetime)) = (&mut history, lifetime) {
        for cookie in [
            history.portal_cookie.as_mut(),
            history.gateway_cookie.as_mut(),
        ]
        .into_iter()
        .flatten()
        {
            cookie.expires_at = cookie
                .expires_at
                .min(cookie.issued_at.saturating_add(lifetime));
        }
    }
    let mut updated = lifetime.map(|lifetime| {
        let previous = saved
            .as_ref()
            .filter(|saved| saved.username == configuration.username);
        app::SavedAuthentication {
            portal: portal.into(),
            username: configuration.username.clone(),
            computer: params.computer.clone(),
            portal_cookie: cookies::retain(
                portal,
                &configuration.username,
                &configuration.user_auth_cookie,
                lifetime,
                cookies::previous(history.as_ref(), &configuration.user_auth_cookie),
            ),
            gateway_cookie: previous
                .and_then(|saved| saved.gateway_cookie.as_ref())
                .filter(|cookie| cookie.server == gateway)
                .and_then(|cookie| {
                    cookies::retain(
                        &gateway,
                        &cookie.username,
                        &cookie.value,
                        lifetime,
                        Some(cookie),
                    )
                }),
        }
    });
    options.save(updated.clone(), output).await?;
    let mut gateway_credential = configuration.to_gateway_credential();
    let has_portal_cookie = [
        &configuration.user_auth_cookie,
        &configuration.prelogon_user_auth_cookie,
    ]
    .into_iter()
    .any(|cookie| !cookie.is_empty() && cookie != "empty" && cookie != "(null)");
    let mut fresh_portal_credential = None;
    let cached_gateway = updated
        .as_ref()
        .and_then(|saved| saved.gateway_cookie.as_ref().map(cookies::credential));
    if let Some(credential) = cached_gateway {
        let previous = std::mem::replace(&mut gateway_credential, credential);
        if has_portal_cookie {
            fresh_portal_credential = Some(previous);
        }
    }
    let mut params = params;
    params.is_gateway = true;
    let mut gateway_challenge = None;
    let needs_gateway_login = updated
        .as_ref()
        .is_none_or(|saved| saved.gateway_cookie.is_none())
        && (configuration.user_auth_cookie.is_empty() || configuration.user_auth_cookie == "empty")
        && (configuration.prelogon_user_auth_cookie.is_empty()
            || configuration.prelogon_user_auth_cookie == "empty");
    let resource_mfa = configuration.resource_mfa.clone();
    drop(configuration);
    if needs_gateway_login {
        let gateway_client = options.client(params.clone())?;
        let prelogin = gateway_client.prelogin(&gateway).await?;
        let (credential, id) =
            request_credential(&gateway, &prelogin, output, answers, options).await?;
        gateway_credential = credential;
        gateway_challenge = Some(id);
    }
    let mut challenge_count = 0;
    let mut allow_cookie_fallback = gateway_challenge.is_none();
    let gateway_history = updated.clone();
    loop {
        cookies::check_credential(&gateway_credential, history.as_ref())?;
        cookies::check_credential(&gateway_credential, gateway_history.as_ref())?;
        let gateway_client = options.client(params.clone())?;
        let result = gateway_client
            .gateway_login(&gateway, &gateway_credential)
            .await;
        drop(gateway_client);
        params.otp = None;
        match result {
            Ok(GatewayLoginResult::Success(cookie)) => {
                if let (Some(saved), Some(lifetime)) = (&mut updated, lifetime) {
                    if let Some(value) = &cookie.user_auth_cookie {
                        let previous = [
                            cookies::previous(Some(saved), value),
                            cookies::previous(history.as_ref(), value),
                        ]
                        .into_iter()
                        .flatten()
                        .min_by_key(|cookie| cookie.expires_at);
                        saved.gateway_cookie =
                            cookies::retain(&gateway, &cookie.username, value, lifetime, previous);
                    }
                }
                options.save(updated, output).await?;
                drop(gateway_credential);
                if let Some(id) = gateway_challenge {
                    output
                        .lock()
                        .await
                        .send(Event::AuthenticationCompleted { challenge_id: &id })
                        .await?;
                }
                return Ok(Authentication {
                    gateway,
                    cookie,
                    resource_mfa,
                });
            }
            Ok(GatewayLoginResult::MfaChallenge { input_str, message }) => {
                fresh_portal_credential = None;
                if let Some(saved) = &mut updated {
                    saved.gateway_cookie = None;
                }
                options.save(updated.clone(), output).await?;
                if challenge_count == 3 {
                    bail!("verification code not accepted");
                }
                challenge_count += 1;
                allow_cookie_fallback = false;
                if let Credential::Password { password, .. } = &mut gateway_credential {
                    password.clear();
                }
                params.input_str = Some(input_str);
                let (otp, challenge) = request_otp(&gateway, &message, output, answers).await?;
                params.otp = Some(otp);
                gateway_challenge = Some(challenge);
            }
            Err(_) if allow_cookie_fallback => {
                if let Some(saved) = &mut updated {
                    saved.gateway_cookie = None;
                }
                options.save(updated.clone(), output).await?;
                if let Some(credential) = fresh_portal_credential.take() {
                    gateway_credential = credential;
                    continue;
                }
                allow_cookie_fallback = false;
                let gateway_client = options.client(params.clone())?;
                let prelogin = gateway_client.prelogin(&gateway).await?;
                let (credential, id) =
                    request_credential(&gateway, &prelogin, output, answers, options).await?;
                gateway_credential = credential;
                gateway_challenge = Some(id);
            }
            Err(error) => return Err(error.into()),
        }
    }
}

fn prompt(value: &str, fallback: &str) -> String {
    let value: String = value
        .chars()
        .filter(|c| {
            !c.is_control() && !matches!(*c, '\u{202a}'..='\u{202e}' | '\u{2066}'..='\u{2069}')
        })
        .take(512)
        .collect();
    if value.trim().is_empty() {
        fallback.into()
    } else {
        value
    }
}

async fn request_otp(
    server: &str,
    message: &str,
    output: &SharedOutput,
    answers: &mut mpsc::Receiver<Answer>,
) -> Result<(String, String)> {
    let id = challenge_id()?;
    let message = prompt(message, "Enter your verification code.");
    let mut out = output.lock().await;
    out.phase("authenticating", 0).await?;
    out.send(Event::OtpRequired {
        challenge_id: &id,
        message: &message,
        server,
    })
    .await?;
    drop(out);
    Ok((answer(answers, &id, true).await?, id))
}

async fn validate_portal_method(
    prelogin: &PreloginResponse,
    method: app::AuthenticationMethod,
    output: &SharedOutput,
) -> Result<()> {
    let is_cas = matches!(prelogin, PreloginResponse::Saml(saml) if saml.is_cas);
    let message = match (method, prelogin) {
        (app::AuthenticationMethod::CloudIdentity, _) if !is_cas => {
            "The portal did not offer Cloud Identity Engine. Select Automatic in Edit Connection."
        }
        (app::AuthenticationMethod::Saml | app::AuthenticationMethod::Password, _) if is_cas => {
            "The portal requires Cloud Identity Engine. Select Automatic or Cloud Identity Engine in Edit Connection."
        }
        (app::AuthenticationMethod::Saml, PreloginResponse::Standard(_)) => {
            "The portal did not offer SAML. Select Automatic or Username and password in Edit Connection."
        }
        (app::AuthenticationMethod::Password, PreloginResponse::Saml(_)) => {
            "The portal requires SAML. Select Automatic or SAML in Edit Connection."
        }
        _ => return Ok(()),
    };
    output
        .lock()
        .await
        .send(Event::Failure {
            code: "authentication_method_mismatch",
            message,
            retryable: false,
        })
        .await?;
    bail!("authentication method mismatch")
}

async fn request_credential(
    server: &str,
    prelogin: &PreloginResponse,
    output: &SharedOutput,
    answers: &mut mpsc::Receiver<Answer>,
    options: &AuthenticationOptions,
) -> Result<(Credential, String)> {
    let id = challenge_id()?;
    output.lock().await.phase("authenticating", 0).await?;
    let saml = match prelogin {
        PreloginResponse::Standard(standard) => {
            if options.certificate_only {
                let username = standard
                    .certificate_username
                    .clone()
                    .or_else(|| options.certificate_username.clone())
                    .unwrap_or_default();
                if username.len() > 1024 || username.contains(char::is_control) {
                    bail!("invalid certificate username");
                }
                return Ok((
                    Credential::Password {
                        username,
                        password: String::new(),
                    },
                    id,
                ));
            }
            let message = prompt(&standard.auth_message, "Enter your VPN credentials.");
            let username_label = prompt(&standard.label_username, "Username");
            let password_label = prompt(&standard.label_password, "Password");
            output
                .lock()
                .await
                .send(Event::CredentialsRequired {
                    challenge_id: &id,
                    server,
                    message: &message,
                    username_label: &username_label,
                    password_label: &password_label,
                })
                .await?;
            let response = tokio::time::timeout(Duration::from_secs(300), answers.recv())
                .await?
                .context("answer channel closed")?;
            let username = response.username.context("username required")?;
            if response.challenge_id != id
                || response.otp
                || username.is_empty()
                || username.len() > 1024
                || username.contains(char::is_control)
                || response.value.is_empty()
                || response.value.len() > 4096
            {
                bail!("invalid credential response");
            }
            return Ok((
                Credential::Password {
                    username,
                    password: response.value,
                },
                id,
            ));
        }
        PreloginResponse::Saml(saml) => saml,
    };
    let body = gp_auth::saml_paste::build_app_launch_body(saml)?;
    let listener = tokio::net::TcpListener::bind((std::net::Ipv4Addr::LOCALHOST, 0)).await?;
    let authority = listener.local_addr()?.to_string();
    let path = format!("/{}", challenge_id()?);
    let url = format!("http://{authority}{path}");
    let raw = {
        let mut out = output.lock().await;
        out.phase("authenticating", 0).await?;
        out.send(Event::AuthenticationRequired {
            challenge_id: &id,
            launch_url: &url,
            cloud_identity: saml.is_cas,
        })
        .await?;
        drop(out);
        tokio::select! {
            result = answer(answers, &id, false) => result?,
            result = serve_launch(listener, &authority, &path, &body) => { result?; bail!("launch server stopped"); }
        }
    };
    let credential = if saml.is_cas {
        parse_cas_callback(&raw).context("invalid CAS callback")?
    } else {
        parse_globalprotect_callback(&raw)
            .context("invalid callback")?
            .into_credential()
    };
    Ok((credential, id))
}

fn normalize_gateway(value: &str) -> Result<String> {
    let origin = if value.contains("://") {
        value.to_owned()
    } else {
        format!("https://{value}")
    };
    normalize_portal(&origin)
}

async fn serve_launch(
    listener: tokio::net::TcpListener,
    authority: &str,
    path: &str,
    body: &[u8],
) -> Result<()> {
    loop {
        let (mut socket, peer) = listener.accept().await?;
        if !peer.ip().is_loopback() {
            continue;
        }
        let request = tokio::time::timeout(Duration::from_secs(3), async {
            let mut bytes = Vec::new();
            let mut buffer = [0u8; 1024];
            loop {
                let count = socket.read(&mut buffer).await?;
                if count == 0 || bytes.len() + count > 8192 {
                    return Err(std::io::Error::other("invalid request"));
                }
                bytes.extend_from_slice(&buffer[..count]);
                if bytes.windows(4).any(|v| v == b"\r\n\r\n") {
                    break;
                }
            }
            Ok(bytes)
        })
        .await;
        let Ok(Ok(request)) = request else {
            continue;
        };
        let Ok(request) = std::str::from_utf8(&request) else {
            continue;
        };
        let mut lines = request.split("\r\n");
        let valid_path = lines.next() == Some(format!("GET {path} HTTP/1.1").as_str());
        let hosts: Vec<_> = lines
            .filter_map(|line| line.split_once(':'))
            .filter(|(key, _)| key.eq_ignore_ascii_case("host"))
            .collect();
        let valid_host = hosts.len() == 1 && hosts[0].1.trim() == authority;
        if !valid_path || !valid_host {
            let _ = tokio::time::timeout(
                Duration::from_secs(3),
                socket.write_all(
                    b"HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
                ),
            )
            .await;
            continue;
        }
        let header = format!("HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: {}\r\nCache-Control: no-store\r\nReferrer-Policy: no-referrer\r\nContent-Security-Policy: default-src https: 'unsafe-inline'; form-action https:; base-uri 'none'; frame-ancestors 'none'\r\nConnection: close\r\n\r\n", body.len());
        let _ = tokio::time::timeout(Duration::from_secs(3), async {
            socket.write_all(header.as_bytes()).await?;
            socket.write_all(body).await
        })
        .await;
    }
}

async fn network_worker(mode: &str) -> Result<()> {
    let helper = std::env::current_exe()?
        .parent()
        .context("missing executable directory")?
        .join("GPBarHelper");
    let mut process = tokio::process::Command::new(helper);
    process
        .arg(mode)
        .env_clear()
        .env("PATH", "/usr/bin:/bin:/usr/sbin:/sbin")
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .kill_on_drop(true);
    process.stdout(std::process::Stdio::piped());
    let result = tokio::time::timeout(Duration::from_secs(30), process.output()).await??;
    if !result.status.success() {
        let detail = std::str::from_utf8(&result.stdout).unwrap_or("");
        let allowed = [
            "initialization",
            "configuration",
            "interface_preflight",
            "route_ownership",
            "dns_install",
            "interface",
            "route_add",
            "route_delete",
            "route_lookup",
        ];
        let kinds = [
            "invalidSession",
            "invalidConfiguration",
            "conflict",
            "command",
            "verification",
            "journal",
            "unknown",
        ];
        if let Some((stage, kind)) = detail.split_once(':') {
            if allowed.contains(&stage) && kinds.contains(&kind) {
                bail!("Network setup failed at {stage} ({kind}).");
            }
        }
        bail!("Network setup could not be verified.");
    }
    Ok(())
}

async fn run_session(
    portal: &str,
    reconnect: bool,
    output: &SharedOutput,
    answers: &mut mpsc::Receiver<Answer>,
    stop_sender: watch::Sender<bool>,
    options: &AuthenticationOptions,
) -> Result<()> {
    let mut stop = stop_sender.subscribe();
    let mut authentication = tokio::select! {
        result = authenticate(portal, output, answers, options) => result?,
        _ = stop.wait_for(|v| *v) => return Ok(()),
    };
    let script = std::env::current_exe()?
        .parent()
        .context("missing executable directory")?
        .join("../Resources/vpnc-script")
        .canonicalize()?;
    if !script.is_file() {
        bail!("missing route script");
    }
    let script_path = script.to_str().context("invalid script path")?;
    let script = format!("'{}'", script_path.replace('\'', "'\"'\"'"));
    let started = SystemTime::now().duration_since(UNIX_EPOCH)?.as_secs();
    let session_id = output.lock().await.session_id.clone();
    let counters = super::metrics::MetricsCounters::new();
    let mut attempt = 0;
    let mut reauth_count = 0;
    loop {
        if *stop.borrow() {
            return Ok(());
        }
        {
            let mut out = output.lock().await;
            out.snapshot.gateway = Some(authentication.gateway.clone());
            out.snapshot.account = Some(authentication.cookie.username.clone());
            out.snapshot.started_at_unix = Some(started);
            out.snapshot.interface = None;
            out.snapshot.ipv4 = None;
            out.phase("connecting", attempt).await?;
        }
        let base = Arc::new(RwLock::new(gp_ipc::StateSnapshotBase {
            instance: session_id.clone(),
            portal: portal.into(),
            gateway: authentication.gateway.clone(),
            user: authentication.cookie.username.clone(),
            reported_os: "mac".into(),
            routes: Vec::new(),
            started_at_unix: started,
            tun_ifname: None,
            local_ipv4: None,
            state: gp_ipc::SessionState::Connecting,
        }));
        let cookie = super::build_openconnect_cookie(&authentication.cookie);
        let outcome = {
            let task = super::run_tunnel_attempt(super::TunnelAttemptArgs {
                gateway_host: &authentication.gateway,
                cookie: &cookie,
                os: "mac-intel",
                script: Some(&script),
                routes: Vec::new(),
                reconnect_enabled: reconnect,
                enable_esp: true,
                base: &base,
                disconnect_rx: stop.clone(),
                counters: &counters,
                attempt_num: attempt,
                route_conflict: gp_route::RouteConflictPolicy::Fail,
                hip_mode: super::HipMode::Auto,
                hip_script: None,
                split_dns_zones: Vec::new(),
                client_cert: options
                    .identity
                    .as_ref()
                    .map(|_| "gpbar-keychain:session".into()),
                client_key: options
                    .identity
                    .as_ref()
                    .map(|_| "gpbar-keychain:session".into()),
                gateway_ip_pin: None,
                instance: session_id.clone(),
            });
            tokio::pin!(task);
            let mut interval = tokio::time::interval(Duration::from_millis(250));
            let mut resource_tasks = tokio::task::JoinSet::new();
            let (resource_sender, mut resource_events) = mpsc::channel::<resource_mfa::Notice>(2);
            let outcome = loop {
                tokio::select! {
                    biased;
                    outcome = &mut task => break outcome,
                    Some(notice) = resource_events.recv() => {
                        if !*stop.borrow() {
                            let result = output.lock().await.send(notice.event()).await;
                            if result.is_err() {
                                let _ = stop_sender.send(true);
                                let _ = (&mut task).await;
                                resource_tasks.shutdown().await;
                                bail!("event stream unavailable");
                            }
                        }
                    },
                    _ = interval.tick() => {
                        let state = match base.read() {
                            Ok(state) => Some(state.clone()),
                            Err(_) => None,
                        };
                        let Some(state) = state else {
                            let _ = stop_sender.send(true);
                            let _ = (&mut task).await;
                            resource_tasks.shutdown().await;
                            bail!("snapshot unavailable");
                        };
                        let needs_verification = state.state == gp_ipc::SessionState::Connected
                            && output.lock().await.snapshot.phase != "connected";
                        if needs_verification {
                            let verification = tokio::select! {
                                biased;
                                outcome = &mut task => break outcome,
                                _ = stop.wait_for(|value| *value) => None,
                                result = network_worker("--network-verify") => Some(result),
                            };
                            let Some(verification) = verification else {
                                break (&mut task).await;
                            };
                            if let Err(error) = verification {
                                let _ = stop_sender.send(true);
                                let _ = (&mut task).await;
                                output.lock().await.send(Event::Failure { code: "network_configuration", message: &error.to_string(), retryable: false }).await?;
                                bail!("network setup could not be verified");
                            }
                            if *stop.borrow() { break (&mut task).await; }
                            let mut out = output.lock().await;
                            out.snapshot.interface = state.tun_ifname.clone();
                            out.snapshot.ipv4 = state.local_ipv4.clone();
                            let result = async {
                                out.failure_reported = false;
                                out.phase("connected", attempt).await?;
                                out.snapshot().await
                            }.await;
                            if result.is_err() {
                                drop(out);
                                let _ = stop_sender.send(true);
                                let _ = (&mut task).await;
                                bail!("event stream unavailable");
                            }
                            drop(out);
                            if let (Some(policy), Some(interface), Some(address)) =
                                (authentication.resource_mfa.clone(), state.tun_ifname, state.local_ipv4) {
                                resource_tasks.spawn(resource_mfa::run(policy, interface, address, base.clone(), resource_sender.clone(), stop.clone()));
                            }
                        }
                    }
                }
            };
            resource_tasks.shutdown().await;
            output
                .lock()
                .await
                .send(Event::ResourceAuthenticationCleared)
                .await?;
            outcome
        };
        if *stop.borrow() {
            return Ok(());
        }
        if let super::AttemptOutcome::Err(ref error) = outcome {
            let (code, message) = tunnel_failure(error);
            output
                .lock()
                .await
                .send(Event::Failure {
                    code: &code,
                    message: &message,
                    retryable: reconnect && attempt < 9,
                })
                .await?;
        }
        match outcome {
            super::AttemptOutcome::Ok | super::AttemptOutcome::UserCancel => return Ok(()),
            super::AttemptOutcome::AuthExpired(_) if reconnect && reauth_count < 2 => {
                reauth_count += 1;
                authentication = tokio::select! {
                    result = authenticate(portal, output, answers, options) => result?,
                    _ = stop.wait_for(|v| *v) => return Ok(()),
                };
            }
            super::AttemptOutcome::Err(_) if reconnect && attempt < 9 => {
                attempt += 1;
                output.lock().await.phase("reconnecting", attempt).await?;
                tokio::select! {
                    _ = tokio::time::sleep(super::reconnect_backoff(attempt)) => {},
                    _ = stop.wait_for(|v| *v) => return Ok(()),
                }
            }
            _ => bail!("tunnel failed"),
        }
    }
}

fn tunnel_failure(error: &anyhow::Error) -> (String, String) {
    for cause in error.chain() {
        if let Some(gp_tunnel::TunnelError::Ffi { operation, code }) =
            cause.downcast_ref::<gp_tunnel::TunnelError>()
        {
            return (
                format!("tunnel_{operation}_{code}"),
                format!("VPN setup failed at {operation} (code {code})."),
            );
        }
    }
    let stage = error
        .chain()
        .find_map(|cause| match cause.to_string().as_str() {
            "creating openconnect session" => Some("runtime"),
            "set_protocol_gp" => Some("protocol"),
            "set_url" => Some("gateway_address"),
            "set_os_spoof" => Some("client_platform"),
            "set_cookie" => Some("session_credential"),
            "make_cstp_connection" => Some("gateway_connection"),
            "setup_tun_device" => Some("network_configuration"),
            _ => None,
        })
        .unwrap_or("tunnel");
    (
        format!("tunnel_{stage}"),
        format!("VPN setup failed during {stage}."),
    )
}

#[cfg(test)]
mod cie_tests;
