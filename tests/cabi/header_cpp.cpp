#include "joubako.h"

#include <type_traits>

static_assert(JOUBAKO_ABI_VERSION == 1u, "unexpected Joubako ABI version");
static_assert(std::is_enum<JoubakoErrorCode>::value, "error code must be an enum");

int main() {
  JoubakoClient *client = nullptr;
  JoubakoResponse *response = nullptr;
  (void)client;
  (void)response;
  return joubako_abi_version() == JOUBAKO_ABI_VERSION ? 0 : 1;
}
