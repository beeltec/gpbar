use super::{challenge_id, prompt};
use anyhow::{bail, Context, Result};
use gp_ipc::app::Event;
use gp_proto::resource_mfa::ResourceMfaPolicy;
use std::collections::HashSet;
use std::net::{Ipv4Addr, SocketAddrV4};
use std::os::fd::AsRawFd;
use std::sync::{Arc, RwLock};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};
use tokio::net::UdpSocket;
use url::Url;

pub enum Notice {
    Required {
        challenge_id: String,
        launch_url: String,
        message: String,
        expires_at_unix: u64,
    },
    Cleared,
    Unavailable,
}

impl Notice {
    pub fn event(&self) -> Event<'_> {
        match self {
            Self::Required {
                challenge_id,
                launch_url,
                message,
                expires_at_unix,
            } => Event::ResourceAuthenticationRequired {
                challenge_id,
                launch_url,
                message,
                expires_at_unix: *expires_at_unix,
            },
            Self::Cleared => Event::ResourceAuthenticationCleared,
            Self::Unavailable => Event::ResourceAuthenticationUnavailable,
        }
    }
}

const MAX_PACKET: usize = 2048;
const PROMPT_LIFETIME: Duration = Duration::from_secs(120);

struct TrustedHost {
    origin: url::Origin,
    addresses: HashSet<Ipv4Addr>,
}

fn authentication_url(value: &str) -> Option<Url> {
    if value.len() > MAX_PACKET
        || !value.is_ascii()
        || value
            .bytes()
            .any(|byte| byte <= 32 || byte == 127 || byte == b'\\')
    {
        return None;
    }
    let url = Url::parse(value).ok()?;
    if url.scheme() != "https"
        || url.host_str().is_none()
        || !url.username().is_empty()
        || url.password().is_some()
        || url.fragment().is_some()
        || url.port() == Some(0)
        || !matches!(url.path(), "/php/uid.php" | "/php/browser_challenge.php")
    {
        return None;
    }
    if url.query()?.split('&').count() != 2 {
        return None;
    }
    let mut keys = HashSet::new();
    for (key, value) in url.query_pairs() {
        if !matches!(key.as_ref(), "vsys" | "rule")
            || !keys.insert(key.into_owned())
            || value.is_empty()
            || value.len() > 10
            || !value.bytes().all(|b| b.is_ascii_digit())
        {
            return None;
        }
    }
    (keys.len() == 2).then_some(url)
}

fn notification(packet: &[u8]) -> Option<Url> {
    if packet.is_empty() || packet.len() > MAX_PACKET {
        return None;
    }
    let mut remaining = packet;
    let mut result = None;
    let mut count = 0;
    while !remaining.is_empty() {
        if remaining.len() < 3 || count == 16 {
            return None;
        }
        count += 1;
        let kind = remaining[0];
        let length = u16::from_be_bytes([remaining[1], remaining[2]]) as usize;
        let value = remaining.get(3..3 + length)?;
        if kind == 3 {
            if result.is_some() {
                return None;
            }
            result = Some(authentication_url(std::str::from_utf8(value).ok()?)?);
        }
        remaining = &remaining[3 + length..];
    }
    result
}

async fn trusted_hosts(policy: &ResourceMfaPolicy) -> Result<Vec<TrustedHost>> {
    let mut hosts = Vec::new();
    for host in &policy.hosts {
        if !host.is_ascii() || host.contains(['/', '@', '%', '?', '#', '\\']) {
            bail!("invalid resource authentication host");
        }
        let origin = super::normalize_portal(&format!("https://{host}"))?;
        let url = Url::parse(&origin)?;
        let name = url.host_str().context("missing host")?;
        let addresses: HashSet<_> =
            tokio::net::lookup_host((name, url.port_or_known_default().unwrap_or(443)))
                .await?
                .filter_map(|address| match address.ip() {
                    std::net::IpAddr::V4(ip)
                        if !ip.is_loopback()
                            && !ip.is_unspecified()
                            && !ip.is_multicast()
                            && !ip.is_broadcast() =>
                    {
                        Some(ip)
                    }
                    _ => None,
                })
                .take(32)
                .collect();
        if addresses.is_empty() {
            bail!("resource authentication host unavailable");
        }
        hosts.push(TrustedHost {
            origin: url.origin(),
            addresses,
        });
    }
    Ok(hosts)
}

fn trusted(url: &Url, source: Ipv4Addr, hosts: &[TrustedHost]) -> bool {
    hosts
        .iter()
        .any(|host| host.origin == url.origin() && host.addresses.contains(&source))
}

fn socket(address: Ipv4Addr, port: u16, interface: &str) -> Result<(UdpSocket, u32)> {
    let name = std::ffi::CString::new(interface)?;
    // The C string remains valid for this call.
    let index = unsafe { libc::if_nametoindex(name.as_ptr()) };
    if index == 0 {
        bail!("resource authentication interface unavailable");
    }
    let socket = std::net::UdpSocket::bind(SocketAddrV4::new(address, port))?;
    socket.set_nonblocking(true)?;
    let enabled: libc::c_int = 1;
    // Both options copy their values. The socket owns the descriptor throughout these calls.
    let configured = unsafe {
        libc::setsockopt(
            socket.as_raw_fd(),
            libc::IPPROTO_IP,
            libc::IP_BOUND_IF,
            (&index as *const u32).cast(),
            std::mem::size_of_val(&index) as libc::socklen_t,
        ) == 0
            && libc::setsockopt(
                socket.as_raw_fd(),
                libc::IPPROTO_IP,
                libc::IP_PKTINFO,
                (&enabled as *const libc::c_int).cast(),
                std::mem::size_of_val(&enabled) as libc::socklen_t,
            ) == 0
    };
    if !configured {
        return Err(std::io::Error::last_os_error().into());
    }
    Ok((UdpSocket::from_std(socket)?, index))
}

fn receive(
    socket: &UdpSocket,
    packet: &mut [u8],
    index: u32,
    address: Ipv4Addr,
) -> std::io::Result<Option<(usize, Ipv4Addr)>> {
    // All buffers remain valid until recvmsg returns. Ancillary storage has native alignment.
    unsafe {
        let mut source: libc::sockaddr_in = std::mem::zeroed();
        let mut control = [0usize; 32];
        let mut vector = libc::iovec {
            iov_base: packet.as_mut_ptr().cast(),
            iov_len: packet.len(),
        };
        let mut message: libc::msghdr = std::mem::zeroed();
        message.msg_name = (&mut source as *mut libc::sockaddr_in).cast();
        message.msg_namelen = std::mem::size_of_val(&source) as libc::socklen_t;
        message.msg_iov = &mut vector;
        message.msg_iovlen = 1;
        message.msg_control = control.as_mut_ptr().cast();
        message.msg_controllen = std::mem::size_of_val(&control) as libc::socklen_t;
        let length = libc::recvmsg(socket.as_raw_fd(), &mut message, 0);
        if length < 0 {
            return Err(std::io::Error::last_os_error());
        }
        if message.msg_flags & (libc::MSG_TRUNC | libc::MSG_CTRUNC) != 0
            || source.sin_family as i32 != libc::AF_INET
        {
            return Ok(None);
        }
        let mut header = libc::CMSG_FIRSTHDR(&message);
        while !header.is_null() {
            if (*header).cmsg_level == libc::IPPROTO_IP
                && (*header).cmsg_type == libc::IP_PKTINFO
                && (*header).cmsg_len as usize
                    >= libc::CMSG_LEN(std::mem::size_of::<libc::in_pktinfo>() as u32) as usize
            {
                let info =
                    std::ptr::read_unaligned(libc::CMSG_DATA(header).cast::<libc::in_pktinfo>());
                if info.ipi_ifindex == index
                    && Ipv4Addr::from(info.ipi_addr.s_addr.to_ne_bytes()) == address
                {
                    return Ok(Some((
                        length as usize,
                        Ipv4Addr::from(source.sin_addr.s_addr.to_ne_bytes()),
                    )));
                }
            }
            header = libc::CMSG_NXTHDR(&message, header);
        }
        Ok(None)
    }
}

pub async fn run(
    policy: ResourceMfaPolicy,
    interface: String,
    address: String,
    base: Arc<RwLock<gp_ipc::StateSnapshotBase>>,
    notices: tokio::sync::mpsc::Sender<Notice>,
    mut stop: tokio::sync::watch::Receiver<bool>,
) {
    let result = tokio::select! {
        biased;
        _ = stop.wait_for(|value| *value) => return,
        result = listen(policy, interface, address, base, &notices) => result,
    };
    if result.is_err() {
        let _ = notices.send(Notice::Unavailable).await;
    }
}

async fn listen(
    policy: ResourceMfaPolicy,
    interface: String,
    address: String,
    base: Arc<RwLock<gp_ipc::StateSnapshotBase>>,
    notices: &tokio::sync::mpsc::Sender<Notice>,
) -> Result<()> {
    if !interface.starts_with("utun") {
        bail!("resource authentication requires a tunnel");
    }
    let address: Ipv4Addr = address.parse()?;
    let (socket, index) = socket(address, policy.port, &interface)?;
    let hosts = tokio::time::timeout(Duration::from_secs(10), trusted_hosts(&policy)).await??;
    let message = prompt(
        &policy.message,
        "A protected resource needs additional sign-in.",
    );
    let mut packet = [0u8; MAX_PACKET + 1];
    let mut expires: Option<Instant> = None;
    let mut next_prompt = Instant::now();
    let mut timer = tokio::time::interval(Duration::from_millis(250));
    loop {
        tokio::select! {
            biased;
            _ = timer.tick() => {
                if expires.is_some_and(|deadline| Instant::now() >= deadline) {
                    expires = None;
                    notices.send(Notice::Cleared).await.map_err(|_| anyhow::anyhow!("resource notification receiver closed"))?;
                }
            }
            result = socket.readable() => {
                result?;
                let received = socket.try_io(tokio::io::Interest::READABLE, || receive(&socket, &mut packet, index, address));
                let (length, source) = match received {
                    Ok(Some(value)) => value,
                    Ok(None) => continue,
                    Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => continue,
                    Err(error) => return Err(error.into()),
                };
                if Instant::now() < next_prompt { continue; }
                let active = base.read().ok().is_some_and(|state| state.state == gp_ipc::SessionState::Connected
                    && state.tun_ifname.as_deref() == Some(&interface)
                    && state.local_ipv4.as_deref() == Some(&address.to_string()));
                if !active { return Ok(()); }
                let Some(url) = notification(&packet[..length]) else { continue; };
                if !trusted(&url, source, &hosts) { continue; }
                let id = challenge_id()?;
                let deadline = SystemTime::now().duration_since(UNIX_EPOCH)?.as_secs() + PROMPT_LIFETIME.as_secs();
                expires = Some(Instant::now() + PROMPT_LIFETIME);
                next_prompt = Instant::now() + PROMPT_LIFETIME.max(Duration::from_secs(policy.suppression_seconds));
                notices.send(Notice::Required {
                    challenge_id: id, launch_url: url.into(), message: message.clone(), expires_at_unix: deadline,
                }).await.map_err(|_| anyhow::anyhow!("resource notification receiver closed"))?;
            }
        }
        let active = base
            .read()
            .ok()
            .is_some_and(|state| state.state == gp_ipc::SessionState::Connected);
        if !active {
            return Ok(());
        }
    }
}

#[cfg(test)]
#[path = "resource_mfa_tests.rs"]
mod tests;
