.intel_syntax noprefix
.text

.globl guest_leaf
.type guest_leaf,@function
guest_leaf:
.Lleaf:
    lea rax, [rcx + rdx]
    ret
.size guest_leaf, .-guest_leaf

.globl guest_vtable
.type guest_vtable,@function
guest_vtable:
    sub rsp, 40
    mov rax, [rcx]
    mov rcx, rdx
    mov rdx, r8
    call [rax]
    add rsp, 40
    ret
.size guest_vtable, .-guest_vtable

.globl guest_tail
.type guest_tail,@function
guest_tail:
    jmp .Lleaf
.size guest_tail, .-guest_tail

.globl guest_indirect_tail
.type guest_indirect_tail,@function
guest_indirect_tail:
    mov rax, rcx
    mov rcx, rdx
    mov rdx, r8
    jmp rax
.size guest_indirect_tail, .-guest_indirect_tail

.globl guest_switch
.type guest_switch,@function
guest_switch:
    cmp ecx, 1
    ja .Ldefault
    lea r10, [rip + .Ltable]
    movsxd rax, dword ptr [r10 + rcx*4]
    add rax, r10
    jmp rax
.Lsum:
    lea rax, [rdx + r8]
    ret
.Ldifference:
    mov rax, rdx
    sub rax, r8
    ret
.Ldefault:
    mov rax, -1
    ret
.p2align 2
.Ltable:
    .long .Lsum-.Ltable, .Ldifference-.Ltable
.size guest_switch, .-guest_switch

.globl guest_host_call
.type guest_host_call,@function
guest_host_call:
    sub rsp, 56
    mov rax, rcx
    mov rcx, rdx
    mov rdx, r8
    mov r8, r9
    mov r9d, 4
    mov qword ptr [rsp + 32], 0x5566
    mov qword ptr [rsp + 40], 0x7788
    call rax
    add rsp, 56
    ret
.size guest_host_call, .-guest_host_call

.globl guest_capture_carry
.type guest_capture_carry,@function
guest_capture_carry:
.Lcapture_carry:
    setb al
    movzx eax, al
    ret
.size guest_capture_carry, .-guest_capture_carry

.globl guest_flags_direct
.type guest_flags_direct,@function
guest_flags_direct:
    sub rsp, 40
    cmp rcx, rdx
    call .Lcapture_carry
    add rsp, 40
    ret
.size guest_flags_direct, .-guest_flags_direct

.globl guest_flags_indirect
.type guest_flags_indirect,@function
guest_flags_indirect:
    sub rsp, 40
    cmp rcx, rdx
    call r8
    add rsp, 40
    ret
.size guest_flags_indirect, .-guest_flags_indirect

/* E3: flags across calls and returns. */
.globl guest_compare_return
.type guest_compare_return,@function
guest_compare_return:
.Lcompare_return:
    cmp rcx, rdx
    ret
.size guest_compare_return, .-guest_compare_return

/* The callee's flags reach the caller through its RET (the former return-flag gap). */
.globl guest_flags_return
.type guest_flags_return,@function
guest_flags_return:
    sub rsp, 40
    call .Lcompare_return
    setb al
    movzx eax, al
    add rsp, 40
    ret
.size guest_flags_return, .-guest_flags_return

.globl guest_keep_flags
.type guest_keep_flags,@function
guest_keep_flags:
.Lkeep_flags:
    mov eax, 7
    ret
.size guest_keep_flags, .-guest_keep_flags

/* Flags set before a call of a callee that neither reads nor writes them stay live after it. */
.globl guest_flags_through
.type guest_flags_through,@function
guest_flags_through:
    sub rsp, 40
    cmp rcx, rdx
    call .Lkeep_flags
    setb al
    movzx eax, al
    add rsp, 40
    ret
.size guest_flags_through, .-guest_flags_through

/* Flags dead across the call: the generator skips materializing them. */
.globl guest_flags_dead
.type guest_flags_dead,@function
guest_flags_dead:
    sub rsp, 40
    cmp rcx, rdx
    call .Lkeep_flags
    add eax, 1
    add rsp, 40
    ret
.size guest_flags_dead, .-guest_flags_dead

.globl guest_many_args
.type guest_many_args,@function
guest_many_args:
    mov qword ptr [rsp + 8], 0x1111
    mov qword ptr [rsp + 16], 0x2222
    mov qword ptr [rsp + 24], 0x3333
    mov qword ptr [rsp + 32], 0x4444
    lea rax, [rcx + rdx]
    add rax, r8
    add rax, r9
    .irp slot,40,48,56,64,72,80,88,96,104,112,120,128
    add rax, [rsp + \slot]
    .endr
    ret
.size guest_many_args, .-guest_many_args

.globl guest_float_call
.type guest_float_call,@function
guest_float_call:
    sub rsp, 56
    mov r11, rcx
    mov ecx, 11
    mov rax, 0x3ff8000000000000
    movq xmm1, rax
    mov r8d, 33
    mov eax, 0xc0100000
    movd xmm3, eax
    mov rax, 0x400a000000000000
    mov [rsp + 32], rax
    mov qword ptr [rsp + 40], 66
    call r11
    movd eax, xmm0
    add rsp, 56
    ret
.size guest_float_call, .-guest_float_call

.globl guest_struct_call
.type guest_struct_call,@function
guest_struct_call:
    sub rsp, 40
    mov r11, rcx
    mov rcx, rdx
    mov rdx, r8
    mov rax, 0x4004000000000000
    movq xmm2, rax
    mov r9d, 77
    call r11
    add rsp, 40
    ret
.size guest_struct_call, .-guest_struct_call

.macro shlx_test name, destination, value, count
.globl \name
.type \name,@function
\name:
    cmp rcx, rdx
    pushfq
    pop r9
    shlx \destination, \value, \count
    pushfq
    pop r10
    xor r10, r9
    mov [r8], r10
    ret
.size \name, .-\name
.endm
shlx_test guest_shlx64, rax, rcx, rdx
shlx_test guest_shlx32, eax, ecx, edx

.macro fp_scope name, padding
.globl \name
.type \name,@function
\name:
    sub rsp, 72
    mov [rsp + 40], rcx
    mov [rsp + 48], r8
    mov [rsp + 56], edx
    stmxcsr [rsp + 60]
    ldmxcsr [rsp + 56]
    mov eax, 0x3f800000
    movd xmm0, eax
    shufps xmm0, xmm0, 0
    movaps xmm2, xmm0
    mov eax, 0x33800000
    movd xmm1, eax
    shufps xmm1, xmm1, 0
    mov ecx, 16
.Lfp_up\@:
    addps xmm0, xmm1
    vfmadd231ps xmm0, xmm1, xmm2
    cvtss2sd xmm3, xmm0
    cvtsd2ss xmm3, xmm3
    movss xmm0, xmm3
    .rept \padding
    nop
    .endr
    sub ecx, 1
    jnz .Lfp_up\@
    mov rax, [rsp + 48]
    movups [rax], xmm0
    call [rsp + 40]
    mov eax, 0x3f800000
    movd xmm0, eax
    shufps xmm0, xmm0, 0
    movaps xmm2, xmm0
    mov eax, 0x33800000
    movd xmm1, eax
    shufps xmm1, xmm1, 0
    addps xmm0, xmm1
    vfmadd231ps xmm0, xmm1, xmm2
    cvtss2sd xmm3, xmm0
    cvtsd2ss xmm3, xmm3
    movss xmm0, xmm3
    mov rax, [rsp + 48]
    movups [rax + 32], xmm0
    xor dword ptr [rsp + 56], 0x6000
    ldmxcsr [rsp + 56]
    mov eax, 0x3f800000
    movd xmm0, eax
    shufps xmm0, xmm0, 0
    movaps xmm2, xmm0
    mov eax, 0x33800000
    movd xmm1, eax
    shufps xmm1, xmm1, 0
    mov ecx, 16
.Lfp_down\@:
    addps xmm0, xmm1
    vfmadd231ps xmm0, xmm1, xmm2
    cvtss2sd xmm3, xmm0
    cvtsd2ss xmm3, xmm3
    movss xmm0, xmm3
    sub ecx, 1
    jnz .Lfp_down\@
    mov rax, [rsp + 48]
    movups [rax + 16], xmm0
    ldmxcsr [rsp + 60]
    mov eax, 0xf00d
    add rsp, 72
    ret
.size \name, .-\name
.endm
fp_scope guest_fp_scope, 0
fp_scope guest_fp_regions, 5200

.globl guest_regions
.type guest_regions,@function
guest_regions:
    sub rsp, 40
    mov r10d, 3
    xor eax, eax
.Lregions_loop:
    cmp rcx, rdx
    .rept 1800
    nop
    .endr
    setb r11b
    movzx r11d, r11b
    add rax, r11
    test r8, r8
    jnz .Lregions_skip
    .rept 1800
    nop
    .endr
    add rax, 7
.Lregions_skip:
    .rept 1800
    nop
    .endr
    dec r10
    jz .Lregions_done
    test r8, r8
    jz .Lregions_loop
    lea r11, [rip + .Lregions_loop]
    jmp r11
.Lregions_done:
    mov rdx, rax
    call .Lleaf
    add rsp, 40
    ret
.size guest_regions, .-guest_regions

.macro scan name, stride
.globl \name
.type \name,@function
\name:
    std
    stc
    mov rax, rdx
.Lscan\@:
    cmp qword ptr [rcx], r8
    je .Lscan_done\@
    add rcx, \stride
    dec rax
    jne .Lscan\@
.Lscan_done\@:
    pushfq
    pop rdx
    cld
    mov [r9], rcx
    mov [r9 + 8], rax
    mov [r9 + 16], rdx
    mov eax, 0xcafe
    ret
.size \name, .-\name
.endm
scan guest_scan, 8
scan guest_scan_stride, 16

.globl guest_scan_oracle
.type guest_scan_oracle,@function
guest_scan_oracle:
.Lscan_oracle:
    cmp qword ptr [rcx], r15
    je .Lscan_oracle_done
    add rcx, 8
    dec rax
    jne .Lscan_oracle
.Lscan_oracle_done:
    pushfq
    pop rdx
    ret
.size guest_scan_oracle, .-guest_scan_oracle
