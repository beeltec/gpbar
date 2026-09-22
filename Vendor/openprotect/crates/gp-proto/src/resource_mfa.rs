use crate::xml::XmlNode;

#[derive(Clone, Debug)]
pub struct ResourceMfaPolicy {
    pub port: u16,
    pub hosts: Vec<String>,
    pub message: String,
    pub suppression_seconds: u64,
}

impl ResourceMfaPolicy {
    pub fn parse(root: &XmlNode) -> Option<Self> {
        if root.name != "policy" {
            return None;
        }
        let agent = unique(root, "agent-config")?;
        if scalar(agent, "mfa-enabled")? != "yes" {
            return None;
        }
        let port = match unique_optional(agent, "mfa-listening-port")? {
            Some(node) => number(node, 65535)? as u16,
            None => 4501,
        };
        if port == 0 {
            return None;
        }
        let list = unique(agent, "mfa-trusted-host-list")?;
        if !list.text.is_empty() || list.children.is_empty() || list.children.len() > 32 {
            return None;
        }
        let mut hosts = Vec::new();
        for member in &list.children {
            if member.name != "member"
                || !member.children.is_empty()
                || member.text.is_empty()
                || member.text.len() > 253
            {
                return None;
            }
            hosts.push(member.text.clone());
        }
        let message = match unique_optional(agent, "mfa-notification-msg")? {
            Some(node) if node.children.is_empty() && node.text.len() <= 2048 => node.text.clone(),
            Some(_) => return None,
            None => String::new(),
        };
        let suppression_seconds = match unique_optional(agent, "mfa-prompt-suppress-time")? {
            Some(node) => number(node, 180)?,
            None => 0,
        };
        Some(Self {
            port,
            hosts,
            message,
            suppression_seconds,
        })
    }
}

fn unique_optional<'a>(parent: &'a XmlNode, name: &str) -> Option<Option<&'a XmlNode>> {
    let mut children = parent.children.iter().filter(|child| child.name == name);
    let first = children.next();
    if children.next().is_some() {
        None
    } else {
        Some(first)
    }
}

fn unique<'a>(parent: &'a XmlNode, name: &str) -> Option<&'a XmlNode> {
    unique_optional(parent, name)?
}

fn scalar<'a>(parent: &'a XmlNode, name: &str) -> Option<&'a str> {
    let node = unique(parent, name)?;
    node.children.is_empty().then_some(node.text.as_str())
}

fn number(node: &XmlNode, maximum: u64) -> Option<u64> {
    if !node.children.is_empty()
        || node.text.is_empty()
        || !node.text.bytes().all(|byte| byte.is_ascii_digit())
    {
        return None;
    }
    node.text
        .parse::<u64>()
        .ok()
        .filter(|value| *value <= maximum)
}
