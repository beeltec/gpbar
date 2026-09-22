use super::*;
use base64::Engine;

fn options(method: app::AuthenticationMethod) -> AuthenticationOptions {
    AuthenticationOptions {
        method,
        identity: None,
        certificate_only: false,
        certificate_username: None,
        remember_authentication: false,
        kerberos: None,
        kerberos_fallback: std::sync::atomic::AtomicBool::new(false),
        saved_authentication: Mutex::new(None),
    }
}

fn output() -> (SharedOutput, BufReader<Receiver>) {
    let (pipe, reader) = tokio::net::unix::pipe::pipe().unwrap();
    (
        Arc::new(Mutex::new(Output {
            pipe,
            sequence: 0,
            session_id: "fixture-session".into(),
            snapshot: AppSnapshot::default(),
            failure_reported: false,
        })),
        BufReader::new(reader),
    )
}

fn cas() -> PreloginResponse {
    PreloginResponse::Saml(gp_proto::prelogin::SamlPrelogin {
        region: String::new(), is_cas: true, saml_auth_method: "POST".into(),
        saml_request: base64::engine::general_purpose::STANDARD.encode("<form method='post' action='https://cie.example'><input name='request' value='original'></form>"),
    })
}

#[tokio::test]
async fn cie_method_selection_never_downgrades() {
    let (output, _reader) = output();
    for method in [
        app::AuthenticationMethod::Automatic,
        app::AuthenticationMethod::CloudIdentity,
        app::AuthenticationMethod::Certificate,
    ] {
        assert!(validate_portal_method(&cas(), method, &output)
            .await
            .is_ok());
    }
    for method in [
        app::AuthenticationMethod::Saml,
        app::AuthenticationMethod::Password,
    ] {
        assert!(validate_portal_method(&cas(), method, &output)
            .await
            .is_err());
    }
    let standard =
        PreloginResponse::parse("<prelogin-response><status>Success</status></prelogin-response>")
            .unwrap();
    assert!(
        validate_portal_method(&standard, app::AuthenticationMethod::CloudIdentity, &output)
            .await
            .is_err()
    );
}

async fn launch(reader: &mut BufReader<Receiver>) -> serde_json::Value {
    loop {
        let mut line = String::new();
        tokio::time::timeout(Duration::from_secs(5), reader.read_line(&mut line))
            .await
            .unwrap()
            .unwrap();
        let value: serde_json::Value = serde_json::from_str(&line).unwrap();
        if value["event"]["type"] == "authentication_required" {
            return value["event"].clone();
        }
    }
}

async fn fetch(url: &str, host: Option<&str>) -> std::io::Result<String> {
    let (authority, path) = url
        .strip_prefix("http://")
        .unwrap()
        .split_once('/')
        .unwrap();
    let mut socket = tokio::net::TcpStream::connect(authority).await?;
    let request = format!(
        "GET /{path} HTTP/1.1\r\nHost: {}\r\nConnection: close\r\n\r\n",
        host.unwrap_or(authority)
    );
    socket.write_all(request.as_bytes()).await?;
    let mut result = String::new();
    tokio::time::timeout(Duration::from_secs(5), socket.read_to_string(&mut result)).await??;
    Ok(result)
}

#[tokio::test]
async fn cie_loopback_handoff_and_single_challenge_response() {
    let (output, mut reader) = output();
    let (sender, mut answers) = mpsc::channel(1);
    let task = tokio::spawn(async move {
        request_credential(
            "https://portal.example",
            &cas(),
            &output,
            &mut answers,
            &options(app::AuthenticationMethod::Automatic),
            true,
        )
        .await
    });
    let event = launch(&mut reader).await;
    assert_eq!(event["cloud_identity"], true);
    let url = event["launch_url"].as_str().unwrap();
    let response = fetch(url, None).await.unwrap();
    assert!(response.contains("Cache-Control: no-store"));
    assert!(response.contains("value='original'"));
    assert!(fetch(&format!("{url}wrong"), None)
        .await
        .unwrap()
        .starts_with("HTTP/1.1 404"));
    assert!(fetch(url, Some("evil.example"))
        .await
        .unwrap()
        .starts_with("HTTP/1.1 404"));
    sender
        .send(Answer {
            challenge_id: event["challenge_id"].as_str().unwrap().into(),
            otp: false,
            username: None,
            value: "globalprotectcallback:cas-as=1&un=alice&token=opaque-token".into(),
        })
        .await
        .unwrap();
    let (credential, _) = task.await.unwrap().unwrap();
    assert!(credential
        .to_params()
        .contains(&("token", "opaque-token".into())));
    assert!(fetch(url, None).await.is_err());
}

#[tokio::test]
async fn cie_cancel_and_wrong_challenge_close_the_launch_listener() {
    for cancel in [false, true] {
        let (output, mut reader) = output();
        let (sender, mut answers) = mpsc::channel(1);
        let task = tokio::spawn(async move {
            request_credential(
                "https://portal.example",
                &cas(),
                &output,
                &mut answers,
                &options(app::AuthenticationMethod::CloudIdentity),
                true,
            )
            .await
        });
        let event = launch(&mut reader).await;
        if cancel {
            task.abort();
            assert!(task.await.unwrap_err().is_cancelled());
        } else {
            sender
                .send(Answer {
                    challenge_id: "stale".into(),
                    value: "globalprotectcallback:cas-as=1&un=alice&token=opaque".into(),
                    otp: false,
                    username: None,
                })
                .await
                .unwrap();
            assert!(task.await.unwrap().is_err());
        }
        assert!(fetch(event["launch_url"].as_str().unwrap(), None)
            .await
            .is_err());
    }
}
