use super::*;

fn cookie(server: &str, value: &str) -> app::RetainedCookie {
    app::RetainedCookie {
        server: server.into(),
        username: "alice".into(),
        value: value.into(),
        issued_at: cookies::now() - 60,
        expires_at: cookies::now() + 3600,
    }
}

fn saved() -> app::SavedAuthentication {
    app::SavedAuthentication {
        portal: "https://portal.example".into(),
        username: "alice".into(),
        computer: "fixture".into(),
        portal_cookie: Some(cookie("https://portal.example", "portal-cookie")),
        gateway_cookie: Some(cookie("https://gateway.example", "gateway-cookie")),
    }
}

#[test]
fn authentication_cookies_bind_origin_account_device_and_expiry() {
    let mut saved = saved();
    assert!(cookies::valid(&saved, "https://portal.example", "fixture"));
    assert!(!cookies::valid(&saved, "https://other.example", "fixture"));
    assert!(!cookies::valid(
        &saved,
        "https://portal.example",
        "other-device"
    ));
    saved.portal_cookie.as_mut().unwrap().username = "bob".into();
    assert!(!cookies::valid(&saved, "https://portal.example", "fixture"));
    saved.portal_cookie.as_mut().unwrap().username = "alice".into();
    saved.portal_cookie.as_mut().unwrap().server = "https://gateway.example".into();
    assert!(!cookies::valid(&saved, "https://portal.example", "fixture"));
    saved.portal_cookie = None;
    let retained = saved.gateway_cookie.as_mut().unwrap();
    retained.expires_at = cookies::now() - 1;
    let credential = cookies::credential(retained);
    assert!(!cookies::current(retained));
    assert!(cookies::check_credential(&credential, Some(&saved)).is_err());
    saved.gateway_cookie.as_mut().unwrap().issued_at = cookies::now() + 60;
    saved.gateway_cookie.as_mut().unwrap().expires_at = cookies::now() + 3600;
    assert!(!cookies::current(saved.gateway_cookie.as_ref().unwrap()));
    assert!(!format!("{credential:?}").contains("gateway-cookie"));
}

#[test]
fn authentication_cookie_reuse_never_extends_retention() {
    let mut old = cookie("https://portal.example", "same-cookie");
    let retain = |lifetime, previous: &app::RetainedCookie| {
        cookies::retain(
            "https://portal.example",
            "alice",
            "same-cookie",
            lifetime,
            Some(previous),
        )
    };
    let reused = retain(86400, &old).unwrap();
    assert_eq!(reused.issued_at, old.issued_at);
    assert_eq!(reused.expires_at, old.expires_at);
    let shortened = retain(120, &old).unwrap();
    assert_eq!(shortened.expires_at, old.issued_at + 120);
    old.expires_at = cookies::now() - 1;
    assert!(retain(86400, &old).is_none());
    assert!(cookies::retain(
        "https://portal.example",
        "alice",
        "fresh-cookie",
        3600,
        Some(&old)
    )
    .is_some());
    let mut saved = saved();
    saved.portal_cookie = Some(old.clone());
    let mut second = old.clone();
    second.server = "https://gateway.example".into();
    second.expires_at += 10;
    saved.gateway_cookie = Some(second);
    assert_eq!(
        cookies::previous(Some(&saved), "same-cookie")
            .unwrap()
            .expires_at,
        old.expires_at
    );
    for value in ["", "empty", "(null)", "line\nbreak"] {
        assert!(cookies::retain("https://portal.example", "alice", value, 3600, None).is_none());
    }
    for lifetime in [0, 366 * 86400, u64::MAX] {
        assert!(retain(lifetime, &old).is_none());
    }
}

pub(super) fn output() -> (SharedOutput, BufReader<Receiver>) {
    let (pipe, reader) = tokio::net::unix::pipe::pipe().unwrap();
    (
        Arc::new(Mutex::new(Output {
            pipe,
            sequence: 0,
            session_id: "fixture".into(),
            snapshot: AppSnapshot::default(),
            failure_reported: false,
        })),
        BufReader::new(reader),
    )
}

pub(super) async fn event(reader: &mut BufReader<Receiver>, kind: &str) -> serde_json::Value {
    loop {
        let mut line = String::new();
        assert!(
            tokio::time::timeout(Duration::from_secs(5), reader.read_line(&mut line))
                .await
                .unwrap()
                .unwrap()
                > 0
        );
        let envelope: serde_json::Value = serde_json::from_str(&line).unwrap();
        if envelope["event"]["type"] == kind {
            return envelope["event"].clone();
        }
    }
}

fn options() -> AuthenticationOptions {
    AuthenticationOptions {
        method: app::AuthenticationMethod::Certificate,
        identity: None,
        certificate_only: true,
        certificate_username: Some("configured-user".into()),
        remember_authentication: true,
        kerberos: None,
        kerberos_fallback_until: std::sync::atomic::AtomicU64::new(0),
        saved_authentication: Mutex::new(None),
    }
}

#[tokio::test]
async fn authentication_certificate_only_uses_server_username_without_password() {
    let (output, _reader) = output();
    let (_sender, mut answers) = mpsc::channel(1);
    for (field, expected) in [
        (
            "<ccusername>certificate-user</ccusername>",
            "certificate-user",
        ),
        ("", "configured-user"),
    ] {
        let response = PreloginResponse::parse(&format!(
            "<prelogin-response><status>Success</status>{field}</prelogin-response>"
        ))
        .unwrap();
        let (credential, _) = request_credential(
            "https://portal.example",
            &response,
            &output,
            &mut answers,
            &options(),
            true,
        )
        .await
        .unwrap();
        assert!(
            matches!(credential, Credential::Password { username, password } if username == expected && password.is_empty())
        );
    }
}

#[tokio::test]
async fn authentication_certificate_mode_preserves_password_and_mfa_prompts() {
    let (output, mut reader) = output();
    let (sender, mut answers) = mpsc::channel(1);
    let task = tokio::spawn(async move {
        let mut options = options();
        options.certificate_only = false;
        let prelogin = PreloginResponse::parse("<prelogin-response><status>Success</status><password-label>Password</password-label></prelogin-response>").unwrap();
        let (credential, _) = request_credential(
            "https://gateway.example",
            &prelogin,
            &output,
            &mut answers,
            &options,
            false,
        )
        .await
        .unwrap();
        assert!(
            matches!(credential, Credential::Password { username, password } if username == "gateway-user" && password == "gateway-password")
        );
        let (code, _) = request_otp("https://gateway.example", "Verify", &output, &mut answers)
            .await
            .unwrap();
        assert_eq!(code, "654321");
    });
    let prompt = event(&mut reader, "credentials_required").await;
    assert_eq!(prompt["server"], "https://gateway.example");
    assert_eq!(prompt["login_sso_allowed"], false);
    sender
        .send(Answer {
            challenge_id: prompt["challenge_id"].as_str().unwrap().into(),
            otp: false,
            username: Some("gateway-user".into()),
            value: "gateway-password".into(),
        })
        .await
        .unwrap();
    let prompt = event(&mut reader, "otp_required").await;
    sender
        .send(Answer {
            challenge_id: prompt["challenge_id"].as_str().unwrap().into(),
            otp: true,
            username: None,
            value: "654321".into(),
        })
        .await
        .unwrap();
    task.await.unwrap();
}

#[tokio::test]
async fn authentication_otp_rejects_stale_wrong_type_and_oversized_answers() {
    for (id, otp, username, value) in [
        ("stale", true, None, "123456".into()),
        ("current", false, None, "123456".into()),
        ("current", true, Some("alice".into()), "123456".into()),
        ("current", true, None, "x".repeat(1025)),
        ("current", true, None, "line\nbreak".into()),
        ("current", true, None, String::new()),
    ] {
        let (sender, mut answers) = mpsc::channel(1);
        sender
            .send(Answer {
                challenge_id: id.into(),
                otp,
                username,
                value,
            })
            .await
            .unwrap();
        assert!(answer(&mut answers, "current", true).await.is_err());
    }
}

#[tokio::test]
async fn authentication_cache_clear_emits_no_secret_snapshot() {
    let (output, mut reader) = output();
    let options = options();
    options.save(Some(saved()), &output).await.unwrap();
    let changed = event(&mut reader, "authentication_cache_changed").await;
    assert_eq!(
        changed["saved_authentication"]["portal_cookie"]["value"],
        "portal-cookie"
    );
    output.lock().await.snapshot().await.unwrap();
    let snapshot = event(&mut reader, "snapshot").await.to_string();
    assert!(!snapshot.contains("portal-cookie") && !snapshot.contains("gateway-cookie"));
    options.save(None, &output).await.unwrap();
    assert!(
        event(&mut reader, "authentication_cache_changed").await["saved_authentication"].is_null()
    );
    assert!(options.saved_authentication.lock().await.is_none());
}
