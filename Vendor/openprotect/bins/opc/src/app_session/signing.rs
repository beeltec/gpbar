use std::sync::Arc;
use std::time::Duration;

use anyhow::{bail, Result};
use base64::Engine;
use gp_ipc::app::{CertificateIdentity, Event};
use gp_proto::identity::{ClientIdentity, IdentityError, IdentitySigner};
use tokio::sync::{mpsc, oneshot, watch};

use super::{challenge_id, SharedOutput};

pub(super) struct Answer {
    pub request_id: String,
    pub signature: Option<String>,
}

struct Request {
    scheme: u16,
    digest: bool,
    input: Vec<u8>,
    reply: oneshot::Sender<Result<Vec<u8>, IdentityError>>,
}

struct RemoteSigner {
    requests: mpsc::Sender<Request>,
    stop: watch::Receiver<bool>,
    runtime: tokio::runtime::Handle,
}

impl IdentitySigner for RemoteSigner {
    fn sign(&self, scheme: u16, digest: bool, input: &[u8]) -> Result<Vec<u8>, IdentityError> {
        let mut stop = self.stop.clone();
        if *stop.borrow() {
            return Err(IdentityError);
        }
        self.runtime.block_on(async {
            tokio::select! {
                _ = stop.wait_for(|value| *value) => Err(IdentityError),
                result = tokio::time::timeout(Duration::from_secs(120), async {
                    let (reply, response) = oneshot::channel();
                    self.requests.send(Request { scheme, digest, input: input.to_vec(), reply }).await.map_err(|_| IdentityError)?;
                    response.await.map_err(|_| IdentityError)?
                }) => result.map_err(|_| IdentityError)?,
            }
        })
    }
}

pub(super) fn start(
    descriptor: CertificateIdentity,
    output: SharedOutput,
    stop: watch::Receiver<bool>,
    answers: mpsc::Receiver<Answer>,
) -> Result<(Arc<ClientIdentity>, tokio::task::JoinHandle<()>)> {
    if descriptor.certificates.len() > 16
        || descriptor
            .certificates
            .iter()
            .any(|cert| cert.len() > 21848)
    {
        bail!("invalid client identity");
    }
    let certificates = descriptor
        .certificates
        .into_iter()
        .map(|cert| base64::engine::general_purpose::STANDARD.decode(cert))
        .collect::<Result<Vec<_>, _>>()?;
    let (requests, receiver) = mpsc::channel(1);
    let identity = Arc::new(ClientIdentity::new(
        certificates,
        descriptor.schemes,
        Arc::new(RemoteSigner {
            requests,
            stop: stop.clone(),
            runtime: tokio::runtime::Handle::current(),
        }),
    )?);
    gp_tunnel::install_client_identity(identity.clone())?;
    let task = tokio::spawn(worker(receiver, answers, output, stop));
    Ok((identity, task))
}

async fn worker(
    mut requests: mpsc::Receiver<Request>,
    mut answers: mpsc::Receiver<Answer>,
    output: SharedOutput,
    mut stop: watch::Receiver<bool>,
) {
    loop {
        let request = tokio::select! {
            _ = stop.wait_for(|value| *value) => return,
            value = requests.recv() => match value { Some(value) => value, None => return },
        };
        let mut reply = request.reply;
        let result = tokio::select! {
            _ = stop.wait_for(|value| *value) => return,
            _ = reply.closed() => continue,
            result = tokio::time::timeout(Duration::from_secs(120), async {
                let id = challenge_id().map_err(|_| IdentityError)?;
                let input = base64::engine::general_purpose::STANDARD.encode(&request.input);
                output.lock().await.send(Event::SignatureRequired {
                    request_id: &id, scheme: request.scheme, digest: request.digest, input: &input,
                }).await.map_err(|_| IdentityError)?;
                let answer = loop {
                    let answer = answers.recv().await.ok_or(IdentityError)?;
                    if answer.request_id == id { break answer; }
                };
                let signature = answer.signature.ok_or(IdentityError)?;
                if signature.len() > 1368 { return Err(IdentityError); }
                let signature = base64::engine::general_purpose::STANDARD.decode(signature).map_err(|_| IdentityError)?;
                if signature.is_empty() || signature.len() > 1024 { return Err(IdentityError); }
                Ok(signature)
            }) => result.unwrap_or(Err(IdentityError)),
        };
        let _ = reply.send(result);
    }
}
