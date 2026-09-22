use super::*;
use base64::Engine;
use gp_auth::{
    kerberos::{Negotiator, Step, MAX_TOKEN},
    AuthError,
};

pub(super) struct Answer {
    pub request_id: String,
    pub token: Option<String>,
    pub complete: bool,
}

pub(super) struct Bridge {
    pub output: SharedOutput,
    pub answers: Mutex<mpsc::Receiver<Answer>>,
}

#[async_trait::async_trait]
impl Negotiator for Bridge {
    async fn step(
        &self,
        context: &str,
        server: &str,
        input: Option<&[u8]>,
    ) -> std::result::Result<Option<Step>, AuthError> {
        let fail = || AuthError::Failed("Kerberos ticket exchange failed".into());
        let id = challenge_id().map_err(|_| fail())?;
        let input = input.map(|bytes| base64::engine::general_purpose::STANDARD.encode(bytes));
        self.output
            .lock()
            .await
            .send(Event::KerberosRequired {
                request_id: &id,
                context_id: context,
                server,
                input: input.as_deref(),
            })
            .await
            .map_err(|_| fail())?;
        let answer =
            tokio::time::timeout(Duration::from_secs(30), self.answers.lock().await.recv())
                .await
                .map_err(|_| fail())?
                .ok_or_else(fail)?;
        if answer.request_id != id {
            return Err(fail());
        }
        let Some(token) = answer.token else {
            if answer.complete {
                return Err(fail());
            }
            return Ok(None);
        };
        if token.len() > MAX_TOKEN * 4 / 3 {
            return Err(fail());
        }
        let token = base64::engine::general_purpose::STANDARD
            .decode(token)
            .map_err(|_| fail())?;
        Ok(Some(Step {
            token,
            complete: answer.complete,
        }))
    }

    async fn finish(&self, context: &str) {
        let _ = self
            .output
            .lock()
            .await
            .send(Event::KerberosFinished {
                context_id: context,
            })
            .await;
    }
}
