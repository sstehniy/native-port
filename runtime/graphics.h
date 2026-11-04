#pragma once
#include <cstdint>

// Transfers one native COM reference to a guest-callable interface, preserving COM identity.
uint64_t rt_graphics_wrap(void *owned_interface);
// Borrows a native interface from a guest graphics object; null for an unknown object.
void *rt_graphics_native(uint64_t guest_interface);
