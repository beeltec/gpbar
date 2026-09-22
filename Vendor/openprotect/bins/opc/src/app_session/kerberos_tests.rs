use super::*;
use gp_auth::kerberos::Negotiator;
use tokio::io::AsyncBufReadExt;

fn output() -> (SharedOutput, BufReader<Receiver>) {
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

#[tokio::test]
async fn kerberos_bridge_rejects_stale_replies_and_handles_unavailable_tickets() {
    for stale in [false, true] {
        let (output, mut reader) = output();
        let (answers, receiver) = mpsc::channel(1);
        let bridge = kerberos::Bridge {
            output,
            answers: Mutex::new(receiver),
        };
        let task =
            tokio::spawn(
                async move { bridge.step("context", "https://portal.example", None).await },
            );
        let mut line = String::new();
        reader.read_line(&mut line).await.unwrap();
        let event: serde_json::Value = serde_json::from_str(&line).unwrap();
        assert_eq!(event["event"]["server"], "https://portal.example");
        assert_eq!(event["event"]["context_id"], "context");
        let id = event["event"]["request_id"].as_str().unwrap();
        answers
            .send(kerberos::Answer {
                request_id: if stale { "old" } else { id }.into(),
                token: None,
                complete: false,
            })
            .await
            .unwrap();
        let result = task.await.unwrap();
        if stale {
            assert!(result.is_err());
        } else {
            assert!(result.unwrap().is_none());
        }
    }
}

#[tokio::test]
async fn kerberos_cancel_drops_the_pending_exchange() {
    let (output, mut reader) = output();
    let (answers, receiver) = mpsc::channel(1);
    let bridge = kerberos::Bridge {
        output,
        answers: Mutex::new(receiver),
    };
    let task =
        tokio::spawn(async move { bridge.step("context", "https://portal.example", None).await });
    reader.read_line(&mut String::new()).await.unwrap();
    task.abort();
    match task.await {
        Err(error) => assert!(error.is_cancelled()),
        _ => panic!("pending exchange survived cancellation"),
    }
    assert!(answers
        .send(kerberos::Answer {
            request_id: "old".into(),
            token: None,
            complete: false
        })
        .await
        .is_err());
}

#[tokio::test]
async fn kerberos_credentials_use_the_existing_handoff_for_each_endpoint() {
    for portal in [true, false] {
        let (output, _reader) = output();
        let (_, mut answers) = mpsc::channel(1);
        let options = AuthenticationOptions {
            method: app::AuthenticationMethod::Automatic,
            identity: None,
            certificate_only: false,
            certificate_username: None,
            remember_authentication: false,
            saved_authentication: Mutex::new(None),
            kerberos: None,
            kerberos_fallback: std::sync::atomic::AtomicBool::new(false),
        };
        let prelogin = PreloginResponse::Kerberos {
            region: "test".into(),
            username: "alice".into(),
            prelogin_cookie: "secret".into(),
        };
        let (credential, _) = request_credential(
            "https://portal.example",
            &prelogin,
            &output,
            &mut answers,
            &options,
            portal,
        )
        .await
        .unwrap();
        let params = credential.to_params();
        assert!(params.contains(&("user", "alice".into())));
        assert!(params.contains(&("prelogin-cookie", "secret".into())));
        assert!(params.contains(&("passwd", String::new())));
    }
}
