#include "FIDO2Bridge.h"
#include <fido.h>
// Public libfido2 ES256 API; avoid exposing unused OpenSSL conversion APIs.
es256_pk_t *es256_pk_new(void);
void es256_pk_free(es256_pk_t **);
int es256_pk_from_ptr(es256_pk_t *, const void *, size_t);
#include <Security/SecRandom.h>
#include <string.h>
#include <pthread.h>
void cn_fido_wipe(void *bytes, size_t count) { volatile uint8_t *p=bytes; while(count--) *p++=0; }
static const char *rp = "consolinotes.local-unlock";
static pthread_once_t once = PTHREAD_ONCE_INIT;
static void initialize(void) { fido_init(0); }
static void discard_diagnostic(const char *message) { (void)message; }
#define CHECK(call) do { result=(call); if(result!=FIDO_OK) goto done; } while(0)
// Exactly one Yubico USB device; never guess which key should receive a PIN.
int cn_fido_path(char *path, size_t cap) {
 pthread_once(&once,initialize);
 // FIDO_DEBUG can enable library frame dumps even with fido_init(0).
 // Its handler is thread-local, and a serial dispatch queue can change threads.
 fido_set_log_handler(discard_diagnostic);
 size_t n=0, matches=0; int result; fido_dev_info_t *list=fido_dev_info_new(32);
 if(!list) return FIDO_ERR_INTERNAL;
 result=fido_dev_info_manifest(list,32,&n);
 if(result==FIDO_OK) for(size_t i=0;i<n;i++) {
  const fido_dev_info_t *d=fido_dev_info_ptr(list,i); const char *p=fido_dev_info_path(d);
  if(fido_dev_info_vendor(d)!=0x1050 || !p || strncmp(p,"ioreg://",8)) continue;
  matches++; if(strlen(p)>=cap) {result=FIDO_ERR_INTERNAL;break;} strcpy(path,p);
 }
 fido_dev_info_free(&list,32);
 if(result!=FIDO_OK)return result;
 return matches==1 ? FIDO_OK : (matches==0 ? -1001 : -1002);
}
static int open_device(const char *path, fido_dev_t **out) {
 char current[1024]; int result=cn_fido_path(current,sizeof(current));
 if(result!=FIDO_OK)return result;
 if(strcmp(path,current))return -1001;
 fido_dev_t *d=fido_dev_new(); fido_cbor_info_t *info=fido_cbor_info_new();
 if(!d||!info){if(d)fido_dev_free(&d);if(info)fido_cbor_info_free(&info);return FIDO_ERR_INTERNAL;}
 CHECK(fido_dev_set_timeout(d,25000)); CHECK(fido_dev_open(d,path));
 if(!fido_dev_is_fido2(d)){result=-1003;goto done;}
 if(!fido_dev_has_pin(d)){result=-1004;goto done;}
 CHECK(fido_dev_get_cbor_info(d,info));
 result=-1003;
 for(size_t i=0;i<fido_cbor_info_extensions_len(info);i++)
  if(!strcmp(fido_cbor_info_extensions_ptr(info)[i],"hmac-secret"))result=FIDO_OK;
 done: fido_cbor_info_free(&info);
 if(result!=FIDO_OK){fido_dev_close(d);fido_dev_free(&d);} else *out=d;
 return result;
}
// Confirm the selected credential before submitting a PIN. This request has no
// hmac-secret extension and requests neither touch nor user verification. A
// fresh signed assertion proves possession of this enrollment's private key.
// Keep the device open through the later PIN request to avoid a replug race.
static int verify_selected_credential(fido_dev_t *d,const uint8_t *id,size_t len,const es256_pk_t *key) {
 int result; fido_assert_t *a=fido_assert_new(); uint8_t challenge[32];
 if(!a)return FIDO_ERR_INTERNAL;
 if(SecRandomCopyBytes(kSecRandomDefault,32,challenge)){result=FIDO_ERR_INTERNAL;goto done;}
 CHECK(fido_assert_set_rp(a,rp));CHECK(fido_assert_set_clientdata_hash(a,challenge,32));
 CHECK(fido_assert_allow_cred(a,id,len));
 // CTAP requires uv to be absent on keys without built-in verification (e.g.
 // non-biometric YubiKey 5). Even explicit false can return INVALID_OPTION.
 // The actual secret request below still requires PIN verification and touch.
 CHECK(fido_assert_set_up(a,FIDO_OPT_FALSE));CHECK(fido_assert_set_uv(a,FIDO_OPT_OMIT));
 result=fido_dev_get_assert(d,a,NULL);
 if(result==FIDO_ERR_NO_CREDENTIALS || result==FIDO_ERR_INVALID_CREDENTIAL){result=-1005;goto done;}
 if(result==FIDO_ERR_PIN_REQUIRED || result==FIDO_ERR_PIN_AUTH_INVALID ||
    result==FIDO_ERR_UP_REQUIRED || result==FIDO_ERR_OPERATION_DENIED){result=-1006;goto done;}
 if(result==FIDO_ERR_INVALID_OPTION){result=-1007;goto done;}
 if(result==FIDO_ERR_UNSUPPORTED_OPTION){result=-1008;goto done;}
 if(result!=FIDO_OK)goto done;
 if(fido_assert_count(a)!=1){result=-1005;goto done;}
 result=fido_assert_verify(a,0,COSE_ES256,key);
 if(result!=FIDO_OK)result=-1005;
 done:fido_assert_free(&a);cn_fido_wipe(challenge,32);return result;
}
int cn_fido_create(const char *path,const char *pin,uint8_t *id,size_t *len,uint8_t pk[64]) {
 int result; fido_dev_t *d=NULL; fido_cred_t *c=NULL; uint8_t challenge[32],user[32];
 if(!pin||!*pin)return -1004;
 if(SecRandomCopyBytes(kSecRandomDefault,32,challenge)||SecRandomCopyBytes(kSecRandomDefault,32,user))return FIDO_ERR_INTERNAL;
 CHECK(open_device(path,&d)); c=fido_cred_new();if(!c){result=FIDO_ERR_INTERNAL;goto done;}
 CHECK(fido_cred_set_type(c,COSE_ES256));CHECK(fido_cred_set_rp(c,rp,"consolinotes local unlock"));
 CHECK(fido_cred_set_user(c,user,32,"consolinotes","consolinotes local unlock",NULL));
 CHECK(fido_cred_set_clientdata_hash(c,challenge,32));CHECK(fido_cred_set_extensions(c,FIDO_EXT_HMAC_SECRET));
 CHECK(fido_cred_set_rk(c,FIDO_OPT_FALSE)); CHECK(fido_cred_set_uv(c,FIDO_OPT_TRUE));
 CHECK(fido_dev_make_cred(d,c,pin));
 if((fido_cred_flags(c)&5)!=5){result=FIDO_ERR_INVALID_PARAM;goto done;}
 CHECK(fido_cred_x5c_ptr(c) ? fido_cred_verify(c) : fido_cred_verify_self(c));
 if(fido_cred_id_len(c)==0 || fido_cred_id_len(c)>*len || fido_cred_pubkey_len(c)!=64){result=FIDO_ERR_INVALID_PARAM;goto done;}
 *len=fido_cred_id_len(c);memcpy(id,fido_cred_id_ptr(c),*len);memcpy(pk,fido_cred_pubkey_ptr(c),64);
 done:if(c)fido_cred_free(&c);if(d){fido_dev_close(d);fido_dev_free(&d);} cn_fido_wipe(challenge,32);cn_fido_wipe(user,32);return result;
}
int cn_fido_secret(const char *path,const char *pin,const uint8_t *id,size_t len,const uint8_t pk[64],const uint8_t salt[32],uint8_t secret[32]) {
 int result;fido_dev_t *d=NULL;fido_assert_t *a=NULL;es256_pk_t *key=NULL;uint8_t challenge[32];
 memset(secret,0,32);if(!pin||!*pin)return -1004;
 if(SecRandomCopyBytes(kSecRandomDefault,32,challenge))return FIDO_ERR_INTERNAL;
 CHECK(open_device(path,&d));a=fido_assert_new();key=es256_pk_new();if(!a||!key){result=FIDO_ERR_INTERNAL;goto done;}
 CHECK(es256_pk_from_ptr(key,pk,64));
 CHECK(verify_selected_credential(d,id,len,key));
 CHECK(fido_assert_set_rp(a,rp));CHECK(fido_assert_set_clientdata_hash(a,challenge,32));
 CHECK(fido_assert_allow_cred(a,id,len));CHECK(fido_assert_set_extensions(a,FIDO_EXT_HMAC_SECRET));CHECK(fido_assert_set_hmac_salt(a,salt,32));
 CHECK(fido_assert_set_up(a,FIDO_OPT_TRUE));CHECK(fido_assert_set_uv(a,FIDO_OPT_TRUE));CHECK(fido_dev_get_assert(d,a,pin));
 if(fido_assert_count(a)!=1 || (fido_assert_flags(a,0)&5)!=5 || fido_assert_hmac_secret_len(a,0)!=32){result=FIDO_ERR_INVALID_PARAM;goto done;}
 CHECK(fido_assert_verify(a,0,COSE_ES256,key));memcpy(secret,fido_assert_hmac_secret_ptr(a,0),32);
 done:if(key)es256_pk_free(&key);if(a)fido_assert_free(&a);if(d){fido_dev_close(d);fido_dev_free(&d);}cn_fido_wipe(challenge,32);return result;
}
const char *cn_fido_error(int status) {
 switch(status){
 case -1001:return "Connect one YubiKey over USB and try again.";
 case -1002:return "More than one YubiKey is connected. Leave only the intended key connected.";
 case -1003:return "This key does not support FIDO2 hmac-secret. Enable its FIDO2 interface using Yubico tools.";
 case -1004:return "Set a FIDO2 PIN using Yubico Authenticator first, then enter it here. The app does not set or reset PINs.";
 case -1005:return "The connected YubiKey does not match the selected enrollment. Connect the matching key or select another enrollment. No PIN was sent.";
 case FIDO_ERR_NO_CREDENTIALS:return "The connected YubiKey does not contain the selected credential. Connect the matching key or select another enrollment.";
 case -1006:return "This YubiKey's policy prevents a PIN-free identity check. No PIN was sent. Use your note password; do not weaken the key's security policy.";
 case -1007:return "The YubiKey rejected an option in the app's preliminary identity check (CTAP INVALID_OPTION). No PIN was sent. Use your note password and report this compatibility error.";
 case -1008:return "The YubiKey does not support an option in the app's preliminary identity check (CTAP UNSUPPORTED_OPTION). No PIN was sent. Use your note password and report this compatibility error.";
 case FIDO_ERR_PIN_INVALID:return "Incorrect FIDO2 PIN. No automatic retry was made; repeated mistakes can block the key.";
 case FIDO_ERR_PIN_BLOCKED:return "The FIDO2 PIN is blocked. Use your note password; do not reset your key to troubleshoot this app.";
 case FIDO_ERR_PIN_AUTH_BLOCKED:return "PIN attempts are temporarily blocked. Reconnect the key and use the correct PIN.";
 case FIDO_ERR_ACTION_TIMEOUT: case FIDO_ERR_USER_ACTION_TIMEOUT: return "The key timed out waiting for touch. Try again or enter your note password.";
 default:return fido_strerr(status);
 }
}
