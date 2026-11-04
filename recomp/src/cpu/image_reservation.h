#ifndef BB_IMAGE_RESERVATION_H
#define BB_IMAGE_RESERVATION_H
#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <mach-o/getsect.h>
#include <mach-o/ldsyms.h>
#include <stdint.h>

/* A host may link a zero-fill __GUEST reservation. Never replace somebody else's mapping. */
static inline kern_return_t bb_reserve_image(uint64_t base, uint64_t size) {
    unsigned long reserved_size = 0;
    const uint8_t *reserved = getsectiondata(&_mh_execute_header, "__GUEST", "__image", &reserved_size);
    const uint64_t start = (uint64_t)(uintptr_t)reserved;
    if (reserved && base >= start && base - start <= reserved_size && size <= reserved_size - (base - start))
        return KERN_SUCCESS;
    mach_vm_address_t address = base;
    return mach_vm_allocate(mach_task_self(), &address, size, VM_FLAGS_FIXED);
}
#endif
