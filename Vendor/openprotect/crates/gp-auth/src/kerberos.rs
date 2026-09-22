use async_trait::async_trait;
use base64::Engine;
use gp_proto::PreloginResponse;
use reqwest::{header, StatusCode};

use crate::{AuthError, GpBar};

pub const MAX_TOKEN: usize = 49152;

pub struct Step {
    pub token: Vec<u8>,
    pub complete: bool,
}

#[async_trait]
pub trait Negotiator: Send + Sync {
    async fn step(
        &self,
        context: &str,
        server: &str,
        input: Option<&[u8]>,
    ) -> Result<Option<Step>, AuthError>;
    async fn finish(&self, context: &str);
}

fn failure() -> AuthError {
    AuthError::Failed("Kerberos authentication failed".into())
}

fn challenge(headers: &header::HeaderMap) -> Result<Option<Vec<u8>>, AuthError> {
    let mut result = None;
    for header in headers.get_all(header::WWW_AUTHENTICATE) {
        let value = header.to_str().map_err(|_| failure())?;
        for part in value.split(',') {
            let mut parts = part.split_ascii_whitespace();
            if !parts
                .next()
                .is_some_and(|scheme| scheme.eq_ignore_ascii_case("Negotiate"))
            {
                continue;
            }
            if result.is_some() {
                return Err(failure());
            }
            let token = parts.next().unwrap_or("");
            if token.len() > MAX_TOKEN * 4 / 3 || parts.next().is_some() {
                return Err(failure());
            }
            result = Some(
                base64::engine::general_purpose::STANDARD
                    .decode(token)
                    .map_err(|_| failure())?,
            );
        }
    }
    Ok(result)
}

impl GpBar {
    pub async fn prelogin_with_kerberos(
        &self,
        server: &str,
        negotiator: &dyn Negotiator,
        context: &str,
        fallback: bool,
    ) -> Result<PreloginResponse, AuthError> {
        let result = self
            .kerberos_exchange(server, negotiator, context, fallback)
            .await;
        negotiator.finish(context).await;
        result
    }

    async fn kerberos_exchange(
        &self,
        server: &str,
        negotiator: &dyn Negotiator,
        context: &str,
        fallback: bool,
    ) -> Result<PreloginResponse, AuthError> {
        let url = format!(
            "{}?kerberos-support=yes",
            self.gp_params.prelogin_url(server)
        );
        let mut params = self.gp_params.to_prelogin_params();
        params.push(("kerberos-support", "yes".into()));
        let mut response = self.http.post(&url).form(&params).send().await?;
        if response.status() != StatusCode::UNAUTHORIZED {
            if !response.status().is_success() {
                return Err(failure());
            }
            let body = self.read_body(response.error_for_status()?).await?;
            let parsed = PreloginResponse::parse(&body)?;
            if matches!(parsed, PreloginResponse::Kerberos { .. }) {
                return Err(failure());
            }
            return Ok(parsed);
        }
        let mut input = challenge(response.headers())?.ok_or_else(failure)?;
        if !input.is_empty() {
            return Err(failure());
        }
        for round in 0..4 {
            let step = negotiator
                .step(context, server, (round != 0).then_some(input.as_slice()))
                .await?;
            let Some(step) = step else {
                return self.kerberos_fallback(server, fallback).await;
            };
            if step.token.is_empty() || step.token.len() > MAX_TOKEN {
                return Err(failure());
            }
            let token = base64::engine::general_purpose::STANDARD.encode(&step.token);
            let mut authorization = header::HeaderValue::from_str(&format!("Negotiate {token}"))
                .map_err(|_| failure())?;
            authorization.set_sensitive(true);
            response = self
                .http
                .post(&url)
                .form(&params)
                .header(header::AUTHORIZATION, authorization)
                .send()
                .await?;
            if response.status() == StatusCode::UNAUTHORIZED {
                input = challenge(response.headers())?.ok_or_else(failure)?;
                if step.complete || input.is_empty() {
                    return self.kerberos_fallback(server, fallback).await;
                }
                continue;
            }
            response = response.error_for_status()?;
            if !response.status().is_success() {
                return Err(failure());
            }
            let final_token = challenge(response.headers())?;
            let complete = if let Some(token) = final_token {
                if token.is_empty() || step.complete {
                    return Err(failure());
                }
                let final_step = negotiator
                    .step(context, server, Some(&token))
                    .await?
                    .ok_or_else(failure)?;
                final_step.complete && final_step.token.is_empty()
            } else {
                step.complete
            };
            if !complete {
                return Err(failure());
            }
            let body = self.read_body(response).await?;
            let parsed = PreloginResponse::parse(&body)?;
            if matches!(parsed, PreloginResponse::Kerberos { .. }) {
                return Ok(parsed);
            }
            return self.kerberos_fallback(server, fallback).await;
        }
        Err(failure())
    }

    async fn kerberos_fallback(
        &self,
        server: &str,
        allowed: bool,
    ) -> Result<PreloginResponse, AuthError> {
        if !allowed {
            return Err(failure());
        }
        let mut params = self.gp_params.to_prelogin_params();
        params.push(("kerberos-support", "no".into()));
        let response = self
            .http
            .post(format!(
                "{}?kerberos-support=no",
                self.gp_params.prelogin_url(server)
            ))
            .form(&params)
            .send()
            .await?
            .error_for_status()?;
        let body = self.read_body(response).await?;
        let parsed = PreloginResponse::parse(&body)?;
        if matches!(parsed, PreloginResponse::Kerberos { .. }) {
            return Err(failure());
        }
        Ok(parsed)
    }
}
