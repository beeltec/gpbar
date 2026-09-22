//! Shared types and helpers used by every SAML auth provider
//! (`saml_paste` today, any future headless variant tomorrow).
//!
//! Historically this module also fed an embedded GTK+WebKit
//! provider (`saml_webview`). That provider was removed when
//! openprotect standardised on headless auth — see
//! `SamlAuthMode::Paste` and `SamlAuthMode::Okta` — so only the
//! paste/IdP-callback helpers still live here.

use base64::engine::general_purpose::STANDARD as BASE64;
use base64::Engine;
use gp_proto::Credential;

/// Data we extract from a completed SAML flow, regardless of transport.
///
/// `prelogin_cookie` here is the raw captured string — it may be a classic
/// on-prem GP prelogin cookie OR a Prisma Access JWT. The provider decides
/// which one it is via [`looks_like_jwt`] before building the final
/// [`Credential`].
#[derive(Clone)]
pub struct SamlCapture {
    pub username: String,
    pub prelogin_cookie: String,
    pub portal_user_auth_cookie: Option<String>,
}

impl std::fmt::Debug for SamlCapture {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("SamlCapture([redacted])")
    }
}

impl SamlCapture {
    /// Build a [`Credential::Prelogin`] from this capture, routing the
    /// secret into either the `token` field (JWT — Prisma Access) or
    /// `prelogin_cookie` field (classic GP).
    pub fn into_credential(self) -> Credential {
        let (prelogin_cookie, token) = if looks_like_jwt(&self.prelogin_cookie) {
            (None, Some(self.prelogin_cookie))
        } else {
            (Some(self.prelogin_cookie), None)
        };
        Credential::Prelogin {
            username: self.username,
            prelogin_cookie,
            token,
        }
    }
}

/// Heuristic: three non-empty base64-url segments separated by `.`.
pub fn looks_like_jwt(s: &str) -> bool {
    let parts: Vec<&str> = s.split('.').collect();
    parts.len() == 3
        && parts.iter().all(|p| {
            !p.is_empty()
                && p.bytes()
                    .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_' || b == b'=')
        })
}

/// Parse a Prisma Access `globalprotectcallback:` URI into a [`SamlCapture`].
///
/// Format: `globalprotectcallback:cas-as=1&un=<user>&token=<JWT>` — not a
/// standard URL (no `//`), so we split the scheme prefix and parse the
/// remainder as application/x-www-form-urlencoded.
///
/// Both modern (`un` / `token`) and slightly older (`user` /
/// `prelogin-cookie`) field name variants are recognized. The classic
/// on-prem callback form `globalprotectcallback:<base64-blob>` is also
/// recognized by base64-decoding the payload and extracting
/// `<saml-username>` / `<prelogin-cookie>` tags from the embedded HTML.
pub fn parse_globalprotect_callback(uri: &str) -> Option<SamlCapture> {
    if uri.len() > 256 * 1024 {
        return None;
    }
    let rest = uri.strip_prefix("globalprotectcallback:")?;
    let rest = rest.trim();
    let rest = rest.strip_prefix('?').unwrap_or(rest).trim();

    parse_query_callback(rest).or_else(|| parse_classic_cookie_callback(rest))
}

/// CAS returns a token for the VPN endpoint, not an OIDC authorization code.
pub fn parse_cas_callback(uri: &str) -> Option<Credential> {
    if uri.len() > 192 * 1024 {
        return None;
    }
    let query = uri.strip_prefix("globalprotectcallback:")?;
    let query = query.strip_prefix('?').unwrap_or(query);
    if query.contains('#')
        || query.contains(char::is_whitespace)
        || query.contains(char::is_control)
    {
        return None;
    }
    let mut fields = std::collections::HashMap::new();
    for pair in query.split('&') {
        let (key, value) = pair.split_once('=')?;
        if fields.len() >= 16
            || key.is_empty()
            || !key.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-')
        {
            return None;
        }
        let value = percent_decode(value)?;
        if value.is_empty()
            || value.contains(char::is_control)
            || fields.insert(key, value).is_some()
        {
            return None;
        }
    }
    if fields.remove("cas-as")?.as_str() != "1"
        || fields.contains_key("user")
        || fields.contains_key("prelogin-cookie")
        || fields.contains_key("portal-userauthcookie")
    {
        return None;
    }
    let username = fields.remove("un")?;
    let token = fields.remove("token")?;
    if username.len() > 1024 || token.len() > 128 * 1024 {
        return None;
    }
    Some(Credential::Prelogin {
        username,
        prelogin_cookie: None,
        token: Some(token),
    })
}

fn parse_query_callback(rest: &str) -> Option<SamlCapture> {
    if rest.split('&').any(|pair| pair.starts_with("cas-as=")) {
        let Credential::Prelogin {
            username,
            token: Some(token),
            ..
        } = parse_cas_callback(&format!("globalprotectcallback:{rest}"))?
        else {
            return None;
        };
        return Some(SamlCapture {
            username,
            prelogin_cookie: token,
            portal_user_auth_cookie: None,
        });
    }
    let mut username: Option<String> = None;
    let mut secret: Option<String> = None;
    let mut portal_user_auth_cookie: Option<String> = None;

    for pair in rest.split('&') {
        let Some((k, v)) = pair.split_once('=') else {
            continue;
        };
        let v = percent_decode(v)?;
        if v.is_empty() || v.contains(char::is_control) {
            return None;
        }
        let target = match k {
            "un" | "user" => &mut username,
            "token" | "prelogin-cookie" => &mut secret,
            "portal-userauthcookie" => &mut portal_user_auth_cookie,
            _ => continue,
        };
        if target.replace(v).is_some() {
            return None;
        }
    }

    Some(SamlCapture {
        username: username?,
        prelogin_cookie: secret?,
        portal_user_auth_cookie,
    })
}

fn parse_classic_cookie_callback(rest: &str) -> Option<SamlCapture> {
    let decoded = BASE64.decode(rest.as_bytes()).ok()?;
    let decoded = String::from_utf8(decoded).ok()?;

    Some(SamlCapture {
        username: extract_tag_text(&decoded, "saml-username")?,
        prelogin_cookie: extract_tag_text(&decoded, "prelogin-cookie")?,
        portal_user_auth_cookie: extract_tag_text(&decoded, "portal-userauthcookie"),
    })
}

fn extract_tag_text(doc: &str, tag: &str) -> Option<String> {
    let open = format!("<{tag}>");
    let close = format!("</{tag}>");
    let start = doc.find(&open)? + open.len();
    let end = doc[start..].find(&close)? + start;
    let value = doc[start..end].trim();
    if value.is_empty()
        || value.contains(char::is_control)
        || doc[end + close.len()..].contains(&open)
    {
        return None;
    }
    Some(value.to_string())
}

/// Minimal application/x-www-form-urlencoded decoder. Handles `%XX` and `+`.
fn percent_decode(s: &str) -> Option<String> {
    let bytes = s.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        match bytes[i] {
            b'+' => {
                out.push(b' ');
                i += 1;
            }
            b'%' if i + 2 < bytes.len() => {
                let hi = (bytes[i + 1] as char).to_digit(16);
                let lo = (bytes[i + 2] as char).to_digit(16);
                match (hi, lo) {
                    (Some(h), Some(l)) => {
                        out.push((h * 16 + l) as u8);
                        i += 3;
                    }
                    _ => return None,
                }
            }
            b'%' => return None,
            b => {
                out.push(b);
                i += 1;
            }
        }
    }
    String::from_utf8(out).ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_prisma_access_callback() {
        let uri = "globalprotectcallback:cas-as=1&un=alice%40example.com&token=aaa.bbb.ccc";
        let cap = parse_globalprotect_callback(uri).unwrap();
        assert_eq!(cap.username, "alice@example.com");
        assert_eq!(cap.prelogin_cookie, "aaa.bbb.ccc");
    }

    #[test]
    fn parse_classic_base64_callback() {
        // Synthetic. The blob this fixture replaced was lifted from a
        // public upstream bug report and still carried that reporter's
        // real (long-expired) prelogin-cookie next to a hand-blanked
        // username — a partial redaction is not a redaction. Shape and
        // element order are preserved exactly; only the values are
        // placeholders.
        let uri = concat!(
            "globalprotectcallback:",
            "PGh0bWw+PCEtLSA8c2FtbC1hdXRoLXN0YXR1cz4xPC9zYW1sLWF1dGgtc3RhdHVzPjxwcmVsb2dpbi1jb29raWU+",
            "QUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFB",
            "QUFBQT09PC9wcmVsb2dpbi1jb29raWU+PHNhbWwtdXNlcm5hbWU+YWxpY2VAZXhhbXBsZS5jb208L3NhbWwtdXNl",
            "cm5hbWU+PHNhbWwtc2xvPm5vPC9zYW1sLXNsbz48c2FtbC1TZXNzaW9uTm90T25PckFmdGVyPjwvc2FtbC1TZXNz",
            "aW9uTm90T25PckFmdGVyPiAtLT48L2h0bWw+"
        );
        let cap = parse_globalprotect_callback(uri).unwrap();
        assert_eq!(cap.username, "alice@example.com");
        assert_eq!(
            cap.prelogin_cookie,
            "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=="
        );
    }

    #[test]
    fn jwt_detection() {
        assert!(looks_like_jwt("aaa.bbb.ccc"));
        assert!(looks_like_jwt("eyJ0eXAi.eyJzdWIi.sig_value"));
        assert!(!looks_like_jwt("just-a-random-cookie"));
        assert!(!looks_like_jwt("aaa.bbb"));
        assert!(!looks_like_jwt(""));
    }
}
