use super::*;

fn packet(url: &str) -> Vec<u8> {
    let mut packet = vec![1, 0, 1, 1, 2, 0, 4, b'M', b'F', b'A', b'G', 3];
    packet.extend_from_slice(&(url.len() as u16).to_be_bytes());
    packet.extend_from_slice(url.as_bytes());
    packet
}

const URL: &str = "https://mfa.example.com:6082/php/uid.php?vsys=1&rule=0";

#[test]
fn resource_mfa_binary_notification() {
    assert_eq!(notification(&packet(URL)).unwrap().as_str(), URL);
    assert!(notification(URL.as_bytes()).is_none());
    let bytes = packet(URL);
    for end in 0..bytes.len() {
        assert!(notification(&bytes[..end]).is_none());
    }
    let mut duplicate = bytes.clone();
    duplicate.extend_from_slice(&bytes);
    assert!(notification(&duplicate).is_none());
    let mut trailing = bytes;
    trailing.push(0);
    assert!(notification(&trailing).is_none());
    assert!(notification(&vec![0; MAX_PACKET + 1]).is_none());
    assert!(notification(&[3, 255, 255, 0]).is_none());
}

#[test]
fn resource_mfa_rejects_unsafe_targets() {
    for url in [
        URL.replace("https:", "http:"),
        URL.replace("https:", "file:"),
        URL.replace("mfa.example.com", "user:secret@mfa.example.com"),
        format!("{URL}#fragment"),
        format!("{URL}&"),
        URL.replace("&rule", "&&rule"),
        format!("{URL}&rule=1"),
        format!("{URL}&next=https://evil.example"),
        URL.replace("uid.php", "other.php"),
        URL.replace("vsys=1", "vsys=bad"),
        URL.replace("&rule=0", ""),
        URL.replace("6082", "0"),
        URL.replace("vsys=1", "vsys=%0a"),
        format!("{URL}\0"),
        format!("{URL}\n"),
        URL.replace("mfa.example.com", "mfa.example.com\\evil"),
    ] {
        assert!(notification(&packet(&url)).is_none(), "accepted unsafe URL");
    }
}

#[test]
fn resource_mfa_requires_matching_source_and_exact_origin() {
    let source = Ipv4Addr::new(192, 0, 2, 5);
    let hosts = vec![TrustedHost {
        origin: Url::parse(URL).unwrap().origin(),
        addresses: HashSet::from([source]),
    }];
    assert!(trusted(
        &notification(&packet(URL)).unwrap(),
        source,
        &hosts
    ));
    assert!(!trusted(
        &notification(&packet(URL)).unwrap(),
        Ipv4Addr::new(192, 0, 2, 6),
        &hosts
    ));
    for url in [
        URL.replace("6082", "443"),
        URL.replace("mfa.example.com", "mfa.example.com.evil"),
        URL.replace("mfa.example.com", "other.example.com"),
    ] {
        assert!(!trusted(
            &notification(&packet(&url)).unwrap(),
            source,
            &hosts
        ));
    }
}

#[tokio::test]
async fn resource_mfa_socket_checks_ingress_and_truncation() {
    let (receiver, index) = socket(Ipv4Addr::LOCALHOST, 0, "lo0").unwrap();
    let sender = UdpSocket::bind("127.0.0.1:0").await.unwrap();
    let mut buffer = [0u8; MAX_PACKET + 1];
    for (bytes, expected_index, accepted) in [
        (packet(URL), index, true),
        (packet(URL), index + 1, false),
        (vec![0; MAX_PACKET + 2], index, false),
    ] {
        sender
            .send_to(&bytes, receiver.local_addr().unwrap())
            .await
            .unwrap();
        let result = tokio::time::timeout(Duration::from_secs(2), async {
            loop {
                receiver.readable().await.unwrap();
                match receiver.try_io(tokio::io::Interest::READABLE, || {
                    receive(&receiver, &mut buffer, expected_index, Ipv4Addr::LOCALHOST)
                }) {
                    Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => continue,
                    result => break result.unwrap(),
                }
            }
        })
        .await
        .unwrap();
        assert_eq!(result.is_some(), accepted);
    }
    let address = receiver.local_addr().unwrap();
    drop(receiver);
    let _rebound = UdpSocket::bind(address).await.unwrap();
}

#[tokio::test]
async fn resource_mfa_cancellation_preserves_event_framing() {
    use super::super::Output;
    use gp_ipc::app::AppSnapshot;
    use tokio::io::{AsyncBufReadExt, BufReader};
    let (pipe, reader) = tokio::net::unix::pipe::pipe().unwrap();
    let mut output = Output {
        pipe,
        sequence: 0,
        session_id: "test-session".into(),
        snapshot: AppSnapshot::default(),
        failure_reported: false,
    };
    let base = Arc::new(RwLock::new(gp_ipc::StateSnapshotBase {
        instance: "test-session".into(),
        portal: "https://vpn.example.com".into(),
        gateway: "vpn.example.com".into(),
        user: String::new(),
        reported_os: "mac".into(),
        routes: Vec::new(),
        started_at_unix: 0,
        tun_ifname: None,
        local_ipv4: None,
        state: gp_ipc::SessionState::Connecting,
    }));
    let (_stop, stop_rx) = tokio::sync::watch::channel(false);
    let (sender, mut receiver) = tokio::sync::mpsc::channel(1);
    assert!(sender.send(Notice::Unavailable).await.is_ok());
    let mut tasks = tokio::task::JoinSet::new();
    tasks.spawn(run(
        ResourceMfaPolicy {
            port: 4501,
            hosts: Vec::new(),
            message: String::new(),
            suppression_seconds: 0,
        },
        "lo0".into(),
        "127.0.0.1".into(),
        base,
        sender,
        stop_rx,
    ));
    tokio::task::yield_now().await;
    tokio::time::timeout(Duration::from_secs(1), tasks.shutdown())
        .await
        .unwrap();
    output
        .send(receiver.recv().await.unwrap().event())
        .await
        .unwrap();
    output.send(Notice::Cleared.event()).await.unwrap();
    assert!(receiver.recv().await.is_none());
    let mut lines = BufReader::new(reader).lines();
    for sequence in 1..=2 {
        let line = tokio::time::timeout(Duration::from_secs(1), lines.next_line())
            .await
            .unwrap()
            .unwrap()
            .unwrap();
        let frame: serde_json::Value = serde_json::from_str(&line).unwrap();
        assert_eq!(frame["sequence"], sequence);
    }
}
