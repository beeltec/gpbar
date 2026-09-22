use super::*;
use crate::saml_common::{parse_cas_callback, parse_globalprotect_callback};
use crate::saml_paste::build_app_launch_body;
use base64::Engine;

const CALLBACK: &str =
    "globalprotectcallback:cas-as=1&un=alice%40example.com&token=fixture%2Bopaque%2Ftoken%3D%3D";

fn prelogin(extra: &str) -> String {
    format!("<prelogin-response><status>Success</status>{extra}</prelogin-response>")
}

#[test]
fn cie_prelogin_requires_an_unambiguous_browser_handoff() {
    for fields in [
        "<cas-auth>yes</cas-auth>",
        "<cas-auth>maybe</cas-auth>",
        "<cas-auth>yes</cas-auth><cas-auth>no</cas-auth>",
        "<cas-auth><child>yes</child></cas-auth>",
        "<cas-auth>yes</cas-auth><saml-auth-method>POST</saml-auth-method>",
        "<cas-auth>yes</cas-auth><saml-auth-method>POST</saml-auth-method><saml-request>aA==</saml-request><saml-request>aA==</saml-request>",
    ] {
        assert!(PreloginResponse::parse(&prelogin(fields)).is_err());
    }
    assert!(matches!(
        PreloginResponse::parse(&prelogin("<cas-auth>no</cas-auth>")).unwrap(),
        PreloginResponse::Standard(_)
    ));
}

#[test]
fn cie_preserves_the_server_request_and_https_redirect() {
    for (method, value) in [
        ("POST", "<form method=\"post\" action=\"https://cie.example/authorize\"><input name=\"request\" value=\"opaque+signed/request==\"></form>"),
        ("REDIRECT", "https://cie.example/authorize?request=opaque%2Bsigned&state=original"),
    ] {
        let encoded = base64::engine::general_purpose::STANDARD.encode(value);
        let PreloginResponse::Saml(saml) = PreloginResponse::parse(&prelogin(&format!(
            "<cas-auth>yes</cas-auth><saml-auth-method>{method}</saml-auth-method><saml-request>{encoded}</saml-request>"
        ))).unwrap() else { panic!("expected browser handoff") };
        assert!(saml.is_cas);
        let body = String::from_utf8(build_app_launch_body(&saml).unwrap()).unwrap();
        if method == "POST" { assert_eq!(body, value); }
        else { assert!(body.contains("request=opaque%2Bsigned&amp;state=original")); }
    }
    for value in [
        "http://cie.example",
        "https://user:secret@cie.example",
        "javascript:alert(1)",
    ] {
        let saml = gp_proto::prelogin::SamlPrelogin {
            region: String::new(),
            is_cas: true,
            saml_auth_method: "REDIRECT".into(),
            saml_request: base64::engine::general_purpose::STANDARD.encode(value),
        };
        assert!(build_app_launch_body(&saml).is_err());
    }
}

#[test]
fn cie_callback_status_encoding_and_bounds() {
    let credential = parse_cas_callback(CALLBACK).unwrap();
    let params = credential.to_params();
    assert!(params.contains(&("token", "fixture+opaque/token==".into())));
    assert!(params.contains(&("prelogin-cookie", String::new())));
    assert!(!format!("{credential:?}").contains("fixture+opaque"));
    for value in [
        CALLBACK.replace("cas-as=1", "cas-as=-1"),
        CALLBACK.replace("cas-as=1", "cas-as=0"),
        CALLBACK.replace("cas-as=1&", ""),
        CALLBACK.replace("un=", "user="),
        CALLBACK.replace("token=", "prelogin-cookie="),
        format!("{CALLBACK}#fragment"),
        format!("{CALLBACK} "),
        format!("{CALLBACK}&token=second"),
        format!("{CALLBACK}&cas-as=1"),
        format!("{CALLBACK}&un=second"),
        format!("{CALLBACK}&prelogin-cookie=second"),
        format!("{CALLBACK}&token"),
        CALLBACK.replace("alice%40example.com", "%FF"),
        CALLBACK.replace("alice%40example.com", "%0A"),
        CALLBACK.replace("alice%40example.com", "%"),
        CALLBACK.replace("alice%40example.com", ""),
        CALLBACK.replace("alice%40example.com", &"a".repeat(1025)),
        CALLBACK.replace("fixture%2Bopaque%2Ftoken%3D%3D", &"a".repeat(131073)),
    ] {
        assert!(
            parse_cas_callback(&value).is_none(),
            "accepted invalid CAS callback"
        );
    }
    assert!(parse_globalprotect_callback(&CALLBACK.replace("cas-as=1", "cas-as=-1")).is_none());
    assert!(parse_globalprotect_callback(
        "globalprotectcallback:user=alice&prelogin-cookie=classic"
    )
    .is_some());
}

#[tokio::test]
#[ignore = "requires scripts/test-cie-oidc.sh HTTPS fixture"]
async fn cie_https_exchange_uses_existing_portal_and_gateway_requests() {
    let origin = std::env::var("GPBAR_CIE_TEST_ORIGIN").expect("run scripts/test-cie-oidc.sh");
    let pem = std::fs::read(std::env::var("GPBAR_CIE_TEST_CERT").unwrap()).unwrap();
    let params = GpParams::new(ClientOs::Mac);
    assert!(
        GpBar::new_for_app(params.clone())
            .unwrap()
            .prelogin(&origin)
            .await
            .is_err(),
        "production trust accepted the fixture certificate"
    );
    // Trust the fixture only in this test client. Production trust stays unchanged.
    let client = GpBar {
        http: reqwest::Client::builder()
            .no_proxy()
            .redirect(reqwest::redirect::Policy::none())
            .timeout(std::time::Duration::from_secs(5))
            .add_root_certificate(reqwest::Certificate::from_pem(&pem).unwrap())
            .build()
            .unwrap(),
        bounded_responses: true,
        gp_params: params,
    };
    let PreloginResponse::Saml(saml) = client.prelogin(&origin).await.unwrap() else {
        panic!("expected CAS")
    };
    assert!(saml.is_cas);
    let credential = parse_cas_callback(CALLBACK).unwrap();
    assert!(matches!(
        client
            .portal_login_for_app(&origin, &credential)
            .await
            .unwrap(),
        PortalLoginResult::Success(_)
    ));
    assert!(matches!(
        client.gateway_login(&origin, &credential).await.unwrap(),
        GatewayLoginResult::Success(_)
    ));
    let rejected =
        parse_cas_callback(&CALLBACK.replace("fixture%2Bopaque%2Ftoken%3D%3D", "wrong-token"))
            .unwrap();
    assert!(client
        .portal_login_for_app(&origin, &rejected)
        .await
        .is_err());
}
