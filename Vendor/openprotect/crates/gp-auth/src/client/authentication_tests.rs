use super::*;
use base64::Engine;
use gp_proto::identity::{ClientIdentity, IdentityError, IdentitySigner};
use std::io::{Read, Write};
use std::os::fd::AsRawFd;
use std::process::{Child, ChildStdin, ChildStdout, Command, Stdio};
use std::sync::{Arc, Mutex};

struct NativeProcess {
    child: Child,
    input: Option<ChildStdin>,
    output: ChildStdout,
}

impl NativeProcess {
    fn read_line(&mut self) -> Result<String, IdentityError> {
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(10);
        let mut bytes = Vec::new();
        while bytes.len() <= 65536 {
            let remaining = deadline.saturating_duration_since(std::time::Instant::now());
            if remaining.is_zero() {
                return Err(IdentityError);
            }
            let mut descriptor = libc::pollfd {
                fd: self.output.as_raw_fd(),
                events: libc::POLLIN,
                revents: 0,
            };
            // The child owns this pipe until the request completes or the fixture is dropped.
            if unsafe { libc::poll(&mut descriptor, 1, remaining.as_millis() as i32) } <= 0 {
                return Err(IdentityError);
            }
            let mut buffer = [0; 4096];
            let count = self.output.read(&mut buffer).map_err(|_| IdentityError)?;
            if count == 0 {
                return Err(IdentityError);
            }
            bytes.extend_from_slice(&buffer[..count]);
            if bytes.last() == Some(&b'\n') {
                return String::from_utf8(bytes).map_err(|_| IdentityError);
            }
        }
        Err(IdentityError)
    }
}

impl Drop for NativeProcess {
    fn drop(&mut self) {
        self.input.take();
        for _ in 0..100 {
            if self.child.try_wait().ok().flatten().is_some() {
                return;
            }
            std::thread::sleep(std::time::Duration::from_millis(10));
        }
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

struct NativeSigner(Mutex<NativeProcess>);

impl IdentitySigner for NativeSigner {
    fn sign(&self, scheme: u16, digest: bool, input: &[u8]) -> Result<Vec<u8>, IdentityError> {
        let mut process = self.0.lock().map_err(|_| IdentityError)?;
        let request = serde_json::json!({"scheme": scheme, "digest": digest,
            "input": base64::engine::general_purpose::STANDARD.encode(input)});
        writeln!(process.input.as_mut().ok_or(IdentityError)?, "{request}")
            .map_err(|_| IdentityError)?;
        let line = process.read_line()?;
        let response: serde_json::Value = serde_json::from_str(&line).map_err(|_| IdentityError)?;
        base64::engine::general_purpose::STANDARD
            .decode(response["signature"].as_str().ok_or(IdentityError)?)
            .map_err(|_| IdentityError)
    }
}

fn native_identity(directory: &std::path::Path, name: &str) -> Arc<ClientIdentity> {
    let mut child = Command::new(directory.join("native"))
        .args([directory.as_os_str(), name.as_ref()])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn()
        .unwrap();
    let input = child.stdin.take();
    let output = child.stdout.take().unwrap();
    let mut process = NativeProcess {
        child,
        input,
        output,
    };
    let line = process.read_line().unwrap();
    #[derive(serde::Deserialize)]
    struct Descriptor {
        certificates: Vec<String>,
        schemes: Vec<u16>,
    }
    let descriptor: Descriptor = serde_json::from_str(&line).unwrap();
    Arc::new(
        ClientIdentity::new(
            descriptor
                .certificates
                .into_iter()
                .map(|certificate| {
                    base64::engine::general_purpose::STANDARD
                        .decode(certificate)
                        .unwrap()
                })
                .collect(),
            descriptor.schemes,
            Arc::new(NativeSigner(Mutex::new(process))),
        )
        .unwrap(),
    )
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires scripts/test-authentication.sh HTTPS and native signer fixtures"]
async fn authentication_https_native_certificate_cookies_and_gateway_mfa() {
    let directory =
        std::path::PathBuf::from(std::env::var("GPBAR_AUTHENTICATION_FIXTURE").unwrap());
    let origin = std::fs::read_to_string(directory.join("origin")).unwrap();
    let server_der = std::fs::read(directory.join("server.der")).unwrap();
    let server_pem = std::fs::read(directory.join("server.pem")).unwrap();
    let params = GpParams::new(ClientOs::Mac);
    let no_identity = GpBar {
        http: reqwest::Client::builder()
            .no_proxy()
            .timeout(std::time::Duration::from_secs(5))
            .add_root_certificate(reqwest::Certificate::from_pem(&server_pem).unwrap())
            .build()
            .unwrap(),
        bounded_responses: true,
        gp_params: params.clone(),
    };
    assert!(no_identity.prelogin(&origin).await.is_err());
    for name in ["rsa", "p256", "p384", "p521"] {
        let identity = native_identity(&directory, name);
        assert!(
            GpBar::new_for_app_with_identity(params.clone(), identity.clone())
                .unwrap()
                .prelogin(&origin)
                .await
                .is_err(),
            "production must reject fixture server trust"
        );
        let mut incompatible = params.clone();
        incompatible.ignore_tls_errors = true;
        assert!(GpBar::new_for_app_with_identity(incompatible, identity.clone()).is_err());
        let mut tls = crate::identity::tls_config(identity).unwrap();
        let mut roots = rustls::RootCertStore::empty();
        roots
            .add(rustls::pki_types::CertificateDer::from(server_der.clone()))
            .unwrap();
        let verifier = rustls::client::WebPkiServerVerifier::builder_with_provider(
            Arc::new(roots),
            Arc::new(rustls::crypto::ring::default_provider()),
        )
        .build()
        .unwrap();
        tls.dangerous().set_certificate_verifier(verifier);
        let mut client = GpBar {
            http: reqwest::Client::builder()
                .no_proxy()
                .redirect(reqwest::redirect::Policy::none())
                .timeout(std::time::Duration::from_secs(10))
                .use_preconfigured_tls(tls)
                .build()
                .unwrap(),
            bounded_responses: true,
            gp_params: params.clone(),
        };
        assert!(matches!(
            client.prelogin(&origin).await.unwrap(),
            PreloginResponse::Standard(_)
        ));
        let certificate_only = Credential::Password {
            username: "fixture-user".into(),
            password: String::new(),
        };
        let PortalLoginResult::Success(config) = client
            .portal_login_for_app(&origin, &certificate_only)
            .await
            .unwrap()
        else {
            panic!("certificate-only portal authentication failed");
        };
        assert_eq!(config.cookie_lifetime_seconds, Some(3600));
        let credential = config.to_gateway_credential();
        assert!(matches!(
            client
                .portal_login_for_app(&origin, &credential)
                .await
                .unwrap(),
            PortalLoginResult::Success(_)
        ));
        let rejected = Credential::AuthCookie {
            username: "fixture-user".into(),
            user_auth_cookie: "rejected-cookie".into(),
            prelogon_user_auth_cookie: String::new(),
        };
        assert!(client
            .portal_login_for_app(&origin, &rejected)
            .await
            .is_err());
        let GatewayLoginResult::MfaChallenge { input_str, .. } =
            client.gateway_login(&origin, &credential).await.unwrap()
        else {
            panic!("gateway MFA challenge missing");
        };
        client.gp_params.input_str = Some(input_str);
        client.gp_params.otp = Some("654321".into());
        let GatewayLoginResult::Success(cookie) =
            client.gateway_login(&origin, &credential).await.unwrap()
        else {
            panic!("gateway MFA failed");
        };
        assert_eq!(cookie.authcookie, "tunnel-cookie");
        assert_eq!(cookie.user_auth_cookie.as_deref(), Some("gateway-cookie"));
        assert!(!format!("{cookie:?}").contains("tunnel-cookie"));
        assert!(!format!("{config:?}").contains("portal+cookie"));
    }
}

fn policy(agent: &str, overrides: &str) -> String {
    format!("<policy><agent-config>{agent}</agent-config><authentication-override>{overrides}</authentication-override></policy>")
}

#[test]
fn authentication_cookie_policy_requires_unambiguous_permission() {
    let lifetime = "<cookie-lifetime><lifetime-in-hours>1</lifetime-in-hours></cookie-lifetime>";
    let permission = "<accept-cookie>yes</accept-cookie><generate-cookie>yes</generate-cookie>";
    let agent = "<save-user-credentials>1</save-user-credentials>";
    let overrides = format!("{permission}{lifetime}");
    let accepted = policy(agent, &overrides);
    let parse = |xml: &str| {
        PortalConfig::parse(xml, "https://portal.example", "alice")
            .unwrap()
            .cookie_lifetime_seconds
    };
    assert_eq!(parse(&accepted), Some(3600));
    for xml in [
        policy("", &overrides),
        policy(agent, lifetime),
        policy(agent, permission),
        policy(&format!("{agent}{agent}"), &overrides),
        policy(agent, &format!("{permission}{permission}{lifetime}")),
        policy(agent, &format!("{permission}{lifetime}{lifetime}")),
        accepted.replace("<accept-cookie>yes", "<accept-cookie>no"),
        accepted.replace("<generate-cookie>yes", "<generate-cookie>no"),
        accepted.replace("<save-user-credentials>1", "<save-user-credentials>0"),
        accepted.replace("<lifetime-in-hours>1", "<lifetime-in-hours>0"),
        accepted.replace("<lifetime-in-hours>1", "<lifetime-in-hours>73"),
        accepted.replace(
            "<lifetime-in-hours>1",
            "<lifetime-in-hours>18446744073709551616",
        ),
        accepted.replace("lifetime-in-hours", "lifetime-in-seconds"),
        accepted.replace("<accept-cookie>yes", "<accept-cookie>yes<extra/>"),
        accepted
            .replace("<policy>", "<response>")
            .replace("</policy>", "</response>"),
    ] {
        assert_eq!(parse(&xml), None, "unsafe cookie policy: {xml}");
    }
    for (unit, amount, seconds) in [
        ("minutes", 59, 3540),
        ("hours", 72, 259200),
        ("days", 365, 31536000),
    ] {
        let xml = policy(agent, &format!("{permission}<cookie-lifetime><lifetime-in-{unit}>{amount}</lifetime-in-{unit}></cookie-lifetime>"));
        assert_eq!(parse(&xml), Some(seconds));
    }
}
