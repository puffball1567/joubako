#if !defined(_WIN32)
#define _POSIX_C_SOURCE 200809L
#endif

#include "joubako.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#if defined(_WIN32)
#include <windows.h>
static void sleep_milliseconds(unsigned milliseconds) { Sleep(milliseconds); }
#else
#include <errno.h>
static void sleep_milliseconds(unsigned milliseconds) {
  struct timespec delay;
  delay.tv_sec = (time_t)(milliseconds / 1000u);
  delay.tv_nsec = (long)(milliseconds % 1000u) * 1000000L;
  while (nanosleep(&delay, &delay) != 0 && errno == EINTR) {}
}
#endif

static int contains(const char *text, const char *expected) {
  return text != NULL && strstr(text, expected) != NULL;
}

static int check_request(
  JoubakoClient *client,
  const char *method,
  const char *path,
  const char *body,
  JoubakoErrorCode expected_code,
  int expected_status,
  const char *expected_body
) {
  JoubakoResponse *response = NULL;
  JoubakoErrorCode code = joubako_request_json(
    client, method, path, body, &response
  );
  if (code != expected_code || response == NULL) {
    fprintf(stderr, "%s %s returned code %d without the expected response\n",
      method, path, (int)code);
    return 0;
  }
  int valid =
    joubako_response_error_code(response) == expected_code &&
    joubako_response_status(response) == expected_status &&
    contains(joubako_response_body(response), expected_body);
  if (!valid) {
    fprintf(stderr,
      "%s %s mismatch: code=%d status=%d body=%s error=%s\n",
      method,
      path,
      (int)joubako_response_error_code(response),
      (int)joubako_response_status(response),
      joubako_response_body(response),
      joubako_response_error_message(response));
  }
  joubako_response_free(response);
  return valid;
}

int main(int argc, char **argv) {
  const char *base_url = argc > 1 ? argv[1] : "http://127.0.0.1:8081/";
  unsigned long requested_cycles = argc > 2 ? strtoul(argv[2], NULL, 10) : 1;
  unsigned long duration_seconds = argc > 3 ? strtoul(argv[3], NULL, 10) : 0;
  unsigned delay_ms = argc > 4 ? (unsigned)strtoul(argv[4], NULL, 10) : 0;

  if (joubako_abi_version() != JOUBAKO_ABI_VERSION) {
    fprintf(stderr, "C ABI version mismatch\n");
    return 1;
  }

  JoubakoClient *client = NULL;
  if (joubako_client_create(base_url, &client) != JOUBAKO_OK || client == NULL) {
    fprintf(stderr, "could not create Joubako client\n");
    return 1;
  }
  if (joubako_client_set_header(
      client, "x-joubako-demo", "c-abi-client") != JOUBAKO_OK ||
      joubako_client_set_timeout_ms(client, 5000) != JOUBAKO_OK ||
      joubako_client_set_max_response_bytes(client, 65536) != JOUBAKO_OK) {
    fprintf(stderr, "could not configure Joubako client\n");
    joubako_client_free(client);
    return 1;
  }

  JoubakoResponse *validation = NULL;
  if (joubako_request_json(
      client, "POST", "api/messages", "{broken", &validation) !=
      JOUBAKO_ERROR_CODEC || validation == NULL) {
    fprintf(stderr, "invalid JSON was not rejected locally\n");
    joubako_client_free(client);
    return 1;
  }
  joubako_response_free(validation);

  time_t started = time(NULL);
  unsigned long cycles = 0;
  while ((duration_seconds > 0 &&
          (unsigned long)(time(NULL) - started) < duration_seconds) ||
         (duration_seconds == 0 && cycles < requested_cycles)) {
    int valid = 1;
    valid &= check_request(client, "GET", "api/health", NULL,
      JOUBAKO_OK, 200, "\"framework\":\"Prologue\"");
    valid &= check_request(client, "GET", "api/users/1", NULL,
      JOUBAKO_OK, 200, "\"name\":\"Prologue User\"");
    valid &= check_request(client, "POST", "api/messages",
      "{\"text\":\"Hello from the C ABI\",\"priority\":2}",
      JOUBAKO_OK, 201, "\"client\":\"c-abi-client\"");
    valid &= check_request(client, "POST", "api/messages",
      "{\"text\":\"Invalid priority\",\"priority\":0}",
      JOUBAKO_ERROR_HTTP_STATUS, 422, "\"error\":\"invalid message\"");
    valid &= check_request(client, "GET", "api/users/999", NULL,
      JOUBAKO_ERROR_HTTP_STATUS, 404, "\"error\":\"user not found\"");
    if (!valid) {
      joubako_client_free(client);
      return 1;
    }
    ++cycles;
    if (cycles % 1000ul == 0) {
      printf("cycles=%lu requests=%lu elapsed_seconds=%lu\n",
        cycles, cycles * 5ul, (unsigned long)(time(NULL) - started));
      fflush(stdout);
    }
    if (delay_ms > 0) sleep_milliseconds(delay_ms);
  }

  printf("completed cycles=%lu requests=%lu failures=0 elapsed_seconds=%lu\n",
    cycles, cycles * 5ul, (unsigned long)(time(NULL) - started));
  joubako_client_free(client);
  return 0;
}
