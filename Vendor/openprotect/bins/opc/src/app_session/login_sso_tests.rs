use super::*;

#[tokio::test]
async fn login_sso_only_marks_initial_portal_password_prompts() {
    for (portal, label, expected) in [
        (true, "Password", true),
        (false, "Password", false),
        (true, "OTP", false),
        (true, " ", false),
        (true, "", false),
        (true, "MISSING", false),
    ] {
        let (pipe, reader) = tokio::net::unix::pipe::pipe().unwrap();
        let output = Arc::new(Mutex::new(Output {
            pipe,
            sequence: 0,
            session_id: "fixture".into(),
            snapshot: AppSnapshot::default(),
            failure_reported: false,
        }));
        let mut reader = BufReader::new(reader);
        let (sender, mut answers) = mpsc::channel(1);
        let task = tokio::spawn(async move {
            let label = if label == "MISSING" {
                String::new()
            } else {
                format!("<password-label>{label}</password-label>")
            };
            let prelogin = PreloginResponse::parse(&format!(
                "<prelogin-response><status>Success</status>{label}</prelogin-response>"
            ))
            .unwrap();
            let options = AuthenticationOptions {
                method: app::AuthenticationMethod::Automatic,
                identity: None,
                certificate_only: false,
                certificate_username: None,
                remember_authentication: false,
                kerberos: None,
                kerberos_fallback: std::sync::atomic::AtomicBool::new(false),
                saved_authentication: Mutex::new(None),
            };
            request_credential(
                "https://portal.example",
                &prelogin,
                &output,
                &mut answers,
                &options,
                portal,
            )
            .await
        });
        let event = loop {
            let mut line = String::new();
            tokio::time::timeout(Duration::from_secs(5), reader.read_line(&mut line))
                .await
                .unwrap()
                .unwrap();
            let value: serde_json::Value = serde_json::from_str(&line).unwrap();
            if value["event"]["type"] == "credentials_required" {
                break value["event"].clone();
            }
        };
        assert_eq!(event["login_sso_allowed"], expected);
        sender
            .send(Answer {
                challenge_id: event["challenge_id"].as_str().unwrap().into(),
                value: "fixture-password".into(),
                otp: false,
                username: Some("fixture-user".into()),
            })
            .await
            .unwrap();
        let (credential, _) = task.await.unwrap().unwrap();
        assert!(
            matches!(credential, Credential::Password { username, password }
            if username == "fixture-user" && password == "fixture-password")
        );
    }
}
