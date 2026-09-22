use super::*;
use crate::kerberos::{Negotiator, Step};
use std::sync::atomic::{AtomicUsize, Ordering};

struct Tickets {
    side: &'static str,
    missing: bool,
    calls: AtomicUsize,
    finished: AtomicUsize,
}

#[async_trait::async_trait]
impl Negotiator for Tickets {
    async fn step(
        &self,
        _: &str,
        server: &str,
        input: Option<&[u8]>,
    ) -> Result<Option<Step>, AuthError> {
        assert!(server.starts_with("https://localhost:"));
        let round = self.calls.fetch_add(1, Ordering::SeqCst);
        if self.missing {
            return Ok(None);
        }
        if round == 0 {
            assert!(input.is_none());
            Ok(Some(Step {
                token: format!("{}-ticket", self.side).into_bytes(),
                complete: false,
            }))
        } else {
            if input == Some(b"invalid".as_slice()) {
                return Err(AuthError::Kerberos);
            }
            assert_eq!(input.unwrap(), format!("{}-reply", self.side).as_bytes());
            Ok(Some(Step {
                token: vec![],
                complete: true,
            }))
        }
    }
    async fn finish(&self, _: &str) {
        self.finished.fetch_add(1, Ordering::SeqCst);
    }
}

fn tickets(side: &'static str, missing: bool) -> Tickets {
    Tickets {
        side,
        missing,
        calls: AtomicUsize::new(0),
        finished: AtomicUsize::new(0),
    }
}

fn client(mode: &str, gateway: bool) -> GpBar {
    let cert = std::fs::read(std::env::var("GPBAR_KERBEROS_TEST_CERT").unwrap()).unwrap();
    let mut params = GpParams::new(ClientOs::Mac);
    params.computer = mode.into();
    params.is_gateway = gateway;
    GpBar {
        http: reqwest::Client::builder()
            .no_proxy()
            .redirect(reqwest::redirect::Policy::none())
            .timeout(std::time::Duration::from_secs(5))
            .add_root_certificate(reqwest::Certificate::from_pem(&cert).unwrap())
            .build()
            .unwrap(),
        bounded_responses: true,
        gp_params: params,
    }
}

#[test]
fn kerberos_handoff_and_policy_reject_ambiguous_inputs() {
    let valid = "<prelogin-response><status>Success</status><krb-auth-status>1</krb-auth-status><krb-norm-username>alice</krb-norm-username><prelogin-cookie>secret</prelogin-cookie></prelogin-response>";
    let parsed = PreloginResponse::parse(valid).unwrap();
    assert!(!format!("{parsed:?}").contains("secret"));
    for invalid in [
        valid.replace("<krb-norm-username>alice</krb-norm-username>", ""),
        valid.replace("<prelogin-cookie>secret</prelogin-cookie>", ""),
        valid.replace("<status>Success</status>", ""),
        valid.replace(
            "<krb-auth-status>1</krb-auth-status>",
            "<krb-auth-status>1</krb-auth-status><krb-auth-status>0</krb-auth-status>",
        ),
        valid.replace(
            "<krb-auth-status>1</krb-auth-status>",
            "<krb-auth-status>2</krb-auth-status>",
        ),
        valid.replace("alice", "a&#10;b"),
        valid.replace("secret", &"a".repeat(16385)),
    ] {
        assert!(PreloginResponse::parse(&invalid).is_err());
    }
    for (policy, allowed) in [
        ("<agent-config><krb-auth-fail-fallback>yes</krb-auth-fail-fallback></agent-config>", true),
        ("<agent-config><krb-auth-fail-fallback>no</krb-auth-fail-fallback></agent-config>", false),
        ("<agent-config><krb-auth-fail-fallback>yes</krb-auth-fail-fallback><krb-auth-fail-fallback>no</krb-auth-fail-fallback></agent-config>", false),
        ("<agent-config><krb-auth-fail-fallback><value>yes</value></krb-auth-fail-fallback></agent-config>", false),
        ("", false),
    ] { assert_eq!(PortalConfig::parse(&format!("<policy>{policy}</policy>"), "portal", "alice").unwrap().kerberos_fallback, allowed); }
}

#[tokio::test]
#[ignore = "requires scripts/test-kerberos.sh HTTPS fixture"]
async fn kerberos_https_portal_gateway_and_failure_policy() {
    let origin = std::env::var("GPBAR_KERBEROS_TEST_ORIGIN").unwrap();
    assert!(GpBar::new_for_app(GpParams::new(ClientOs::Mac))
        .unwrap()
        .prelogin(&origin)
        .await
        .is_err());
    for gateway in [false, true] {
        let client = client("success", gateway);
        let tickets = tickets(if gateway { "gateway" } else { "portal" }, false);
        let prelogin = client
            .prelogin_with_kerberos(&origin, &tickets, "context", 0)
            .await
            .unwrap();
        let PreloginResponse::Kerberos {
            username,
            prelogin_cookie,
            ..
        } = prelogin
        else {
            panic!("missing Kerberos result")
        };
        let credential = Credential::Prelogin {
            username,
            prelogin_cookie: Some(prelogin_cookie),
            token: None,
        };
        if gateway {
            assert!(matches!(
                client.gateway_login(&origin, &credential).await.unwrap(),
                GatewayLoginResult::Success(_)
            ));
        } else {
            let PortalLoginResult::Success(config) = client
                .portal_login_for_app(&origin, &credential)
                .await
                .unwrap()
            else {
                panic!("portal rejected")
            };
            assert!(config.kerberos_fallback);
        }
        assert_eq!(tickets.calls.load(Ordering::SeqCst), 2);
        assert_eq!(tickets.finished.load(Ordering::SeqCst), 1);
    }
    for mode in [
        "missing",
        "reject",
        "failed-status",
        "initial-failure",
        "invalid-continuation",
        "bad-header",
        "redirect",
        "unsolicited",
        "missing-cookie",
        "missing-mutual",
    ] {
        for fallback_until in [0, 1, u64::MAX] {
            let fallback = fallback_until == u64::MAX;
            let tickets = tickets("portal", mode == "missing");
            let result = client(mode, false)
                .prelogin_with_kerberos(&origin, &tickets, "context", fallback_until)
                .await;
            assert_eq!(
                result.is_ok(),
                fallback
                    && ["missing", "reject", "failed-status", "initial-failure"].contains(&mode),
                "{mode}, fallback={fallback}"
            );
            assert_eq!(tickets.finished.load(Ordering::SeqCst), 1);
        }
    }
}
