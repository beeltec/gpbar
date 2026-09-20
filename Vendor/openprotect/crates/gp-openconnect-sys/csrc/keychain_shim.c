#include <gnutls/abstract.h>
#include <gnutls/crypto.h>
#include <gnutls/urls.h>
#include <gnutls/x509.h>
#include <stdint.h>
#include <string.h>

typedef int (*gpbar_sign_fn)(void *, uint16_t, const unsigned char *, size_t,
                             unsigned char *, size_t, size_t *);

/* One immutable identity belongs to the single-session engine process. */
static struct {
    gnutls_datum_t certificates[16];
    unsigned count;
    uint16_t schemes[9];
    unsigned scheme_count;
    int algorithm;
    unsigned bits;
    gpbar_sign_fn sign;
    void *context;
} identity;

static const char identity_url[] = "gpbar-keychain:session";

static uint16_t tls_scheme(gnutls_sign_algorithm_t algorithm)
{
    switch (algorithm) {
    case GNUTLS_SIGN_RSA_SHA256: return 0x0401;
    case GNUTLS_SIGN_RSA_SHA384: return 0x0501;
    case GNUTLS_SIGN_RSA_SHA512: return 0x0601;
    case GNUTLS_SIGN_RSA_PSS_RSAE_SHA256: return 0x0804;
    case GNUTLS_SIGN_RSA_PSS_RSAE_SHA384: return 0x0805;
    case GNUTLS_SIGN_RSA_PSS_RSAE_SHA512: return 0x0806;
    case GNUTLS_SIGN_ECDSA_SHA256:
    case GNUTLS_SIGN_ECDSA_SECP256R1_SHA256: return 0x0403;
    case GNUTLS_SIGN_ECDSA_SHA384:
    case GNUTLS_SIGN_ECDSA_SECP384R1_SHA384: return 0x0503;
    case GNUTLS_SIGN_ECDSA_SHA512:
    case GNUTLS_SIGN_ECDSA_SECP521R1_SHA512: return 0x0603;
    default: return 0;
    }
}

static int supports(uint16_t scheme)
{
    if (!scheme || ((scheme & 0xff) == 3) != (identity.algorithm == GNUTLS_PK_ECDSA))
        return 0;
    for (unsigned i = 0; i < identity.scheme_count; i++)
        if (identity.schemes[i] == scheme)
            return 1;
    return 0;
}

static int key_info(gnutls_privkey_t key, unsigned flags, void *context)
{
    (void)key;
    (void)context;
    if (flags & GNUTLS_PRIVKEY_INFO_PK_ALGO)
        return identity.algorithm;
    if (flags & GNUTLS_PRIVKEY_INFO_PK_ALGO_BITS)
        return (int)identity.bits;
    if (flags & GNUTLS_PRIVKEY_INFO_HAVE_SIGN_ALGO) {
        gnutls_sign_algorithm_t algorithm = (gnutls_sign_algorithm_t)GNUTLS_FLAGS_TO_SIGN_ALGO(flags);
        if (algorithm == GNUTLS_SIGN_ECDSA_SHA256 && identity.algorithm == GNUTLS_PK_ECDSA)
            return 1;
        return supports(tls_scheme(algorithm));
    }
    return 0;
}

static int sign_hash(gnutls_privkey_t key, gnutls_sign_algorithm_t algorithm,
                     void *context, unsigned flags, const gnutls_datum_t *hash,
                     gnutls_datum_t *signature)
{
    (void)key;
    (void)context;
    (void)flags;
    uint16_t scheme = tls_scheme(algorithm);
    if (!hash || !hash->data || !signature)
        return GNUTLS_E_PK_SIGN_FAILED;
    unsigned char decoded[64];
    gnutls_datum_t digest = *hash;
    if (algorithm == GNUTLS_SIGN_RSA_RAW) {
        gnutls_digest_algorithm_t hash_algorithm;
        digest.size = sizeof(decoded);
        if (hash->size > 128 || gnutls_decode_ber_digest_info(hash, &hash_algorithm, decoded, &digest.size) < 0)
            return GNUTLS_E_PK_SIGN_FAILED;
        switch (hash_algorithm) {
        case GNUTLS_DIG_SHA256: scheme = 0x0401; break;
        case GNUTLS_DIG_SHA384: scheme = 0x0501; break;
        case GNUTLS_DIG_SHA512: scheme = 0x0601; break;
        default: return GNUTLS_E_PK_SIGN_FAILED;
        }
        digest.data = decoded;
    }
    int certificate_match = algorithm == GNUTLS_SIGN_ECDSA_SHA256 && identity.algorithm == GNUTLS_PK_ECDSA;
    if ((!supports(scheme) && !certificate_match) || digest.size > 64)
        return GNUTLS_E_PK_SIGN_FAILED;
    unsigned char *buffer = gnutls_malloc(1024);
    if (!buffer)
        return GNUTLS_E_MEMORY_ERROR;
    size_t length = 0;
    int result = identity.sign(identity.context, scheme, digest.data, digest.size,
                               buffer, 1024, &length);
    if (result || !length || length > 1024) {
        gnutls_free(buffer);
        return GNUTLS_E_PK_SIGN_FAILED;
    }
    signature->data = buffer;
    signature->size = (unsigned)length;
    return 0;
}

static int import_key(gnutls_privkey_t key, const char *url, unsigned flags)
{
    (void)flags;
    if (!identity.sign || !url || strcmp(url, identity_url))
        return GNUTLS_E_REQUESTED_DATA_NOT_AVAILABLE;
    return gnutls_privkey_import_ext4(key, NULL, NULL, sign_hash, NULL, NULL, key_info, 0);
}

static int import_certificate(gnutls_x509_crt_t certificate, const char *url, unsigned flags)
{
    (void)flags;
    if (!identity.sign || !url || strcmp(url, identity_url))
        return GNUTLS_E_REQUESTED_DATA_NOT_AVAILABLE;
    return gnutls_x509_crt_import(certificate, &identity.certificates[0], GNUTLS_X509_FMT_DER);
}

static int get_issuer(const char *url, gnutls_x509_crt_t certificate,
                      gnutls_datum_t *der, unsigned flags)
{
    (void)flags;
    if (!identity.sign || !url || strcmp(url, identity_url) || !der)
        return GNUTLS_E_REQUESTED_DATA_NOT_AVAILABLE;
    for (unsigned i = 1; i < identity.count; i++) {
        gnutls_x509_crt_t candidate;
        if (gnutls_x509_crt_init(&candidate) < 0)
            return GNUTLS_E_MEMORY_ERROR;
        int result = gnutls_x509_crt_import(candidate, &identity.certificates[i], GNUTLS_X509_FMT_DER);
        int matches = result >= 0 && gnutls_x509_crt_check_issuer(certificate, candidate);
        gnutls_x509_crt_deinit(candidate);
        if (matches) {
            der->data = gnutls_malloc(identity.certificates[i].size);
            if (!der->data)
                return GNUTLS_E_MEMORY_ERROR;
            der->size = identity.certificates[i].size;
            memcpy(der->data, identity.certificates[i].data, der->size);
            return 0;
        }
    }
    return GNUTLS_E_REQUESTED_DATA_NOT_AVAILABLE;
}

int openprotect_install_client_identity(const unsigned char *const *certificates,
                                        const size_t *lengths, unsigned count,
                                        const uint16_t *schemes, unsigned scheme_count,
                                        gpbar_sign_fn sign, void *context)
{
    if (identity.sign || !certificates || !lengths || !count || count > 16 ||
        !schemes || !scheme_count || scheme_count > 9 || !sign || !context)
        return GNUTLS_E_INVALID_REQUEST;
    int result = gnutls_global_init();
    if (result < 0)
        return result;
    size_t total = 0;
    for (unsigned i = 0; i < count; i++) {
        if (!certificates[i] || !lengths[i] || lengths[i] > 16384 || total + lengths[i] > 65536) {
            result = GNUTLS_E_INVALID_REQUEST;
            goto failed;
        }
        total += lengths[i];
        identity.certificates[i].data = gnutls_malloc(lengths[i]);
        if (!identity.certificates[i].data) {
            result = GNUTLS_E_MEMORY_ERROR;
            goto failed;
        }
        identity.certificates[i].size = (unsigned)lengths[i];
        memcpy(identity.certificates[i].data, certificates[i], lengths[i]);
        identity.count++;
    }
    gnutls_x509_crt_t leaf;
    result = gnutls_x509_crt_init(&leaf);
    if (result < 0)
        goto failed;
    result = gnutls_x509_crt_import(leaf, &identity.certificates[0], GNUTLS_X509_FMT_DER);
    if (result >= 0)
        identity.algorithm = gnutls_x509_crt_get_pk_algorithm(leaf, &identity.bits);
    gnutls_x509_crt_deinit(leaf);
    if (result < 0)
        goto failed;
    if (!((identity.algorithm == GNUTLS_PK_RSA && identity.bits >= 2048 && identity.bits <= 8192) ||
          (identity.algorithm == GNUTLS_PK_ECDSA &&
           (identity.bits == 256 || identity.bits == 384 || identity.bits == 521)))) {
        result = GNUTLS_E_UNSUPPORTED_SIGNATURE_ALGORITHM;
        goto failed;
    }
    memcpy(identity.schemes, schemes, scheme_count * sizeof(*schemes));
    identity.scheme_count = scheme_count;
    static const gnutls_custom_url_st provider = {
        .name = "gpbar-keychain:", .name_size = sizeof("gpbar-keychain:") - 1,
        .import_key = import_key, .import_crt = import_certificate, .get_issuer = get_issuer
    };
    result = gnutls_register_custom_url(&provider);
    if (result < 0)
        goto failed;
    identity.context = context;
    identity.sign = sign;
    return 0;

failed:
    for (unsigned i = 0; i < identity.count; i++)
        gnutls_free(identity.certificates[i].data);
    memset(&identity, 0, sizeof(identity));
    gnutls_global_deinit();
    return result;
}
