//! Prelogin response parsing.
//!
//! The prelogin endpoint (`prelogin.esp`) tells the client what authentication
//! method the portal or gateway expects (password vs SAML).

use crate::error::ProtoError;
use crate::xml::XmlNode;

/// Parsed prelogin response from a portal or gateway.
#[derive(Clone)]
pub enum PreloginResponse {
    Kerberos { region: String, username: String, prelogin_cookie: String },
    /// Standard username + password authentication.
    Standard(StandardPrelogin),
    /// SAML-based authentication (browser redirect or POST).
    Saml(SamlPrelogin),
}

/// Fields for standard (password) authentication.
#[derive(Debug, Clone)]
pub struct StandardPrelogin {
    pub region: String,
    pub auth_message: String,
    pub label_username: String,
    pub label_password: String,
    pub explicit_password_label: bool,
    pub certificate_username: Option<String>,
}

/// Fields for SAML authentication.
#[derive(Debug, Clone)]
pub struct SamlPrelogin {
    pub region: String,
    pub is_cas: bool,
    /// `"POST"` or `"REDIRECT"`.
    pub saml_auth_method: String,
    /// Base64-encoded SAML request body or redirect URL.
    pub saml_request: String,
}

impl PreloginResponse {
    /// Parse from the XML body returned by `prelogin.esp`.
    pub fn parse(xml: &str) -> Result<Self, ProtoError> {
        let root = XmlNode::parse(xml)?;

        for name in ["status", "cas-auth", "saml-auth-method", "saml-request", "password-label", "krb-auth-status", "krb-norm-username", "prelogin-cookie"] {
            let mut fields = root.children_named(name);
            if let Some(field) = fields.next() {
                if fields.next().is_some() || !field.children.is_empty() {
                    return Err(ProtoError::Protocol("ambiguous prelogin response".into()));
                }
            }
        }
        let is_cas = match root.child("cas-auth").map(|field| field.text.as_str()) {
            Some("yes") => true,
            None | Some("no" | "") => false,
            _ => {
                return Err(ProtoError::Protocol(
                    "invalid CAS authentication flag".into(),
                ))
            }
        };
        if is_cas
            && (root.name != "prelogin-response" || root.child_text("status") != Some("Success"))
        {
            return Err(ProtoError::Protocol("invalid CAS prelogin response".into()));
        }

        // Check status
        let status = root.child_text("status").unwrap_or("Success");
        if !status.eq_ignore_ascii_case("success") {
            return Err(ProtoError::UnexpectedStatus(status.to_string()));
        }

        let region = root.child_text("region").unwrap_or("Unknown").to_string();

        match root.child_text("krb-auth-status") {
            Some("1") => {
                let username = root.child_text("krb-norm-username").unwrap_or("");
                let cookie = root.child_text("prelogin-cookie").unwrap_or("");
                if root.name != "prelogin-response" || root.child_text("status") != Some("Success")
                    || username.is_empty() || username.len() > 1024 || username.contains(char::is_control)
                    || cookie.is_empty() || cookie.len() > 16384 || cookie.contains(char::is_control)
                {
                    return Err(ProtoError::Protocol("invalid Kerberos credential handoff".into()));
                }
                return Ok(Self::Kerberos { region, username: username.into(), prelogin_cookie: cookie.into() });
            }
            None | Some("0") => {}
            _ => return Err(ProtoError::Protocol("invalid Kerberos status".into())),
        }

        // SAML auth?
        if let Some(method) = root.child_text("saml-auth-method") {
            let request = root
                .child_text("saml-request")
                .ok_or(ProtoError::MissingField {
                    field: "saml-request",
                    context: "SAML prelogin response",
                })?
                .to_string();

            return Ok(Self::Saml(SamlPrelogin {
                region,
                is_cas,
                saml_auth_method: method.to_string(),
                saml_request: request,
            }));
        }

        if is_cas {
            return Err(ProtoError::MissingField {
                field: "saml-auth-method",
                context: "CAS prelogin response",
            });
        }

        // Standard (password) auth
        Ok(Self::Standard(StandardPrelogin {
            explicit_password_label: root.child_text("password-label").is_some(),
            certificate_username: root
                .child_text("ccusername")
                .filter(|value| !value.is_empty())
                .map(str::to_owned),
            region,
            auth_message: root
                .child_text("authentication-message")
                .unwrap_or("Enter login credentials")
                .to_string(),
            label_username: root
                .child_text("username-label")
                .unwrap_or("Username")
                .to_string(),
            label_password: root
                .child_text("password-label")
                .unwrap_or("Password")
                .to_string(),
        }))
    }

    pub fn kerberos_failed(xml: &str) -> Result<bool, ProtoError> {
        Ok(XmlNode::parse(xml)?.child_text("krb-auth-status") == Some("0"))
    }

    /// Server region string.
    pub fn region(&self) -> &str {
        match self {
            Self::Kerberos { region, .. } => region,
            Self::Standard(s) => &s.region,
            Self::Saml(s) => &s.region,
        }
    }

    /// Whether the server requires SAML authentication.
    pub fn is_saml(&self) -> bool {
        matches!(self, Self::Saml(_))
    }
}

impl std::fmt::Debug for PreloginResponse {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Kerberos { .. } => f.write_str("Kerberos [REDACTED]"),
            Self::Standard(value) => value.fmt(f),
            Self::Saml(value) => value.fmt(f),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_standard() {
        let xml = r#"
        <prelogin-response>
            <status>Success</status>
            <region>Americas</region>
            <authentication-message>Sign in</authentication-message>
            <username-label>Email</username-label>
            <password-label>Secret</password-label>
        </prelogin-response>"#;

        let resp = PreloginResponse::parse(xml).unwrap();
        assert!(!resp.is_saml());
        assert_eq!(resp.region(), "Americas");

        if let PreloginResponse::Standard(s) = &resp {
            assert_eq!(s.auth_message, "Sign in");
            assert_eq!(s.label_username, "Email");
            assert_eq!(s.label_password, "Secret");
        } else {
            panic!("expected Standard");
        }
    }

    #[test]
    fn parse_saml() {
        let xml = r#"
        <prelogin-response>
            <status>Success</status>
            <region>EMEA</region>
            <saml-auth-method>REDIRECT</saml-auth-method>
            <saml-request>aHR0cHM6Ly9pZHAuZXhhbXBsZS5jb20=</saml-request>
        </prelogin-response>"#;

        let resp = PreloginResponse::parse(xml).unwrap();
        assert!(resp.is_saml());

        if let PreloginResponse::Saml(s) = &resp {
            assert_eq!(s.saml_auth_method, "REDIRECT");
            assert_eq!(s.saml_request, "aHR0cHM6Ly9pZHAuZXhhbXBsZS5jb20=");
        } else {
            panic!("expected Saml");
        }
    }

    #[test]
    fn parse_error_status() {
        let xml = r#"<prelogin-response><status>Error</status></prelogin-response>"#;
        assert!(PreloginResponse::parse(xml).is_err());
    }
}
