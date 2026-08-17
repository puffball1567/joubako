#ifndef JOUBAKO_H
#define JOUBAKO_H

#include <stddef.h>
#include <stdint.h>

#if defined(_WIN32)
#  if defined(JOUBAKO_BUILDING_LIBRARY)
#    define JOUBAKO_API __declspec(dllexport)
#  else
#    define JOUBAKO_API __declspec(dllimport)
#  endif
#else
#  define JOUBAKO_API __attribute__((visibility("default")))
#endif

#ifdef __cplusplus
extern "C" {
#endif

#define JOUBAKO_ABI_VERSION 1u

typedef struct JoubakoClient JoubakoClient;
typedef struct JoubakoResponse JoubakoResponse;

typedef enum JoubakoErrorCode {
  JOUBAKO_OK = 0,
  JOUBAKO_ERROR_INVALID_ARGUMENT = 1,
  JOUBAKO_ERROR_INVALID_REQUEST = 10,
  JOUBAKO_ERROR_TRANSPORT = 11,
  JOUBAKO_ERROR_TIMEOUT = 12,
  JOUBAKO_ERROR_CANCELLED = 13,
  JOUBAKO_ERROR_HTTP_STATUS = 14,
  JOUBAKO_ERROR_BODY_TOO_LARGE = 15,
  JOUBAKO_ERROR_CODEC = 16,
  JOUBAKO_ERROR_COMPRESSION = 17,
  JOUBAKO_ERROR_STREAM = 18,
  JOUBAKO_ERROR_CIRCUIT_OPEN = 19,
  JOUBAKO_ERROR_RATE_LIMITED = 20,
  JOUBAKO_ERROR_BULKHEAD_REJECTED = 21,
  JOUBAKO_ERROR_RPC_STATUS = 22,
  JOUBAKO_ERROR_INTERNAL = 100
} JoubakoErrorCode;

/*
 * The C ABI is synchronous and drives Joubako's asynchronous HTTP/1.1 client
 * on the calling thread. A handle must be created, used, and freed on the same
 * thread. Functions never transfer a Nim exception across the C boundary.
 */
JOUBAKO_API uint32_t joubako_abi_version(void);

JOUBAKO_API JoubakoErrorCode joubako_client_create(
  const char *base_url,
  JoubakoClient **out_client
);

JOUBAKO_API void joubako_client_free(JoubakoClient *client);

JOUBAKO_API JoubakoErrorCode joubako_client_set_header(
  JoubakoClient *client,
  const char *name,
  const char *value
);

JOUBAKO_API JoubakoErrorCode joubako_client_set_timeout_ms(
  JoubakoClient *client,
  int32_t timeout_ms
);

JOUBAKO_API JoubakoErrorCode joubako_client_set_max_response_bytes(
  JoubakoClient *client,
  int64_t max_response_bytes
);

/*
 * Sends a JSON request. json_body may be NULL or empty for methods without a
 * body. Non-empty request and response bodies must be valid JSON. out_response
 * receives an owned handle for successful requests and structured request
 * failures, including HTTP status failures. The caller must free it.
 */
JOUBAKO_API JoubakoErrorCode joubako_request_json(
  JoubakoClient *client,
  const char *method,
  const char *path,
  const char *json_body,
  JoubakoResponse **out_response
);

JOUBAKO_API void joubako_response_free(JoubakoResponse *response);
JOUBAKO_API JoubakoErrorCode joubako_response_error_code(
  const JoubakoResponse *response
);
JOUBAKO_API int32_t joubako_response_status(
  const JoubakoResponse *response
);

/* Returned pointers remain valid until joubako_response_free(response). */
JOUBAKO_API const char *joubako_response_body(
  const JoubakoResponse *response
);
JOUBAKO_API size_t joubako_response_body_size(
  const JoubakoResponse *response
);
JOUBAKO_API const char *joubako_response_error_message(
  const JoubakoResponse *response
);
JOUBAKO_API size_t joubako_response_error_message_size(
  const JoubakoResponse *response
);

#ifdef __cplusplus
}
#endif

#endif
