use gp_ipc::app::{RetainedCookie, SavedAuthentication};
use gp_proto::Credential;

use super::{normalize_portal, SystemTime, UNIX_EPOCH};

#[derive(Debug)]
pub struct Expired;

impl std::fmt::Display for Expired {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str("saved authentication expired")
    }
}

impl std::error::Error for Expired {}

pub fn check_credential(
    credential: &Credential,
    saved: Option<&SavedAuthentication>,
) -> Result<(), Expired> {
    if let Credential::AuthCookie {
        user_auth_cookie, ..
    } = credential
    {
        if previous(saved, user_auth_cookie).is_some_and(|cookie| !current(cookie)) {
            return Err(Expired);
        }
    }
    Ok(())
}

pub fn now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|time| time.as_secs())
        .unwrap_or(0)
}

pub fn valid(saved: &SavedAuthentication, portal: &str, computer: &str) -> bool {
    saved.portal == portal
        && normalize_portal(portal).is_ok_and(|normalized| normalized == portal)
        && saved.computer == computer
        && !saved.username.is_empty()
        && saved.username.len() <= 1024
        && !saved.username.contains(char::is_control)
        && saved.computer.len() <= 256
        && !saved.computer.is_empty()
        && !saved.computer.contains(char::is_control)
        && (saved.portal_cookie.is_some() || saved.gateway_cookie.is_some())
        && saved.portal_cookie.as_ref().is_none_or(|cookie| {
            cookie.server == portal && cookie.username == saved.username && valid_cookie(cookie)
        })
        && saved.gateway_cookie.as_ref().is_none_or(valid_cookie)
}

fn valid_cookie(cookie: &RetainedCookie) -> bool {
    normalize_portal(&cookie.server).is_ok_and(|server| server == cookie.server)
        && !cookie.username.is_empty()
        && cookie.username.len() <= 1024
        && !cookie.username.contains(char::is_control)
        && valid_value(&cookie.value)
        && cookie.expires_at > cookie.issued_at
        && cookie.expires_at - cookie.issued_at <= 365 * 86400
}

fn valid_value(value: &str) -> bool {
    !value.is_empty()
        && value != "empty"
        && value != "(null)"
        && value.len() <= 16384
        && !value.contains(char::is_control)
}

pub fn current(cookie: &RetainedCookie) -> bool {
    let now = now();
    valid_cookie(cookie) && cookie.issued_at <= now && now < cookie.expires_at
}

pub fn retain(
    server: &str,
    username: &str,
    value: &str,
    lifetime: u64,
    previous: Option<&RetainedCookie>,
) -> Option<RetainedCookie> {
    if !valid_value(value) || !(1..=365 * 86400).contains(&lifetime) {
        return None;
    }
    let now = now();
    let previous = previous.filter(|old| old.value == value);
    let issued_at = previous.map_or(now, |old| old.issued_at);
    let expires_at = issued_at.checked_add(lifetime)?;
    let expires_at = previous.map_or(expires_at, |old| old.expires_at.min(expires_at));
    let cookie = RetainedCookie {
        server: server.into(),
        username: username.into(),
        value: value.into(),
        issued_at,
        expires_at,
    };
    current(&cookie).then_some(cookie)
}

pub fn previous<'a>(
    saved: Option<&'a SavedAuthentication>,
    value: &str,
) -> Option<&'a RetainedCookie> {
    let saved = saved?;
    [saved.portal_cookie.as_ref(), saved.gateway_cookie.as_ref()]
        .into_iter()
        .flatten()
        .filter(|cookie| cookie.value == value)
        .min_by_key(|cookie| cookie.expires_at)
}

pub fn credential(cookie: &RetainedCookie) -> Credential {
    Credential::AuthCookie {
        username: cookie.username.clone(),
        user_auth_cookie: cookie.value.clone(),
        prelogon_user_auth_cookie: String::new(),
    }
}
