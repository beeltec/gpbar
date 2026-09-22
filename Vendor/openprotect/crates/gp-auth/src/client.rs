//! HTTP client for GlobalProtect API endpoints.

use gp_proto::*;

use crate::error::AuthError;
use crate::hip::cookie_to_form_fields;

/// HTTP client wrapping the GlobalProtect REST-ish API.
pub struct GpBar {
    pub(crate) http: reqwest::Client,
    bounded_responses: bool,
    /// The GP request parameters attached to every call.
    pub gp_params: GpParams,
}

pub enum PortalLoginResult {
    Success(PortalConfig),
    Challenge { message: String, input_str: String },
}

impl GpBar {
    /// Create a new client from the given parameters.
    pub fn new(gp_params: GpParams) -> Result<Self, AuthError> {
        Self::build(gp_params, false, None)
    }

    pub fn new_for_app(gp_params: GpParams) -> Result<Self, AuthError> {
        Self::build(gp_params, true, None)
    }

    pub fn new_for_app_with_identity(
        gp_params: GpParams,
        identity: std::sync::Arc<gp_proto::identity::ClientIdentity>,
    ) -> Result<Self, AuthError> {
        Self::build(gp_params, true, Some(identity))
    }

    fn build(
        gp_params: GpParams,
        bounded_responses: bool,
        identity: Option<std::sync::Arc<gp_proto::identity::ClientIdentity>>,
    ) -> Result<Self, AuthError> {
        let mut builder = reqwest::Client::builder()
            .user_agent(&gp_params.user_agent)
            .danger_accept_invalid_certs(gp_params.ignore_tls_errors);

        if bounded_responses {
            builder = builder
                .connect_timeout(std::time::Duration::from_secs(10))
                .timeout(std::time::Duration::from_secs(30))
                .redirect(reqwest::redirect::Policy::none())
                .no_proxy();
        }

        // DNS pin: if the caller supplied a pre-resolved IP for the
        // gateway, route the hostname directly there. Used by the
        // Windows HIP fallback so the post-NRPT internal DNS can't
        // hijack the gateway hostname out from under us. TLS / SNI
        // still uses the hostname so cert validation is unaffected.
        if let Some((host, addr)) = gp_params.resolve_override.clone() {
            tracing::debug!("GpBar: resolve override {host} -> {addr}");
            builder = builder.resolve(&host, addr);
        }

        if let Some(identity) = identity {
            if gp_params.ignore_tls_errors || gp_params.client_cert.is_some()
                || gp_params.client_key.is_some() || gp_params.client_pkcs12.is_some()
            {
                return Err(AuthError::Other("conflicting client identity settings".into()));
            }
            // TLS signing can wait up to 120 seconds for Keychain approval.
            builder = builder
                .connect_timeout(std::time::Duration::from_secs(130))
                .timeout(std::time::Duration::from_secs(150))
                .use_preconfigured_tls(crate::identity::tls_config(identity)?);
        } else if let Some(p12_path) = &gp_params.client_pkcs12 {
            // reqwest + rustls doesn't support PKCS#12 directly
            // (from_pkcs12_der requires native-tls). Convert to PEM
            // via rustls-pemfile + pkcs8. For now, require PEM format
            // and bail with a clear message for PKCS#12.
            return Err(AuthError::Other(format!(
                "--pkcs12 is not supported with the rustls TLS backend. \
                 Convert your PKCS#12 bundle to a combined PEM file:\n\
                 \n  openssl pkcs12 -in {p12_path} -out combined.pem -nodes\n\
                 \nThis produces a single file containing both the certificate \
                 and private key. Pass it to both flags:\n\
                 \n  opc connect --cert combined.pem --key combined.pem ..."
            )));
        } else if let Some(cert_path) = &gp_params.client_cert {
            let cert_pem = std::fs::read(cert_path)
                .map_err(|e| AuthError::Other(format!("reading cert {cert_path}: {e}")))?;
            let key_path = gp_params.client_key.as_deref().ok_or_else(|| {
                AuthError::Other("--cert requires --key (PEM private key path)".into())
            })?;
            let key_pem = std::fs::read(key_path)
                .map_err(|e| AuthError::Other(format!("reading key {key_path}: {e}")))?;
            let mut combined = cert_pem;
            combined.push(b'\n');
            combined.extend_from_slice(&key_pem);
            let identity = reqwest::Identity::from_pem(&combined)
                .map_err(|e| AuthError::Other(format!("loading PEM identity: {e}")))?;
            builder = builder.identity(identity);
        }

        let http = builder.build()?;
        Ok(Self { http, bounded_responses, gp_params })
    }

    pub(crate) async fn read_body(&self, mut response: reqwest::Response) -> Result<String, AuthError> {
        if !self.bounded_responses { return Ok(response.text().await?); }
        const LIMIT: usize = 2 * 1024 * 1024;
        if response.content_length().is_some_and(|length| length > LIMIT as u64) {
            return Err(AuthError::Failed("response exceeds size limit".into()));
        }
        let mut bytes = Vec::new();
        while let Some(chunk) = response.chunk().await? {
            if bytes.len() + chunk.len() > LIMIT {
                return Err(AuthError::Failed("response exceeds size limit".into()));
            }
            bytes.extend_from_slice(&chunk);
        }
        String::from_utf8(bytes).map_err(|_| AuthError::Failed("response has invalid encoding".into()))
    }

    /// Portal or gateway prelogin — determines the required auth method.
    pub async fn prelogin(&self, server: &str) -> Result<PreloginResponse, AuthError> {
        let url = self.gp_params.prelogin_url(server);
        let params = self.gp_params.to_prelogin_params();

        tracing::debug!("prelogin POST {url}");
        let response = self
            .http
            .post(&url)
            .form(&params)
            .send()
            .await?
            .error_for_status()?;
        let body = self.read_body(response).await?;

        tracing::trace!("prelogin response ({} bytes)", body.len());
        let parsed = PreloginResponse::parse(&body)?;
        if matches!(parsed, PreloginResponse::Kerberos { .. }) {
            return Err(AuthError::Failed("Kerberos negotiation required".into()));
        }
        Ok(parsed)
    }

    /// Retrieve the portal configuration (gateway list + auth cookies).
    ///
    /// This doubles as the "portal login" step — the credential is verified
    /// by the portal before it returns the config.
    pub async fn portal_config(
        &self,
        portal: &str,
        cred: &Credential,
    ) -> Result<PortalConfig, AuthError> {
        let body = self.portal_config_response(portal, cred).await?;
        Ok(PortalConfig::parse(&body, portal, cred.username())?)
    }

    pub async fn portal_login_for_app(
        &self,
        portal: &str,
        cred: &Credential,
    ) -> Result<PortalLoginResult, AuthError> {
        let body = self.portal_config_response(portal, cred).await?;
        if let Some(GatewayLoginResult::MfaChallenge { message, input_str }) =
            GatewayLoginResult::parse_challenge(&body)?
        {
            return Ok(PortalLoginResult::Challenge { message, input_str });
        }
        let root = gp_proto::xml::XmlNode::parse(&body)?;
        let gateways = root.find("gateways");
        let has_gateway = gateways
            .and_then(|node| node.at("external/list").or_else(|| node.at("internal/list")))
            .is_some_and(|list| {
                list.children_named("entry")
                    .any(|entry| entry.attr("name").is_some_and(|name| !name.is_empty()))
            });
        if !matches!(root.name.as_str(), "policy" | "response") || !has_gateway {
            return Err(AuthError::Failed("portal authentication rejected".into()));
        }
        Ok(PortalLoginResult::Success(PortalConfig::parse(
            &body, portal, cred.username(),
        )?))
    }

    async fn portal_config_response(
        &self,
        portal: &str,
        cred: &Credential,
    ) -> Result<String, AuthError> {
        let mut params = self.login_params(cred);
        let host = gp_proto::params::normalize_server(portal);
        params.push(("server", host.into()));
        params.push(("host", host.into()));
        let response = self
            .http
            .post(self.gp_params.login_url(portal))
            .form(&params)
            .send()
            .await?
            .error_for_status()?;
        self.read_body(response).await
    }

    fn login_params(&self, cred: &Credential) -> Vec<(&'static str, String)> {
        let mut params = self.gp_params.to_params();
        params.retain(|(key, _)| *key != "passwd");
        params.extend(cred.to_params());
        if let Some(otp) = &self.gp_params.otp {
            if let Some((_, password)) = params.iter_mut().find(|(key, _)| *key == "passwd") {
                *password = otp.clone();
            }
        }
        params
    }

    /// Fetch the gateway's tunnel config by POSTing directly to
    /// `/ssl-vpn/getconfig.esp` with the authcookie already in hand.
    /// libopenconnect calls this internally during
    /// `make_cstp_connection`, but we also call it from the Rust
    /// side earlier in the flow so the HIP submission path knows
    /// the client-ip without having to pump state back out of the
    /// running tunnel thread.
    ///
    /// `cookie_str` is the authcookie query string built by
    /// [`crate::AuthContext`] / `build_openconnect_cookie` — the
    /// same `authcookie=…&portal=…&user=…` form libopenconnect
    /// consumes via `openconnect_set_cookie`.
    ///
    /// # Param set
    ///
    /// This endpoint is **picky** about extra form fields. Sending
    /// the full `gp_params::to_params()` set (which is tailored to
    /// `/ssl-vpn/login.esp`) produces a ~69-byte "error" XML with
    /// no root element — observed live against Prisma Access on a
    /// real UNSW deployment. The fix is to send the minimal set
    /// that yuezk v2's `HipReporter::retrieve_client_ip` uses:
    ///
    ///   client-type, protocol-version, internal, ipv6-support,
    ///   clientos, hmac-algo, enc-algo, os-version, app-version
    ///
    /// plus every field from the merged cookie (authcookie, portal,
    /// user, domain, computer, preferred-ip).
    ///
    /// Notably absent: `prot`, `jnlpReady`, `ok`, `direct`, `host-id`,
    /// `default-browser`, `cas-support`, `computer` (it's already in
    /// the cookie) and `clientVer` (replaced by `app-version`, which
    /// is the correct field name for this endpoint).
    pub async fn gateway_getconfig(
        &self,
        gateway: &str,
        cookie_str: &str,
    ) -> Result<GatewayConfig, AuthError> {
        let host = gp_proto::params::normalize_server(gateway);
        let url = format!("https://{host}/ssl-vpn/getconfig.esp");

        let client_os: String = self.gp_params.client_os.clientos().to_string();
        let os_version: String = self.gp_params.os_version.clone();
        let client_version: String = self.gp_params.client_version.clone();

        // Start with the minimal "correct" param set for this endpoint.
        let mut params: Vec<(String, String)> = vec![
            ("client-type".to_string(), "1".to_string()),
            ("protocol-version".to_string(), "p1".to_string()),
            ("internal".to_string(), "no".to_string()),
            ("ipv6-support".to_string(), "yes".to_string()),
            ("clientos".to_string(), client_os),
            // Match yuezk's reference client's algo advertisements.
            // We don't actually negotiate ESP / DTLS ourselves —
            // libopenconnect redoes getconfig internally and handles
            // that — but the gateway expects these fields and some
            // deployments reject POSTs that omit them.
            ("hmac-algo".to_string(), "sha1,md5,sha256".to_string()),
            (
                "enc-algo".to_string(),
                "aes-128-cbc,aes-256-cbc".to_string(),
            ),
            ("os-version".to_string(), os_version),
            // Note: this endpoint wants `app-version`, not `clientVer`.
            // Sending `clientVer` causes the server to return an error
            // XML with no root element (observed live against UNSW
            // Prisma Access).
            ("app-version".to_string(), client_version),
        ];

        // Append cookie fields (authcookie, portal, user, domain,
        // computer, preferred-ip). `computer` is in the cookie; we
        // deliberately do NOT send a separate top-level `computer`
        // field because duplicating it has been reported to confuse
        // some gateway deployments.
        params.extend(cookie_to_form_fields(cookie_str));

        tracing::debug!("gateway getconfig POST {url}");
        let response = self.http.post(&url).form(&params).send().await?;
        let status = response.status();
        let body = self.read_body(response).await?;
        tracing::trace!(
            "gateway getconfig response: status={status} bytes={} body_head={:?}",
            body.len(),
            body.chars().take(256).collect::<String>()
        );
        if !status.is_success() {
            return Err(AuthError::Failed(format!(
                "gateway getconfig returned HTTP {status}: {body_head}",
                body_head = body.chars().take(256).collect::<String>()
            )));
        }
        Ok(GatewayConfig::parse(&body)?)
    }

    /// POST `/ssl-vpn/hipreportcheck.esp`. Returns
    /// [`HipCheckResponse::needed`] = `true` iff the gateway wants
    /// us to follow up with a full report submission.
    pub async fn hip_report_check(
        &self,
        gateway: &str,
        cookie_str: &str,
        client_ip: &str,
        md5: &str,
    ) -> Result<HipCheckResponse, AuthError> {
        let host = gp_proto::params::normalize_server(gateway);
        let url = format!("https://{host}/ssl-vpn/hipreportcheck.esp");

        let mut params = cookie_to_form_fields(cookie_str);
        params.push(("client-role".to_string(), "global-protect-full".to_string()));
        params.push(("client-ip".to_string(), client_ip.to_string()));
        params.push(("md5".to_string(), md5.to_string()));

        tracing::debug!("hipreportcheck POST {url}");
        let response = self
            .http
            .post(&url)
            .form(&params)
            .send()
            .await?
            .error_for_status()?;
        let body = self.read_body(response).await?;
        tracing::trace!("hipreportcheck response ({} bytes)", body.len());
        Ok(HipCheckResponse::parse(&body)?)
    }

    /// POST `/ssl-vpn/hipreport.esp` with the full HIP XML document.
    /// Ignores the gateway's response body — a successful
    /// `error_for_status` is taken as acceptance.
    pub async fn submit_hip_report(
        &self,
        gateway: &str,
        cookie_str: &str,
        client_ip: &str,
        report_xml: &str,
    ) -> Result<(), AuthError> {
        let host = gp_proto::params::normalize_server(gateway);
        let url = format!("https://{host}/ssl-vpn/hipreport.esp");

        let mut params = cookie_to_form_fields(cookie_str);
        params.push(("client-role".to_string(), "global-protect-full".to_string()));
        params.push(("client-ip".to_string(), client_ip.to_string()));
        params.push(("report".to_string(), report_xml.to_string()));

        tracing::debug!("hipreport POST {url}");
        let response = self
            .http
            .post(&url)
            .form(&params)
            .send()
            .await?
            .error_for_status()?;
        let body = self.read_body(response).await?;
        tracing::trace!("hipreport response ({} bytes): {}", body.len(), body);
        Ok(())
    }

    /// Gateway login — exchange credentials for an authcookie.
    pub async fn gateway_login(
        &self,
        gateway: &str,
        cred: &Credential,
    ) -> Result<GatewayLoginResult, AuthError> {
        let host = gp_proto::params::normalize_server(gateway);
        let url = format!("https://{host}/ssl-vpn/login.esp");
        let mut params = self.login_params(cred);
        params.push(("server", host.to_string()));

        tracing::debug!("gateway login POST {url}");
        let response = self
            .http
            .post(&url)
            .form(&params)
            .send()
            .await?
            .error_for_status()?;
        let body = self.read_body(response).await?;

        tracing::trace!("gateway login response ({} bytes)", body.len());
        Ok(GatewayLoginResult::parse(&body, &self.gp_params.computer)?)
    }
}

#[cfg(test)]
mod cie_tests;

#[cfg(test)]
mod login_sso_tests;

#[cfg(test)]
mod kerberos_tests;
