#!/usr/bin/env python3
"""Exercise production bridge ordering with fake USB; never enumerate real devices."""
from pathlib import Path
import os
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
fixture = r'''
#include <fido.h>
#include <assert.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#undef assert
#define assert(test) do { if(!(test)){fprintf(stderr,"Assertion at line %d: %s\n",__LINE__,#test);exit(1);} } while(0)

enum response {
 NORMAL, BAD_PROBE_SIGNATURE, NO_PROBE_ASSERTIONS, MULTIPLE_PROBE_ASSERTIONS,
 INVALID_PIN, BAD_SIGNATURE, MISSING_UP, MISSING_UV, MISSING_BOTH,
 NO_ASSERTIONS, MULTIPLE_ASSERTIONS, WRONG_CREDENTIAL, INVALID_CREDENTIAL,
 NO_SECRET, LONG_SECRET
};
struct scenario {
 const char *name;
 int probe_result;
 enum response response;
 int expected_result;
 bool expect_pin, expect_no_pin_message;
};
static const struct scenario *scenario;
static int opens, closes, probes, pin_calls, verified, log_handlers;
static fido_dev_t *opened;
static unsigned char fake_info;
struct request { fido_assert_t *assertion; fido_opt_t up, uv; int extensions, allowed; };
static struct request requests[4];
static size_t request_count;
static struct request *request(fido_assert_t *a) {
 for(size_t i=0;i<request_count;i++) if(requests[i].assertion==a)return &requests[i];
 assert(request_count<4); struct request *r=&requests[request_count++];
 *r=(struct request){.assertion=a,.up=FIDO_OPT_OMIT,.uv=FIDO_OPT_OMIT};return r;
}
static fido_dev_info_t *mock_info_new(size_t n){return (fido_dev_info_t *)&fake_info;}
static void mock_info_free(fido_dev_info_t **p,size_t n){*p=NULL;}
static int mock_manifest(fido_dev_info_t *d,size_t n,size_t *out){*out=1;return FIDO_OK;}
static const fido_dev_info_t *mock_info_ptr(const fido_dev_info_t *d,size_t n){return d;}
static const char *mock_info_path(const fido_dev_info_t *d){return "ioreg://synthetic-only";}
static int16_t mock_vendor(const fido_dev_info_t *d){return 0x1050;}
static int mock_open(fido_dev_t *d,const char *p){assert(!strcmp(p,"ioreg://synthetic-only"));opened=d;opens++;return FIDO_OK;}
static int mock_close(fido_dev_t *d){assert(d==opened);closes++;return FIDO_OK;}
static bool mock_capability(const fido_dev_t *d){return true;}
static int mock_get_info(fido_dev_t *d,fido_cbor_info_t *i){return FIDO_OK;}
static size_t mock_extensions_len(const fido_cbor_info_t *i){return 1;}
static char **mock_extensions_ptr(const fido_cbor_info_t *i){static char *v[]={"hmac-secret"};return v;}
static int mock_up(fido_assert_t *a,fido_opt_t value){request(a)->up=value;return fido_assert_set_up(a,value);}
static int mock_uv(fido_assert_t *a,fido_opt_t value){request(a)->uv=value;return fido_assert_set_uv(a,value);}
static int mock_extensions(fido_assert_t *a,int value){request(a)->extensions=value;return fido_assert_set_extensions(a,value);}
static int mock_allow(fido_assert_t *a,const unsigned char *id,size_t n){
 assert(n==64 && id[0]==1);request(a)->allowed++;return fido_assert_allow_cred(a,id,n);
}
static int mock_assert(fido_dev_t *d,fido_assert_t *a,const char *pin){
 struct request *r=request(a);assert(d==opened && opens==1);
 assert(!strcmp(fido_assert_rp_id(a),"consolinotes.local-unlock"));
 assert(fido_assert_clientdata_hash_len(a)==32 && r->allowed==1);
 if(!pin){
  probes++;assert(r->up==FIDO_OPT_FALSE && r->extensions==0);
  // A non-biometric authenticator does not advertise built-in UV. CTAP
  // rejects an explicit UV option, even false; omission is the portable form.
  if(r->uv!=FIDO_OPT_OMIT)return FIDO_ERR_INVALID_OPTION;
  if(scenario->probe_result!=FIDO_OK)return scenario->probe_result;
  size_t count=scenario->response==NO_PROBE_ASSERTIONS?0:
   (scenario->response==MULTIPLE_PROBE_ASSERTIONS?2:1);
  assert(fido_assert_set_count(a,count)==FIDO_OK);return FIDO_OK;
 }
 pin_calls++;assert(pin_calls==1 && probes==1 && verified==1 && !strcmp(pin,"fixture-pin"));
 assert(r->up==FIDO_OPT_TRUE && r->uv==FIDO_OPT_TRUE && r->extensions==FIDO_EXT_HMAC_SECRET);
 if(scenario->response==INVALID_PIN)return FIDO_ERR_PIN_INVALID;
 if(scenario->response==WRONG_CREDENTIAL)return FIDO_ERR_NO_CREDENTIALS;
 if(scenario->response==INVALID_CREDENTIAL)return FIDO_ERR_INVALID_CREDENTIAL;
 size_t count=scenario->response==NO_ASSERTIONS?0:
  (scenario->response==MULTIPLE_ASSERTIONS?2:1);
 assert(fido_assert_set_count(a,count)==FIDO_OK);
 if(count && scenario->response!=NO_SECRET){
  unsigned char secret[64];memset(secret,42,sizeof(secret));
  size_t length=scenario->response==LONG_SECRET?64:32;
  assert(fido_assert_set_hmac_secret(a,0,secret,length)==FIDO_OK);
 }
 return FIDO_OK;
}
static int mock_verify(const fido_assert_t *a,size_t i,int algorithm,const void *pk){
 assert(algorithm==COSE_ES256 && pk && i==0);verified++;
 if((scenario->response==BAD_PROBE_SIGNATURE && pin_calls==0)||
    (scenario->response==BAD_SIGNATURE && pin_calls==1))return FIDO_ERR_INVALID_SIG;
 return FIDO_OK;
}
static uint8_t mock_flags(const fido_assert_t *a,size_t n){
 if(scenario->response==MISSING_UP)return 4;
 if(scenario->response==MISSING_UV)return 1;
 if(scenario->response==MISSING_BOTH)return 0;
 return 5;
}
static void mock_log_handler(fido_log_handler_t *handler){assert(handler);log_handlers++;fido_set_log_handler(handler);}

// Rename only the hardware boundary and request observers. The production
// bridge, libfido2 allocation/setters, and cryptographic key parsing are real.
#define fido_dev_info_new mock_info_new
#define fido_dev_info_free mock_info_free
#define fido_dev_info_manifest mock_manifest
#define fido_dev_info_ptr mock_info_ptr
#define fido_dev_info_path mock_info_path
#define fido_dev_info_vendor mock_vendor
#define fido_dev_open mock_open
#define fido_dev_close mock_close
#define fido_dev_is_fido2 mock_capability
#define fido_dev_has_pin mock_capability
#define fido_dev_get_cbor_info mock_get_info
#define fido_cbor_info_extensions_len mock_extensions_len
#define fido_cbor_info_extensions_ptr mock_extensions_ptr
#define fido_assert_set_up mock_up
#define fido_assert_set_uv mock_uv
#define fido_assert_set_extensions mock_extensions
#define fido_assert_allow_cred mock_allow
#define fido_dev_get_assert mock_assert
#define fido_assert_verify mock_verify
#define fido_assert_flags mock_flags
#define fido_set_log_handler mock_log_handler
#include "FIDO2Bridge.c"

// The upstream diagnostic API is deliberately exercised without any device I/O.
void fido_log_debug(const char *, ...);
static void *check_thread_logging(void *unused){
 char path[1024];assert(cn_fido_path(path,sizeof(path))==0);
 fido_log_debug("must not appear in diagnostics");return NULL;
}
int main(void){
 unsigned char id[64],pk[64],salt[32],secret[32];
 memset(id,1,sizeof(id));memset(salt,3,sizeof(salt));
 // Standard P-256 base point, used only as a valid public key fixture.
 const char *point="6b17d1f2e12c4247f8bce6e563a440f277037d812deb33a0f4a13945d898c296"
                   "4fe342e2fe1a7f9b8ee7eb4a7c0f9e162bce33576b315ececbb6406837bf51f5";
 for(size_t i=0;i<64;i++){unsigned int byte;assert(sscanf(point+2*i,"%2x",&byte)==1);pk[i]=(unsigned char)byte;}
 const struct scenario scenarios[]={
  {"non-biometric key accepts omitted UV",FIDO_OK,NORMAL,FIDO_OK,true,false},
  {"silent wrong key",FIDO_ERR_NO_CREDENTIALS,NORMAL,-1005,false,true},
  {"silent invalid credential",FIDO_ERR_INVALID_CREDENTIAL,NORMAL,-1005,false,true},
  {"silent PIN required",FIDO_ERR_PIN_REQUIRED,NORMAL,-1006,false,true},
  {"silent PIN auth invalid",FIDO_ERR_PIN_AUTH_INVALID,NORMAL,-1006,false,true},
  {"silent touch required",FIDO_ERR_UP_REQUIRED,NORMAL,-1006,false,true},
  {"silent operation denied",FIDO_ERR_OPERATION_DENIED,NORMAL,-1006,false,true},
  {"silent unsupported option",FIDO_ERR_UNSUPPORTED_OPTION,NORMAL,-1008,false,true},
  {"silent invalid option",FIDO_ERR_INVALID_OPTION,NORMAL,-1007,false,true},
  {"silent transport failure",FIDO_ERR_RX,NORMAL,FIDO_ERR_RX,false,false},
  {"silent signature invalid",FIDO_OK,BAD_PROBE_SIGNATURE,-1005,false,true},
  {"silent no assertion",FIDO_OK,NO_PROBE_ASSERTIONS,-1005,false,true},
  {"silent multiple assertions",FIDO_OK,MULTIPLE_PROBE_ASSERTIONS,-1005,false,true},
  {"PIN failure is not retried",FIDO_OK,INVALID_PIN,FIDO_ERR_PIN_INVALID,true,false},
  {"authenticated signature invalid",FIDO_OK,BAD_SIGNATURE,FIDO_ERR_INVALID_SIG,true,false},
  {"authenticated missing presence",FIDO_OK,MISSING_UP,FIDO_ERR_INVALID_PARAM,true,false},
  {"authenticated missing verification",FIDO_OK,MISSING_UV,FIDO_ERR_INVALID_PARAM,true,false},
  {"authenticated missing both flags",FIDO_OK,MISSING_BOTH,FIDO_ERR_INVALID_PARAM,true,false},
  {"authenticated no assertion",FIDO_OK,NO_ASSERTIONS,FIDO_ERR_INVALID_PARAM,true,false},
  {"authenticated multiple assertions",FIDO_OK,MULTIPLE_ASSERTIONS,FIDO_ERR_INVALID_PARAM,true,false},
  {"authenticated wrong credential",FIDO_OK,WRONG_CREDENTIAL,FIDO_ERR_NO_CREDENTIALS,true,false},
  {"authenticated invalid credential",FIDO_OK,INVALID_CREDENTIAL,FIDO_ERR_INVALID_CREDENTIAL,true,false},
  {"authenticated missing secret",FIDO_OK,NO_SECRET,FIDO_ERR_INVALID_PARAM,true,false},
  {"authenticated oversized secret",FIDO_OK,LONG_SECRET,FIDO_ERR_INVALID_PARAM,true,false}
 };
 for(size_t case_index=0;case_index<sizeof(scenarios)/sizeof(scenarios[0]);case_index++){
  scenario=&scenarios[case_index];
  opens=closes=probes=pin_calls=verified=0;request_count=0;memset(secret,99,sizeof(secret));
  int result=cn_fido_secret("ioreg://synthetic-only","fixture-pin",id,sizeof(id),pk,salt,secret);
  if(result!=scenario->expected_result){
   fprintf(stderr,"Scenario '%s': expected %d, got %d\n",scenario->name,scenario->expected_result,result);return 1;
  }
  assert(opens==1 && closes==1 && probes==1);
  assert(pin_calls==(scenario->expect_pin?1:0));
  if(result==FIDO_OK){
   assert(verified==2);for(size_t i=0;i<32;i++)assert(secret[i]==42);
  }else{
   for(size_t i=0;i<32;i++)assert(secret[i]==0);
   if(scenario->expect_no_pin_message)assert(strstr(cn_fido_error(result),"No PIN was sent"));
  }
 }
 int prior=log_handlers;check_thread_logging(NULL);
 pthread_t other;assert(!pthread_create(&other,NULL,check_thread_logging,NULL));assert(!pthread_join(other,NULL));
 assert(log_handlers==prior+2);
 puts("PASS: 24 synthetic bridge scenarios; non-biometric UV omission; same-device PIN-free preflight; fail-closed policy and option refusals; signed UP/UV secret enforcement; no PIN retries; zero failure outputs; per-thread diagnostic suppression");
}
'''

with tempfile.TemporaryDirectory(prefix="consolinotes-fido-bridge-") as temporary:
    directory = Path(temporary)
    source, binary = directory / "bridge-test.c", directory / "bridge-test"
    source.write_text(fixture)
    subprocess.run([
        "xcrun", "clang", "-mmacosx-version-min=12.4",
        "-I" + str(ROOT / "Vendor/FIDO2/include"),
        "-I" + str(ROOT / "FSNotesCore/FIDO2"), str(source),
        *[str(ROOT / "Vendor/FIDO2/lib" / name) for name in ("libfido2.a", "libcbor.a", "libcrypto.a")],
        "-framework", "IOKit", "-framework", "CoreFoundation", "-framework", "Security", "-lz", "-o", str(binary)
    ], check=True)
    result = subprocess.run([str(binary)], env=dict(os.environ, FIDO_DEBUG="1"), text=True, capture_output=True)
    assert result.returncode == 0, result.stderr or str(result.returncode)
    assert not result.stderr, "FIDO2 diagnostics leaked: " + result.stderr
    print(result.stdout, end="")
