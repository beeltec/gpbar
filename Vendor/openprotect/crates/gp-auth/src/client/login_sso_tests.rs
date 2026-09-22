use super::*;

#[tokio::test]
#[ignore = "requires scripts/test-login-sso.sh HTTPS fixture"]
async fn login_sso_https_password_and_mfa_exchange() {
    let origin = std::env::var("GPBAR_LOGIN_SSO_TEST_ORIGIN").unwrap();
    let pem = std::fs::read(std::env::var("GPBAR_LOGIN_SSO_TEST_CERT").unwrap()).unwrap();
    let params = GpParams::new(ClientOs::Mac);
    assert!(GpBar::new_for_app(params.clone())
        .unwrap()
        .prelogin(&origin)
        .await
        .is_err());
    let mut client = GpBar {
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
    assert!(matches!(
        client.prelogin(&origin).await.unwrap(),
        PreloginResponse::Standard(_)
    ));
    let credential = Credential::Password {
        username: "fixture-user".into(),
        password: "fixture+password&=".into(),
    };
    let challenge = client
        .portal_login_for_app(&origin, &credential)
        .await
        .unwrap();
    let PortalLoginResult::Challenge { input_str, .. } = challenge else {
        panic!("MFA challenge expected")
    };
    client.gp_params.input_str = Some(input_str);
    client.gp_params.otp = Some("123456".into());
    assert!(matches!(
        client
            .portal_login_for_app(&origin, &credential)
            .await
            .unwrap(),
        PortalLoginResult::Success(_)
    ));
    client.gp_params.input_str = None;
    client.gp_params.otp = None;
    let wrong = Credential::Password {
        username: "fixture-user".into(),
        password: "wrong".into(),
    };
    assert!(client.portal_login_for_app(&origin, &wrong).await.is_err());
}
