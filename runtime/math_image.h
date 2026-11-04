#ifndef SS_MATH_IMAGE_H
#define SS_MATH_IMAGE_H
#include <stddef.h>
#include <stdint.h>

/* Build-local data from the hash-pinned Microsoft SDK UCRT; never tracked in Git. */
typedef struct {
    uint32_t size, text_offset, text_size;
    const unsigned char *bytes;
    const uint32_t *relocs;
    size_t reloc_count;
    uint32_t exports[16];
} SsMathImage;
#endif
