BITS 64
ORG 0x18000FD00

start:
    ; Configure Hyper-V COM1 as 115200 baud, 8 data bits, no parity.
    mov dx, 0x03F9
    xor eax, eax
    out dx, al
    mov dx, 0x03FB
    mov al, 0x80
    out dx, al
    mov dx, 0x03F8
    mov al, 0x01
    out dx, al
    mov dx, 0x03F9
    xor eax, eax
    out dx, al
    mov dx, 0x03FB
    mov al, 0x03
    out dx, al
    mov dx, 0x03FA
    mov al, 0xC7
    out dx, al
    mov dx, 0x03FC
    mov al, 0x0B
    out dx, al

    ; Prefix the capture so the receiver can ignore unrelated serial data.
    mov eax, 0x314B4D56
    push rax
    mov rsi, rsp
    mov ecx, 4
    call send_bytes
    add rsp, 8

    ; The sample loader zeroes this 36-byte buffer and asks operation 6 to
    ; populate it immediately before jumping here.
    lea rsi, [rsp + 0x320]
    mov ecx, 36
    call send_bytes

    ; Stop before the loader changes the disk or transfers control to Windows.
    cli
.halt:
    hlt
    jmp .halt

send_bytes:
    mov dx, 0x03FD
.wait_ready:
    in al, dx
    test al, 0x20
    jz .wait_ready
    mov dx, 0x03F8
    lodsb
    out dx, al
    loop send_bytes
    ret
