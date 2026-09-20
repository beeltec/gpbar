use std::sync::Arc;

use gp_proto::identity::ClientIdentity;
use rustls::pki_types::CertificateDer;
use rustls::sign::{CertifiedKey, Signer, SigningKey, SingleCertAndKey};
use rustls::{ClientConfig, RootCertStore, SignatureAlgorithm, SignatureScheme};

use crate::AuthError;

#[derive(Debug)]
struct IdentityKey(Arc<ClientIdentity>);

impl SigningKey for IdentityKey {
    fn choose_scheme(&self, offered: &[SignatureScheme]) -> Option<Box<dyn Signer>> {
        offered
            .iter()
            .copied()
            .find(|scheme| self.0.supports(u16::from(*scheme)))
            .map(|scheme| {
                Box::new(IdentitySignature {
                    identity: self.0.clone(),
                    scheme,
                }) as Box<dyn Signer>
            })
    }

    fn algorithm(&self) -> SignatureAlgorithm {
        if self.0.supports(0x0403) || self.0.supports(0x0503) || self.0.supports(0x0603) {
            SignatureAlgorithm::ECDSA
        } else {
            SignatureAlgorithm::RSA
        }
    }
}

#[derive(Debug)]
struct IdentitySignature {
    identity: Arc<ClientIdentity>,
    scheme: SignatureScheme,
}

impl Signer for IdentitySignature {
    fn sign(&self, message: &[u8]) -> Result<Vec<u8>, rustls::Error> {
        // TLS signing is synchronous. Release this executor thread while the user approves access.
        let sign = || self.identity.sign(u16::from(self.scheme), false, message);
        let result = match tokio::runtime::Handle::try_current() {
            Ok(runtime)
                if runtime.runtime_flavor() == tokio::runtime::RuntimeFlavor::MultiThread =>
            {
                tokio::task::block_in_place(sign)
            }
            Ok(_) => {
                return Err(rustls::Error::General(
                    "client identity needs a multi-thread runtime".into(),
                ))
            }
            Err(_) => sign(),
        };
        result.map_err(|_| rustls::Error::General("client identity operation failed".into()))
    }

    fn scheme(&self) -> SignatureScheme {
        self.scheme
    }
}

pub(crate) fn tls_config(identity: Arc<ClientIdentity>) -> Result<ClientConfig, AuthError> {
    let provider = Arc::new(rustls::crypto::ring::default_provider());
    let certificates = identity
        .certificates()
        .iter()
        .cloned()
        .map(CertificateDer::from)
        .collect();
    let certified_key = CertifiedKey::new(certificates, Arc::new(IdentityKey(identity)));
    let roots = RootCertStore::from_iter(webpki_roots::TLS_SERVER_ROOTS.iter().cloned());
    let config = ClientConfig::builder_with_provider(provider)
        .with_safe_default_protocol_versions()
        .map_err(|_| AuthError::Other("TLS configuration failed".into()))?
        .with_root_certificates(roots)
        .with_client_cert_resolver(Arc::new(SingleCertAndKey::from(certified_key)));
    Ok(config)
}
