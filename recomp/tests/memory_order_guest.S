/* R1.05 litmus and stress fixtures (Win64). Litmus functions take rcx = per-iteration slots of
 * 256 bytes, rdx = iterations, r8 = one dword result per iteration, r9 = threads at the
 * per-iteration barrier (slot + 192), then on the stack the offsets of "mine" (r10) and "other"
 * (r11) within a slot. Bodies leave their result in eax and may use rdx; [rsp + 8] is a private
 * fence location (the caller's home space). */
.intel_syntax noprefix
.text

.macro LITMUS name
.globl guest_\name
.type guest_\name,@function
guest_\name:
    mov r10, [rsp + 40]
    mov r11, [rsp + 48]
    mov [rsp + 16], rdx
1:
    lock inc dword ptr [rcx + 192]
2:
    cmp dword ptr [rcx + 192], r9d
    jae 3f
    pause
    jmp 2b
3:
.endm

.macro LITMUS_END name
    mov dword ptr [r8], eax
    add rcx, 256
    add r8, 4
    dec qword ptr [rsp + 16]
    jnz 1b
    ret
.size guest_\name, .-guest_\name
.endm

/* Store buffering: store mine, fence, load other. Both loads 0 is forbidden with a fence. */
.macro SB name, fence:vararg
LITMUS \name
    mov dword ptr [rcx + r10], 1
    \fence
    mov eax, dword ptr [rcx + r11]
LITMUS_END \name
.endm

SB sb_none
SB sb_mfence, mfence
SB sb_lock_add, lock add dword ptr [rsp + 8], 0
SB sb_lock_or, lock or dword ptr [rsp + 8], 0
SB sb_lock_inc, lock inc dword ptr [rsp + 8]
SB sb_lock_xadd, lock xadd dword ptr [rsp + 8], eax
SB sb_xchg, xchg dword ptr [rsp + 8], eax

LITMUS sb_cas_fail
    mov dword ptr [rsp + 8], 0
    mov eax, 1
    mov dword ptr [rcx + r10], 1
    lock cmpxchg dword ptr [rsp + 8], r9d
    mov eax, dword ptr [rcx + r11]
LITMUS_END sb_cas_fail

LITMUS sb_cas_ok
    mov dword ptr [rsp + 8], 0
    xor eax, eax
    mov dword ptr [rcx + r10], 1
    lock cmpxchg dword ptr [rsp + 8], r9d
    mov eax, dword ptr [rcx + r11]
LITMUS_END sb_cas_ok

LITMUS sb_cas64_fail
    mov qword ptr [rsp + 8], 0
    mov eax, 1
    mov dword ptr [rcx + r10], 1
    lock cmpxchg qword ptr [rsp + 8], r9
    mov eax, dword ptr [rcx + r11]
LITMUS_END sb_cas64_fail

/* The locked store itself is the store: no separate fence. */
LITMUS rmw_xadd
    mov eax, 1
    lock xadd dword ptr [rcx + r10], eax
    mov eax, dword ptr [rcx + r11]
LITMUS_END rmw_xadd

LITMUS rmw_xchg
    mov eax, 1
    xchg dword ptr [rcx + r10], eax
    mov eax, dword ptr [rcx + r11]
LITMUS_END rmw_xchg

LITMUS rmw_cas
    xor eax, eax
    lock cmpxchg dword ptr [rcx + r10], r9d
    mov eax, dword ptr [rcx + r11]
LITMUS_END rmw_cas

/* The same with a vector store (plain stores after a release fence on arm64). */
.macro VSB name, fence:vararg
LITMUS \name
    mov eax, 1
    movd xmm1, eax
    movups xmmword ptr [rcx + r10], xmm1
    \fence
    mov eax, dword ptr [rcx + r11]
LITMUS_END \name
.endm

VSB vsb_none
VSB vsb_mfence, mfence
VSB vsb_lock_add, lock add dword ptr [rsp + 8], 0
VSB vsb_lock_xadd, lock xadd dword ptr [rsp + 8], eax
VSB vsb_xchg, xchg dword ptr [rsp + 8], eax

LITMUS vsb_cas_fail
    mov dword ptr [rsp + 8], 0
    mov eax, 1
    movd xmm1, eax
    movups xmmword ptr [rcx + r10], xmm1
    lock cmpxchg dword ptr [rsp + 8], r9d
    mov eax, dword ptr [rcx + r11]
LITMUS_END vsb_cas_fail

/* And with an unaligned scalar store and load. */
LITMUS usb_lock_add
    mov dword ptr [rcx + r10 + 1], 1
    lock add dword ptr [rsp + 8], 0
    mov eax, dword ptr [rcx + r11 + 1]
LITMUS_END usb_lock_add

LITMUS usb_cas_fail
    mov dword ptr [rsp + 8], 0
    mov eax, 1
    mov dword ptr [rcx + r10 + 1], 1
    lock cmpxchg dword ptr [rsp + 8], r9d
    mov eax, dword ptr [rcx + r11 + 1]
LITMUS_END usb_cas_fail

/* Message passing (r10 data, r11 flag); the reader returns flag * 2 + data: 2 is forbidden.
 * Also the IRIW writer and readers. */
LITMUS mp_writer
    mov dword ptr [rcx + r10], 1
    mov dword ptr [rcx + r11], 1
    xor eax, eax
LITMUS_END mp_writer

LITMUS mp_reader
    mov eax, dword ptr [rcx + r11]
    mov edx, dword ptr [rcx + r10]
    lea eax, [rdx + rax * 2]
LITMUS_END mp_reader

LITMUS mpv_writer
    mov eax, 1
    movd xmm1, eax
    movups xmmword ptr [rcx + r10], xmm1
    mov dword ptr [rcx + r11], 1
    xor eax, eax
LITMUS_END mpv_writer

LITMUS mpv_reader
    mov eax, dword ptr [rcx + r11]
    movups xmm0, xmmword ptr [rcx + r10]
    movd edx, xmm0
    lea eax, [rdx + rax * 2]
LITMUS_END mpv_reader

/* Load buffering: load other, store mine. Both 1 is forbidden. */
LITMUS lb
    mov eax, dword ptr [rcx + r11]
    mov dword ptr [rcx + r10], 1
LITMUS_END lb

/* 2+2W: mine = 1, other = 2. Final x == y == 1 is forbidden. */
LITMUS w22
    mov dword ptr [rcx + r10], 1
    mov dword ptr [rcx + r11], 2
    xor eax, eax
LITMUS_END w22

LITMUS iriw_writer
    mov dword ptr [rcx + r10], 1
    xor eax, eax
LITMUS_END iriw_writer

/* Stress: rcx = shared block, rdx = iterations, r8 = this thread's bit. Returns the sum of the
 * tickets its lock xadd saw. Counters: +0 xadd, +64 inc, +128 cas64 loop, +640 cas32 loop,
 * +192 xchg byte lock guarding +256 (plain qword) and +272 (two vector qwords), +576 cmpxchg
 * dword lock guarding +585 (unaligned qword), +384 dec, +448 add 3, +320 or bits. */
.globl guest_stress
.type guest_stress,@function
guest_stress:
    mov [rsp + 16], rdx
    xor r9d, r9d
    xor r11d, r11d
    bts r11d, r8d
1:
    mov eax, 1
    lock xadd dword ptr [rcx], eax
    add r9, rax
    lock inc dword ptr [rcx + 64]
    mov rax, [rcx + 128]
2:
    lea r10, [rax + 1]
    lock cmpxchg qword ptr [rcx + 128], r10
    jne 2b
    mov eax, [rcx + 640]
3:
    lea r10d, [rax + 1]
    lock cmpxchg dword ptr [rcx + 640], r10d
    jne 3b
4:
    mov al, 1
    xchg byte ptr [rcx + 192], al
    test al, al
    jz 6f
5:
    pause
    cmp byte ptr [rcx + 192], 0
    jne 5b
    jmp 4b
6:
    mov rax, [rcx + 256]
    inc rax
    mov [rcx + 256], rax
    movdqu xmm0, xmmword ptr [rcx + 272]
    pcmpeqd xmm1, xmm1
    psubq xmm0, xmm1
    movdqu xmmword ptr [rcx + 272], xmm0
    mov byte ptr [rcx + 192], 0
7:
    xor eax, eax
    mov r10d, 1
    lock cmpxchg dword ptr [rcx + 576], r10d
    je 9f
8:
    pause
    cmp dword ptr [rcx + 576], 0
    jne 8b
    jmp 7b
9:
    mov rax, [rcx + 585]
    inc rax
    mov [rcx + 585], rax
    mov dword ptr [rcx + 576], 0
    lock dec qword ptr [rcx + 384]
    lock add dword ptr [rcx + 448], 3
    lock or dword ptr [rcx + 320], r11d
    dec qword ptr [rsp + 16]
    jnz 1b
    mov rax, r9
    ret
.size guest_stress, .-guest_stress
