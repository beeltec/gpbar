use gp_proto::{resource_mfa::ResourceMfaPolicy, xml::XmlNode};

fn policy(fields: &str) -> Option<ResourceMfaPolicy> {
    ResourceMfaPolicy::parse(
        &XmlNode::parse(&format!(
            "<policy><agent-config>{fields}</agent-config></policy>"
        ))
        .unwrap(),
    )
}

const FIELDS: &str = "<mfa-enabled>yes</mfa-enabled><mfa-trusted-host-list><member>mfa.example.com:6082</member></mfa-trusted-host-list>";

#[test]
fn resource_mfa_policy_is_explicit_and_bounded() {
    let accepted = policy(FIELDS).unwrap();
    assert_eq!(accepted.port, 4501);
    assert_eq!(accepted.hosts, ["mfa.example.com:6082"]);
    for fields in [
        "".into(),
        FIELDS.replace("yes", "no"),
        FIELDS.replace("yes", "true"),
        format!("{FIELDS}<mfa-enabled>yes</mfa-enabled>"),
        format!("{FIELDS}<mfa-listening-port>0</mfa-listening-port>"),
        format!("{FIELDS}<mfa-listening-port>65536</mfa-listening-port>"),
        format!("{FIELDS}<mfa-listening-port>bad</mfa-listening-port>"),
        format!("{FIELDS}<mfa-prompt-suppress-time>181</mfa-prompt-suppress-time>"),
        FIELDS.replace("<member>mfa.example.com:6082</member>", ""),
        FIELDS.replace(
            "<member>mfa.example.com:6082</member>",
            &"<member>mfa.example.com</member>".repeat(33),
        ),
    ] {
        assert!(policy(&fields).is_none());
    }
    assert_eq!(policy(&format!("{FIELDS}<mfa-listening-port>4510</mfa-listening-port><mfa-prompt-suppress-time>180</mfa-prompt-suppress-time>")).unwrap().port, 4510);
}
