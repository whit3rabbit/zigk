# x86_64 memcpy/memset helpers for freestanding builds.
# Uses rep movsq/stosq with byte remainder.

.text

# void *zk_memcpy(void *dest, const void *src, size_t n)
.global zk_memcpy
.type zk_memcpy, @function
zk_memcpy:
    cld
    mov %rdi, %rax
    mov %rdx, %rcx
    shr $3, %rcx
    rep movsq
    mov %rdx, %rcx
    and $7, %rcx
    rep movsb
    ret

# void *zk_memset(void *dest, int c, size_t n)
.global zk_memset
.type zk_memset, @function
zk_memset:
    cld
    mov %rdi, %r11
    mov %rsi, %rax
    movzbq %al, %rax
    movabs $0x0101010101010101, %r10
    imulq %r10, %rax
    mov %rdx, %rcx
    shr $3, %rcx
    rep stosq
    mov %rdx, %rcx
    and $7, %rcx
    rep stosb
    mov %r11, %rax
    ret
