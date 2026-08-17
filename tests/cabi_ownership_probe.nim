import joubako/cabi

const OwnershipCycles = 1_000

for _ in 0 ..< OwnershipCycles:
  var clientHandle: pointer
  doAssert joubako_client_create(
    "http://127.0.0.1/", addr clientHandle
  ) == 0
  doAssert clientHandle != nil
  doAssert joubako_client_set_header(
    clientHandle, "x-joubako-probe", "ownership"
  ) == 0

  var responseHandle: pointer
  doAssert joubako_request_json(
    clientHandle, "POST", "local", "{broken", addr responseHandle
  ) == 16
  doAssert responseHandle != nil
  doAssert joubako_response_error_code(responseHandle) == 16
  doAssert joubako_response_status(responseHandle) == 0
  doAssert joubako_response_error_message_size(responseHandle) > 0

  joubako_response_free(responseHandle)
  joubako_client_free(clientHandle)
