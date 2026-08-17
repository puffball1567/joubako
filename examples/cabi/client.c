#include "joubako.h"

#include <stdio.h>

int main(void) {
  JoubakoClient *client = NULL;
  JoubakoResponse *response = NULL;

  if (joubako_client_create("http://127.0.0.1:8081/", &client) != JOUBAKO_OK) {
    fputs("could not create Joubako client\n", stderr);
    return 1;
  }

  JoubakoErrorCode code = joubako_request_json(
    client, "GET", "api/health", NULL, &response
  );
  if (response != NULL) {
    printf("status=%d body=%s\n",
      (int)joubako_response_status(response),
      joubako_response_body(response));
  }
  if (code != JOUBAKO_OK && response != NULL) {
    fprintf(stderr, "request failed: %s\n",
      joubako_response_error_message(response));
  }

  joubako_response_free(response);
  joubako_client_free(client);
  return code == JOUBAKO_OK ? 0 : 1;
}
