/* R1.06 fixtures (Win64). guest_cpuid has the shape of the game's own __cpuidex wrapper
 * (0x1405d6480): rcx = leaf, rdx = subleaf, r8 = four dwords out. */
.intel_syntax noprefix
.text

.globl guest_cpuid
.type guest_cpuid,@function
guest_cpuid:
    mov [rsp + 8], rbx
    mov eax, ecx
    mov ecx, edx
    cpuid
    mov [r8], eax
    mov [r8 + 4], ebx
    mov rbx, [rsp + 8]
    mov [r8 + 8], ecx
    mov [r8 + 12], edx
    ret
.size guest_cpuid, .-guest_cpuid

.globl guest_xgetbv
.type guest_xgetbv,@function
guest_xgetbv:
    xgetbv
    shl rdx, 32
    or rax, rdx
    ret
.size guest_xgetbv, .-guest_xgetbv
