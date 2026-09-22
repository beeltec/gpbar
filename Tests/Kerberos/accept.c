#include <gssapi/gssapi.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

int main(void) {
    unsigned char bytes[49153];
    size_t length = 0;
    ssize_t count;
    while ((count = read(STDIN_FILENO, bytes + length, sizeof(bytes) - length)) > 0) {
        length += (size_t)count;
        if (length == sizeof(bytes)) return 1;
    }
    if (count < 0 || length == 0) return 1;
    OM_uint32 minor = 0;
    gss_ctx_id_t context = GSS_C_NO_CONTEXT;
    gss_buffer_desc input = {length, bytes}, output = GSS_C_EMPTY_BUFFER;
    OM_uint32 major = gss_accept_sec_context(&minor, &context, GSS_C_NO_CREDENTIAL,
        &input, GSS_C_NO_CHANNEL_BINDINGS, NULL, NULL, &output, NULL, NULL, NULL);
    int result = major != GSS_S_COMPLETE;
    if (!result && fwrite(output.value, 1, output.length, stdout) != output.length) result = 1;
    gss_release_buffer(&minor, &output);
    if (context != GSS_C_NO_CONTEXT) gss_delete_sec_context(&minor, &context, GSS_C_NO_BUFFER);
    return result;
}
