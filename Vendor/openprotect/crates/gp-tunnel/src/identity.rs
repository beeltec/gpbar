use std::sync::{Arc, OnceLock};

use gp_proto::identity::ClientIdentity;

use crate::TunnelError;

static IDENTITY: OnceLock<Arc<ClientIdentity>> = OnceLock::new();

pub fn install_client_identity(identity: Arc<ClientIdentity>) -> Result<(), TunnelError> {
    IDENTITY
        .set(identity)
        .map_err(|_| TunnelError::OpenConnect("identity already installed".into()))?;
    let identity = IDENTITY
        .get()
        .ok_or_else(|| TunnelError::OpenConnect("identity unavailable".into()))?;
    let certificates: Vec<*const u8> = identity
        .certificates()
        .iter()
        .map(|cert| cert.as_ptr())
        .collect();
    let lengths: Vec<usize> = identity.certificates().iter().map(Vec::len).collect();
    let schemes: Vec<u16> = [
        0x0401, 0x0501, 0x0601, 0x0804, 0x0805, 0x0806, 0x0403, 0x0503, 0x0603,
    ]
    .into_iter()
    .filter(|scheme| identity.supports(*scheme))
    .collect();
    // The static Arc keeps callback data alive. C copies the bounded public certificate buffers.
    let result = unsafe {
        gp_openconnect_sys::openprotect_install_client_identity(
            certificates.as_ptr(),
            lengths.as_ptr(),
            certificates.len() as u32,
            schemes.as_ptr(),
            schemes.len() as u32,
            sign,
            Arc::as_ptr(identity) as *mut std::ffi::c_void,
        )
    };
    if result != 0 {
        return Err(TunnelError::OpenConnect(
            "client identity unavailable".into(),
        ));
    }
    Ok(())
}

unsafe extern "C" fn sign(
    context: *mut std::ffi::c_void,
    scheme: u16,
    input: *const u8,
    length: usize,
    output: *mut u8,
    capacity: usize,
    written: *mut usize,
) -> i32 {
    if context.is_null()
        || input.is_null()
        || output.is_null()
        || written.is_null()
        || length == 0
        || length > 64
        || capacity != 1024
    {
        return -1;
    }
    let result = std::panic::catch_unwind(|| {
        // C supplies the static identity and valid buffers for this synchronous callback.
        let identity = unsafe { &*(context as *const ClientIdentity) };
        let input = unsafe { std::slice::from_raw_parts(input, length) };
        identity.sign(scheme, true, input)
    });
    match result {
        Ok(Ok(signature)) if !signature.is_empty() && signature.len() <= capacity => {
            // The checked output buffer is allocated by GnuTLS and owned by the C callback.
            unsafe {
                std::ptr::copy_nonoverlapping(signature.as_ptr(), output, signature.len());
                *written = signature.len();
            }
            0
        }
        _ => -1,
    }
}
