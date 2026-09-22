//! Portal configuration response parsing.

use crate::credential::Credential;
use crate::error::ProtoError;
use crate::gateway::Gateway;
use crate::xml::XmlNode;

/// Configuration returned by the portal after authentication.
///
/// Parsed from the `/global-protect/getconfig.esp` response.
#[derive(Clone)]
pub struct PortalConfig {
    /// Portal hostname.
    pub portal: String,
    /// Authenticated username.
    pub username: String,
    /// Portal user-auth cookie.
    pub user_auth_cookie: String,
    /// Portal prelogon user-auth cookie.
    pub prelogon_user_auth_cookie: String,
    /// Available VPN gateways.
    pub gateways: Vec<Gateway>,
    /// Configuration digest (opaque hash).
    pub config_digest: Option<String>,
    pub cookie_lifetime_seconds: Option<u64>,
    pub kerberos_fallback: bool,
    pub resource_mfa: Option<crate::resource_mfa::ResourceMfaPolicy>,
}

impl PortalConfig {
    /// Parse from the XML body of `/global-protect/getconfig.esp`.
    pub fn parse(xml: &str, portal: &str, username: &str) -> Result<Self, ProtoError> {
        let root = XmlNode::parse(xml)?;

        // Use recursive search — real responses may nest these under
        // intermediate elements (e.g. <policy>).
        let user_auth_cookie = root
            .find_text("portal-userauthcookie")
            .unwrap_or("")
            .to_string();
        let prelogon_user_auth_cookie = root
            .find_text("portal-prelogonuserauthcookie")
            .unwrap_or("")
            .to_string();
        let config_digest = root.find_text("config-digest").map(|s| s.to_string());

        let mut gateways = root
            .find("gateways")
            .map(Gateway::parse_list)
            .unwrap_or_default();

        // Fallback: use the portal itself as a gateway.
        if gateways.is_empty() {
            gateways.push(Gateway {
                address: portal.to_string(),
                description: format!("{portal} (fallback)"),
                priority: 0,
                priority_rules: Vec::new(),
            });
        }

        Ok(Self {
            portal: portal.to_string(),
            username: username.to_string(),
            user_auth_cookie,
            prelogon_user_auth_cookie,
            gateways,
            config_digest,
            cookie_lifetime_seconds: cookie_lifetime_seconds(&root),
            kerberos_fallback: root.name == "policy" && unique_child(&root, "agent-config")
                .and_then(|agent| unique_child(agent, "krb-auth-fail-fallback"))
                .is_some_and(|field| field.children.is_empty() && field.text == "yes"),
            resource_mfa: crate::resource_mfa::ResourceMfaPolicy::parse(&root),
        })
    }

    /// Build a [`Credential::AuthCookie`] for gateway login.
    pub fn to_gateway_credential(&self) -> Credential {
        Credential::AuthCookie {
            username: self.username.clone(),
            user_auth_cookie: self.user_auth_cookie.clone(),
            prelogon_user_auth_cookie: self.prelogon_user_auth_cookie.clone(),
        }
    }

    /// Select the best gateway, preferring the given region.
    pub fn preferred_gateway(&self, region: Option<&str>) -> Option<&Gateway> {
        if self.gateways.is_empty() {
            return None;
        }
        if let Some(region) = region {
            let mut sorted: Vec<_> = self.gateways.iter().collect();
            sorted.sort_by_key(|g| g.priority_for_region(region));
            Some(sorted[0])
        } else {
            self.gateways.iter().min_by_key(|g| g.priority)
        }
    }
}

fn cookie_lifetime_seconds(root: &XmlNode) -> Option<u64> {
    if root.name != "policy" {
        return None;
    }
    let policy = unique_child(root, "authentication-override")?;
    let agent = unique_child(root, "agent-config")?;
    let saved_credentials = unique_child(agent, "save-user-credentials")?;
    let accept = unique_child(policy, "accept-cookie")?;
    let generate = unique_child(policy, "generate-cookie")?;
    if !matches!(saved_credentials.text.as_str(), "1" | "2")
        || !saved_credentials.children.is_empty()
        || accept.text != "yes"
        || !accept.children.is_empty()
        || generate.text != "yes"
        || !generate.children.is_empty()
    {
        return None;
    }
    let lifetime = unique_child(policy, "cookie-lifetime")?;
    if lifetime.children.len() != 1 || !lifetime.text.is_empty() {
        return None;
    }
    let value = &lifetime.children[0];
    if !value.children.is_empty() || !value.text.bytes().all(|byte| byte.is_ascii_digit()) {
        return None;
    }
    let (unit, maximum) = match value.name.as_str() {
        "lifetime-in-minutes" => (60, 59),
        "lifetime-in-hours" => (3600, 72),
        "lifetime-in-days" => (86400, 365),
        _ => return None,
    };
    let count = value.text.parse::<u64>().ok()?;
    (1..=maximum).contains(&count).then(|| count * unit)
}

fn unique_child<'a>(parent: &'a XmlNode, name: &str) -> Option<&'a XmlNode> {
    let mut children = parent.children.iter().filter(|child| child.name == name);
    let child = children.next()?;
    if children.next().is_some() {
        return None;
    }
    Some(child)
}

impl std::fmt::Debug for PortalConfig {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("PortalConfig")
            .field("portal", &self.portal)
            .field("username", &self.username)
            .field("user_auth_cookie", &"[REDACTED]")
            .field("prelogon_user_auth_cookie", &"[REDACTED]")
            .field("gateways", &self.gateways)
            .field("config_digest", &self.config_digest)
            .field("cookie_lifetime_seconds", &self.cookie_lifetime_seconds)
            .finish()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_portal_config() {
        let xml = r#"
        <response>
            <portal-userauthcookie>COOKIE1</portal-userauthcookie>
            <portal-prelogonuserauthcookie>COOKIE2</portal-prelogonuserauthcookie>
            <config-digest>abc123</config-digest>
            <gateways>
                <external>
                    <list>
                        <entry name="gw.example.com">
                            <description>Main GW</description>
                            <priority-rule>
                                <entry name="Any"><priority>10</priority></entry>
                            </priority-rule>
                        </entry>
                    </list>
                </external>
            </gateways>
        </response>"#;

        let config = PortalConfig::parse(xml, "portal.example.com", "alice").unwrap();
        assert_eq!(config.user_auth_cookie, "COOKIE1");
        assert_eq!(config.prelogon_user_auth_cookie, "COOKIE2");
        assert_eq!(config.gateways.len(), 1);
        assert_eq!(config.gateways[0].address, "gw.example.com");
        assert_eq!(config.config_digest.as_deref(), Some("abc123"));
    }

    #[test]
    fn fallback_gateway() {
        let xml = r#"<response></response>"#;
        let config = PortalConfig::parse(xml, "portal.example.com", "alice").unwrap();
        assert_eq!(config.gateways.len(), 1);
        assert_eq!(config.gateways[0].address, "portal.example.com");
    }
}
