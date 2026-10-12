#ifndef CONSOLINOTES_FIDO2_H
#define CONSOLINOTES_FIDO2_H
#include <stddef.h>
#include <stdint.h>
// All calls run on one serial worker. No credentials/PINs are logged.
int cn_fido_path(char *path, size_t capacity);
int cn_fido_create(const char *path, const char *pin, uint8_t *credential, size_t *credential_len, uint8_t public_key[64]);
// Verifies a PIN-free assertion for the selected credential before sending the
// PIN, on the same open USB device. Identity-check failure never submits a PIN.
int cn_fido_secret(const char *path, const char *pin, const uint8_t *credential, size_t credential_len, const uint8_t public_key[64], const uint8_t salt[32], uint8_t secret[32]);
void cn_fido_wipe(void *bytes, size_t count);
const char *cn_fido_error(int status);
#endif
