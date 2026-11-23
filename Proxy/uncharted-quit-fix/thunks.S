# Signature-agnostic pass-throughs to D3DMetal for the exports the proxy doesn't touch (kept at their ordinals).
# First call: save the argument registers, ask uqf_resolve(index) for the real address, restore, jump.
.macro THUNK name, idx
    .globl \name
    .def \name; .scl 2; .type 32; .endef
\name:
    movq uqf_thunk_ptrs+8*\idx(%rip), %rax
    testq %rax, %rax
    jz 1f
    jmp *%rax
1:  pushq %rcx
    pushq %rdx
    pushq %r8
    pushq %r9
    subq $0x68, %rsp
    movdqu %xmm0, 0x20(%rsp)
    movdqu %xmm1, 0x30(%rsp)
    movdqu %xmm2, 0x40(%rsp)
    movdqu %xmm3, 0x50(%rsp)
    movl $\idx, %ecx
    call uqf_resolve
    movdqu 0x20(%rsp), %xmm0
    movdqu 0x30(%rsp), %xmm1
    movdqu 0x40(%rsp), %xmm2
    movdqu 0x50(%rsp), %xmm3
    addq $0x68, %rsp
    popq %r9
    popq %r8
    popq %rdx
    popq %rcx
    jmp *%rax
.endm
    .text
    THUNK GetBehaviorValue, 0
    THUNK D3D12CoreCreateLayeredDevice, 1
    THUNK D3D12CoreGetLayeredDeviceSize, 2
    THUNK D3D12CoreRegisterLayers, 3
