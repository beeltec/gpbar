use super::*;
use crate::app_session::authentication_tests::{event, output};
use std::sync::atomic::{AtomicUsize, Ordering};

struct CountSigner(AtomicUsize);
impl IdentitySigner for CountSigner {
    fn sign(&self, _scheme: u16, _digest: bool, _input: &[u8]) -> Result<Vec<u8>, IdentityError> {
        self.0.fetch_add(1, Ordering::SeqCst);
        Ok(vec![42])
    }
}

#[test]
fn authentication_identity_rejects_unsafe_descriptors_and_requests() {
    let signer = Arc::new(CountSigner(AtomicUsize::new(0)));
    for (certificates, schemes) in [
        (vec![], vec![0x0403]),
        (vec![vec![]], vec![0x0403]),
        (vec![vec![1]; 17], vec![0x0403]),
        (vec![vec![1; 16385]], vec![0x0403]),
        (vec![vec![1; 16384]; 5], vec![0x0403]),
        (vec![vec![1]], vec![]),
        (vec![vec![1]], vec![0x0201]),
        (vec![vec![1]], vec![0x0403, 0x0401]),
    ] {
        assert!(ClientIdentity::new(certificates, schemes, signer.clone()).is_err());
    }
    let identity = ClientIdentity::new(vec![vec![1]], vec![0x0503], signer.clone()).unwrap();
    for (scheme, digest, input) in [
        (0x0201, false, vec![1]),
        (0x0503, false, vec![]),
        (0x0503, false, vec![1; 65537]),
        (0x0503, true, vec![1; 32]),
        (0x0403, false, vec![1]),
    ] {
        assert!(identity.sign(scheme, digest, &input).is_err());
    }
    assert_eq!(signer.0.load(Ordering::SeqCst), 0);
    assert!(identity.sign(0x0403, true, &[1; 32]).is_ok());
    assert_eq!(signer.0.load(Ordering::SeqCst), 1);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn authentication_signing_reply_ownership_and_bounds() {
    for signature in [
        Some("Kg==".to_string()),
        None,
        Some(String::new()),
        Some("invalid base64".into()),
        Some("A".repeat(1372)),
    ] {
        let (output, mut reader) = output();
        let (stop, stopped) = watch::channel(false);
        let (requests, receiver) = mpsc::channel(1);
        let (answers, replies) = mpsc::channel(2);
        let worker = tokio::spawn(worker(receiver, replies, output, stopped.clone()));
        let signer = RemoteSigner {
            requests,
            stop: stopped,
            runtime: tokio::runtime::Handle::current(),
        };
        let signing = tokio::task::spawn_blocking(move || signer.sign(0x0403, false, &[1, 2, 3]));
        let prompt = event(&mut reader, "signature_required").await;
        assert_eq!(prompt["scheme"], 0x0403);
        assert_eq!(prompt["input"], "AQID");
        answers
            .send(Answer {
                request_id: "stale".into(),
                signature: Some("AQ==".into()),
            })
            .await
            .unwrap();
        let valid = signature.as_deref() == Some("Kg==");
        answers
            .send(Answer {
                request_id: prompt["request_id"].as_str().unwrap().into(),
                signature,
            })
            .await
            .unwrap();
        let result = tokio::time::timeout(Duration::from_secs(5), signing)
            .await
            .unwrap()
            .unwrap();
        if valid {
            assert_eq!(result.unwrap(), vec![42]);
        } else {
            assert!(result.is_err());
        }
        stop.send_replace(true);
        worker.await.unwrap();
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn authentication_signing_cancellation_releases_pending_request() {
    let (output, mut reader) = output();
    let (stop, stopped) = watch::channel(false);
    let (requests, receiver) = mpsc::channel(1);
    let (_answers, replies) = mpsc::channel(1);
    let worker = tokio::spawn(worker(receiver, replies, output, stopped.clone()));
    let signer = RemoteSigner {
        requests,
        stop: stopped,
        runtime: tokio::runtime::Handle::current(),
    };
    let signing = tokio::task::spawn_blocking(move || signer.sign(0x0403, false, &[1]));
    event(&mut reader, "signature_required").await;
    stop.send(true).unwrap();
    assert!(tokio::time::timeout(Duration::from_secs(5), signing)
        .await
        .unwrap()
        .unwrap()
        .is_err());
    tokio::time::timeout(Duration::from_secs(5), worker)
        .await
        .unwrap()
        .unwrap();
}
