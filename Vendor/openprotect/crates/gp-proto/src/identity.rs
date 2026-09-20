use std::sync::Arc;

#[derive(Debug, thiserror::Error)]
#[error("client identity operation failed")]
pub struct IdentityError;

pub trait IdentitySigner: Send + Sync {
    fn sign(&self, scheme: u16, digest: bool, input: &[u8]) -> Result<Vec<u8>, IdentityError>;
}

pub struct ClientIdentity {
    certificates: Vec<Vec<u8>>,
    schemes: Vec<u16>,
    signer: Arc<dyn IdentitySigner>,
}

impl std::fmt::Debug for ClientIdentity {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("ClientIdentity")
            .finish_non_exhaustive()
    }
}

impl ClientIdentity {
    pub fn new(
        certificates: Vec<Vec<u8>>,
        schemes: Vec<u16>,
        signer: Arc<dyn IdentitySigner>,
    ) -> Result<Self, IdentityError> {
        if certificates.is_empty()
            || certificates.len() > 16
            || certificates
                .iter()
                .any(|cert| cert.is_empty() || cert.len() > 16384)
            || certificates.iter().map(Vec::len).sum::<usize>() > 65536
            || schemes.is_empty()
            || schemes.len() > 9
            || schemes
                .iter()
                .any(|scheme| digest_length(*scheme).is_none())
            || (schemes.iter().any(|scheme| scheme & 0xff == 3) && schemes.len() != 1)
        {
            return Err(IdentityError);
        }
        Ok(Self {
            certificates,
            schemes,
            signer,
        })
    }

    pub fn certificates(&self) -> &[Vec<u8>] {
        &self.certificates
    }

    pub fn supports(&self, scheme: u16) -> bool {
        self.schemes.contains(&scheme)
    }

    pub fn sign(&self, scheme: u16, digest: bool, input: &[u8]) -> Result<Vec<u8>, IdentityError> {
        if !self.supports(scheme)
            || input.is_empty()
            || input.len() > 65536
            || (digest && digest_length(scheme) != Some(input.len()))
        {
            return Err(IdentityError);
        }
        let signature = self.signer.sign(scheme, digest, input)?;
        if signature.is_empty() || signature.len() > 1024 {
            return Err(IdentityError);
        }
        Ok(signature)
    }
}

pub fn digest_length(scheme: u16) -> Option<usize> {
    match scheme {
        0x0401 | 0x0403 | 0x0804 => Some(32),
        0x0501 | 0x0503 | 0x0805 => Some(48),
        0x0601 | 0x0603 | 0x0806 => Some(64),
        _ => None,
    }
}
