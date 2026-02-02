; ═══════════════════════════════════════════════════════════════════════════
; Wave-BIN Alpha Test 1.0 - Complete Raw Binary Compiler
; 
; Full-featured Wave compiler as raw binary (no ELF headers).
; Loadable directly by bootloaders or embedded systems.
;
; Features (full parity with Wave-C):
;   - Unified Field (i, e, r) configuration
;   - Variables with stack management
;   - Arithmetic: +, -, *, /
;   - Comparison: ==, !=, >, <, >=, <=
;   - Conditions: when { }
;   - Loops: loop { }, break
;   - Functions: fn name params { }, -> return
;   - I/O: out, byte, emit, getchar, putchar
;   - System: syscall.exit(n)
;   - Fate: fate on/off
;   - Raw x86-64 output
;
; Build: nasm -f bin wavec.asm -o wavec.bin
;
; API:
;   Input:  rdi = source pointer
;           rsi = source length
;           rdx = output buffer pointer
;           rcx = output buffer size
;   Output: rax = generated code length (or negative on error)
;
; Copyright (c) 2026 Jouly Mars (ZHUOLI MA)
; Rogue Intelligence LNC.
; ═══════════════════════════════════════════════════════════════════════════

bits 64
org 0x0

; ───────────────────────────────────────────────────────────────────────────
; Header (16 bytes)
; ───────────────────────────────────────────────────────────────────────────
header:
    db 'WAVE'               ; Magic (4 bytes)
    db 1                    ; Version (1 byte)
    db 0                    ; Flags (1 byte)
    dw entry - header       ; Entry offset (2 bytes)
    dq 0                    ; Reserved (8 bytes)

; ───────────────────────────────────────────────────────────────────────────
; Constants
; ───────────────────────────────────────────────────────────────────────────
MAX_VARS    equ 256
MAX_FUNCS   equ 64
MAX_FIXUPS  equ 256
STACK_SIZE  equ 0x1000

; ───────────────────────────────────────────────────────────────────────────
; Entry point - Compiler function
; ───────────────────────────────────────────────────────────────────────────
entry:
    ; Save callee-saved registers
    push rbx
    push r12
    push r13
    push r14
    push r15
    push rbp
    mov rbp, rsp
    
    ; Allocate local storage
    sub rsp, 0x10000        ; 64KB for compiler state
    
    ; Store inputs
    mov [rbp-8], rdi        ; source_ptr
    mov [rbp-16], rsi       ; source_len
    mov [rbp-24], rdx       ; output_ptr
    mov [rbp-32], rcx       ; output_size
    
    ; Initialize state
    mov qword [rbp-40], 0   ; source_pos
    mov qword [rbp-48], 0   ; output_len
    mov qword [rbp-56], 0   ; var_count
    mov qword [rbp-64], 0   ; func_count
    mov qword [rbp-72], 8   ; stack_off
    mov qword [rbp-80], 0   ; loop_depth
    mov qword [rbp-88], 0   ; break_count
    mov qword [rbp-96], 500 ; unified_i
    mov qword [rbp-104], 500; unified_e
    mov qword [rbp-112], 500; unified_r
    mov qword [rbp-120], 1  ; fate_mode
    
    ; Variable storage at rbp-0x1000 to rbp-0x5000
    ; Function storage at rbp-0x5000 to rbp-0x8000
    ; Break fixups at rbp-0x8000 to rbp-0x9000
    ; Loop starts at rbp-0x9000 to rbp-0x9200
    ; Number temp at rbp-0x9100
    ; Ident buffer at rbp-0x9200 to rbp-0x9300
    ; String buffer at rbp-0x9300 to rbp-0xA300
    
    ; Initialize number temp
    mov qword [rbp-0x9100], 0
    
    ; First pass: collect functions
    call .collect_functions
    
    ; Reset position
    mov qword [rbp-40], 0
    
    ; Emit prologue
    call .emit_prologue
    
    ; Second pass: compile
.compile_loop:
    call .skip_ws
    mov rax, [rbp-40]
    cmp rax, [rbp-16]
    jge .compile_done
    call .compile_statement
    jmp .compile_loop
    
.compile_done:
    ; Return output length
    mov rax, [rbp-48]
    
    ; Cleanup
    add rsp, 0x10000
    pop rbp
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; ───────────────────────────────────────────────────────────────────────────
; Collect functions (first pass)
; ───────────────────────────────────────────────────────────────────────────
.collect_functions:
.cf_loop:
    call .skip_ws
    mov rax, [rbp-40]
    cmp rax, [rbp-16]
    jge .cf_done
    
    call .check_fn
    test al, al
    jz .cf_skip
    
    ; Parse 'fn name'
    add qword [rbp-40], 3   ; skip 'fn '
    call .skip_ws
    call .parse_ident
    
    ; Store function
    mov rax, [rbp-64]       ; func_count
    cmp rax, MAX_FUNCS
    jge .cf_done
    
    ; Copy name to func table (rbp-0x5000 + index*48)
    ; Each entry: name(32) + addr(8) + params(8)
    lea rdi, [rbp-0x5000]
    imul rcx, rax, 48
    add rdi, rcx
    lea rsi, [rbp-0x9200]   ; ident_buf
    mov rcx, 32
    rep movsb
    
    ; Set addr to 0 (will fill later)
    mov qword [rdi], 0
    mov qword [rdi+8], 0    ; param count (simplified)
    
    inc qword [rbp-64]
    
    ; Skip to end of function
    call .skip_to_brace_end
    jmp .cf_loop
    
.cf_skip:
    call .skip_line
    jmp .cf_loop
    
.cf_done:
    ret

.skip_to_brace_end:
    xor rcx, rcx
.stbe_loop:
    call .peek_char
    cmp al, 0
    je .stbe_done
    cmp al, '{'
    jne .stbe_check_close
    inc rcx
    jmp .stbe_next
.stbe_check_close:
    cmp al, '}'
    jne .stbe_next
    dec rcx
    cmp rcx, 0
    jl .stbe_done
.stbe_next:
    inc qword [rbp-40]
    jmp .stbe_loop
.stbe_done:
    inc qword [rbp-40]
    ret

; ───────────────────────────────────────────────────────────────────────────
; Emit prologue
; ───────────────────────────────────────────────────────────────────────────
.emit_prologue:
    mov al, 0x55            ; push rbp
    call .emit_byte
    mov al, 0x48            ; mov rbp, rsp
    call .emit_byte
    mov al, 0x89
    call .emit_byte
    mov al, 0xe5
    call .emit_byte
    mov al, 0x48            ; sub rsp, STACK_SIZE
    call .emit_byte
    mov al, 0x81
    call .emit_byte
    mov al, 0xec
    call .emit_byte
    mov eax, STACK_SIZE
    call .emit_dword
    ret

; ───────────────────────────────────────────────────────────────────────────
; Compile statement
; ───────────────────────────────────────────────────────────────────────────
.compile_statement:
    call .skip_ws
    call .peek_char
    
    cmp al, '#'
    je .cs_comment
    cmp al, 0
    je .cs_done
    cmp al, '}'
    je .cs_done
    
    ; Check keywords
    call .check_out
    test al, al
    jnz .cs_out
    
    call .check_byte
    test al, al
    jnz .cs_byte
    
    call .check_emit
    test al, al
    jnz .cs_emit
    
    call .check_syscall_exit
    test al, al
    jnz .cs_exit
    
    call .check_when
    test al, al
    jnz .cs_when
    
    call .check_loop
    test al, al
    jnz .cs_loop
    
    call .check_break
    test al, al
    jnz .cs_break
    
    call .check_fn
    test al, al
    jnz .cs_fn
    
    call .check_unified
    test al, al
    jnz .cs_unified
    
    call .check_fate
    test al, al
    jnz .cs_fate
    
    ; Identifier
    call .peek_char
    call .is_alpha
    test al, al
    jz .cs_skip
    
    call .parse_ident
    call .skip_ws
    call .peek_char
    
    cmp al, '='
    je .cs_assign
    cmp al, '('
    je .cs_call
    jmp .cs_skip
    
.cs_comment:
    call .skip_line
    ret
    
.cs_out:
    call .compile_out
    ret
    
.cs_byte:
    call .compile_byte
    ret
    
.cs_emit:
    call .compile_emit
    ret
    
.cs_exit:
    call .compile_exit
    ret
    
.cs_when:
    call .compile_when
    ret
    
.cs_loop:
    call .compile_loop_stmt
    ret
    
.cs_break:
    call .compile_break
    ret
    
.cs_fn:
    call .compile_fn
    ret
    
.cs_unified:
    call .compile_unified
    ret
    
.cs_fate:
    call .compile_fate
    ret
    
.cs_assign:
    call .next_char
    call .skip_ws
    call .compile_expr
    call .store_var
    ret
    
.cs_call:
    call .compile_call
    ret
    
.cs_skip:
    call .skip_line
    ret
    
.cs_done:
    ret

; ───────────────────────────────────────────────────────────────────────────
; Compile 'out "string"'
; ───────────────────────────────────────────────────────────────────────────
.compile_out:
    add qword [rbp-40], 3
    call .skip_ws
    call .next_char         ; skip "
    
    ; Parse string to buffer (use r12 instead of rdi, since peek_char modifies rdi)
    lea r12, [rbp-0xA300]
    xor rcx, rcx
.out_parse:
    call .peek_char
    cmp al, '"'
    je .out_done
    cmp al, 0
    je .out_done
    
    cmp al, '\'
    jne .out_normal
    
    inc qword [rbp-40]
    call .peek_char
    inc qword [rbp-40]
    
    cmp al, 'n'
    jne .out_not_n
    mov al, 10
    jmp .out_store
.out_not_n:
    cmp al, 't'
    jne .out_not_t
    mov al, 9
    jmp .out_store
.out_not_t:
    cmp al, 'x'
    jne .out_store
    call .parse_hex_byte
    jmp .out_store
    
.out_normal:
    inc qword [rbp-40]
    
.out_store:
    mov [r12 + rcx], al
    inc rcx
    jmp .out_parse
    
.out_done:
    inc qword [rbp-40]
    push rcx
    
    ; jmp over string
    mov al, 0xe9
    call .emit_byte
    mov eax, ecx
    call .emit_dword
    
    ; Emit string
    lea rsi, [rbp-0xA300]
    xor rdx, rdx
.out_emit:
    cmp rdx, rcx
    jge .out_emit_done
    push rcx
    push rdx
    mov al, [rsi + rdx]
    call .emit_byte
    pop rdx
    pop rcx
    inc rdx
    jmp .out_emit
    
.out_emit_done:
    pop rcx
    
    ; write syscall code
    ; mov rax, 1
    mov al, 0x48
    call .emit_byte
    mov al, 0xc7
    call .emit_byte
    mov al, 0xc0
    call .emit_byte
    mov eax, 1
    call .emit_dword
    
    ; mov rdi, 1
    mov al, 0x48
    call .emit_byte
    mov al, 0xc7
    call .emit_byte
    mov al, 0xc7
    call .emit_byte
    mov eax, 1
    call .emit_dword
    
    ; lea rsi, [rip - offset]
    ; offset = string_len + 21 (7+7+7 for instructions after lea)
    mov al, 0x48
    call .emit_byte
    mov al, 0x8d
    call .emit_byte
    mov al, 0x35
    call .emit_byte
    mov eax, ecx
    add eax, 21
    neg eax
    call .emit_dword
    
    ; mov rdx, len
    mov al, 0x48
    call .emit_byte
    mov al, 0xc7
    call .emit_byte
    mov al, 0xc2
    call .emit_byte
    mov eax, ecx
    call .emit_dword
    
    ; syscall
    mov al, 0x0f
    call .emit_byte
    mov al, 0x05
    call .emit_byte
    
    ret

; ───────────────────────────────────────────────────────────────────────────
; Compile 'byte(n)'
; ───────────────────────────────────────────────────────────────────────────
.compile_byte:
    add qword [rbp-40], 5   ; 'byte('
    call .skip_ws
    call .compile_expr
    call .skip_ws
    call .next_char         ; ')'
    
    ; sub rsp, 16
    mov al, 0x48
    call .emit_byte
    mov al, 0x83
    call .emit_byte
    mov al, 0xec
    call .emit_byte
    mov al, 16
    call .emit_byte
    
    ; mov [rsp], al
    mov al, 0x88
    call .emit_byte
    mov al, 0x04
    call .emit_byte
    mov al, 0x24
    call .emit_byte
    
    ; mov rax, 1
    mov al, 0x48
    call .emit_byte
    mov al, 0xc7
    call .emit_byte
    mov al, 0xc0
    call .emit_byte
    mov eax, 1
    call .emit_dword
    
    ; mov rdi, 1
    mov al, 0x48
    call .emit_byte
    mov al, 0xc7
    call .emit_byte
    mov al, 0xc7
    call .emit_byte
    mov eax, 1
    call .emit_dword
    
    ; lea rsi, [rsp]
    mov al, 0x48
    call .emit_byte
    mov al, 0x8d
    call .emit_byte
    mov al, 0x34
    call .emit_byte
    mov al, 0x24
    call .emit_byte
    
    ; mov rdx, 1
    mov al, 0x48
    call .emit_byte
    mov al, 0xc7
    call .emit_byte
    mov al, 0xc2
    call .emit_byte
    mov eax, 1
    call .emit_dword
    
    ; syscall
    mov al, 0x0f
    call .emit_byte
    mov al, 0x05
    call .emit_byte
    
    ; add rsp, 16
    mov al, 0x48
    call .emit_byte
    mov al, 0x83
    call .emit_byte
    mov al, 0xc4
    call .emit_byte
    mov al, 16
    call .emit_byte
    
    ret

; ───────────────────────────────────────────────────────────────────────────
; Compile 'emit "bytes"'
; ───────────────────────────────────────────────────────────────────────────
.compile_emit:
    add qword [rbp-40], 4
    call .skip_ws
    call .next_char         ; "
    
    lea rdi, [rbp-0xA300]
    xor rcx, rcx
.emit_parse:
    call .peek_char
    cmp al, '"'
    je .emit_done
    cmp al, 0
    je .emit_done
    
    cmp al, '\'
    jne .emit_normal
    inc qword [rbp-40]
    call .peek_char
    inc qword [rbp-40]
    cmp al, 'x'
    jne .emit_other
    call .parse_hex_byte
    jmp .emit_store
.emit_other:
    cmp al, 'n'
    jne .emit_store
    mov al, 10
    jmp .emit_store
    
.emit_normal:
    inc qword [rbp-40]
    
.emit_store:
    mov [rdi + rcx], al
    inc rcx
    jmp .emit_parse
    
.emit_done:
    inc qword [rbp-40]
    push rcx
    
    ; jmp over
    mov al, 0xe9
    call .emit_byte
    mov eax, ecx
    call .emit_dword
    
    ; emit bytes
    lea rsi, [rbp-0xA300]
    xor rdx, rdx
.emit_loop:
    cmp rdx, rcx
    jge .emit_loop_done
    push rcx
    push rdx
    mov al, [rsi + rdx]
    call .emit_byte
    pop rdx
    pop rcx
    inc rdx
    jmp .emit_loop
    
.emit_loop_done:
    pop rcx
    
    ; write syscall
    mov al, 0x48
    call .emit_byte
    mov al, 0xc7
    call .emit_byte
    mov al, 0xc0
    call .emit_byte
    mov eax, 1
    call .emit_dword
    
    mov al, 0x48
    call .emit_byte
    mov al, 0xc7
    call .emit_byte
    mov al, 0xc7
    call .emit_byte
    mov eax, 1
    call .emit_dword
    
    mov al, 0x48
    call .emit_byte
    mov al, 0x8d
    call .emit_byte
    mov al, 0x35
    call .emit_byte
    mov eax, ecx
    add eax, 19
    neg eax
    call .emit_dword
    
    mov al, 0x48
    call .emit_byte
    mov al, 0xc7
    call .emit_byte
    mov al, 0xc2
    call .emit_byte
    mov eax, ecx
    call .emit_dword
    
    mov al, 0x0f
    call .emit_byte
    mov al, 0x05
    call .emit_byte
    
    ret

; ───────────────────────────────────────────────────────────────────────────
; Compile 'syscall.exit(n)'
; ───────────────────────────────────────────────────────────────────────────
.compile_exit:
    add qword [rbp-40], 13  ; 'syscall.exit('
    call .skip_ws
    call .compile_expr
    call .skip_ws
    call .next_char         ; ')'
    
    ; mov rdi, rax
    mov al, 0x48
    call .emit_byte
    mov al, 0x89
    call .emit_byte
    mov al, 0xc7
    call .emit_byte
    
    ; mov rax, 60
    mov al, 0x48
    call .emit_byte
    mov al, 0xc7
    call .emit_byte
    mov al, 0xc0
    call .emit_byte
    mov eax, 60
    call .emit_dword
    
    ; syscall
    mov al, 0x0f
    call .emit_byte
    mov al, 0x05
    call .emit_byte
    
    ret

; ───────────────────────────────────────────────────────────────────────────
; Compile 'when condition { ... }'
; ───────────────────────────────────────────────────────────────────────────
.compile_when:
    add qword [rbp-40], 4
    call .skip_ws
    call .compile_expr
    
    ; test rax, rax
    mov al, 0x48
    call .emit_byte
    mov al, 0x85
    call .emit_byte
    mov al, 0xc0
    call .emit_byte
    
    ; jz end
    mov al, 0x0f
    call .emit_byte
    mov al, 0x84
    call .emit_byte
    mov rax, [rbp-48]
    push rax
    xor eax, eax
    call .emit_dword
    
    call .skip_ws
    call .next_char         ; '{'
    
.when_body:
    call .skip_ws
    call .peek_char
    cmp al, '}'
    je .when_done
    cmp al, 0
    je .when_done
    call .compile_statement
    jmp .when_body
    
.when_done:
    call .next_char
    
    ; Patch jump
    pop rax
    mov rcx, [rbp-48]
    sub rcx, rax
    sub rcx, 4
    mov rdi, [rbp-24]
    add rdi, rax
    mov [rdi], ecx
    
    ret

; ───────────────────────────────────────────────────────────────────────────
; Compile 'loop { ... }'
; ───────────────────────────────────────────────────────────────────────────
.compile_loop_stmt:
    add qword [rbp-40], 4
    call .skip_ws
    call .next_char         ; '{'
    
    ; Save loop start
    mov rax, [rbp-48]
    mov rcx, [rbp-80]
    lea rdi, [rbp-0x9000]
    mov [rdi + rcx*8], rax
    inc qword [rbp-80]
    
    mov qword [rbp-88], 0   ; reset break count
    
.loop_body:
    call .skip_ws
    call .peek_char
    cmp al, '}'
    je .loop_done
    cmp al, 0
    je .loop_done
    call .compile_statement
    jmp .loop_body
    
.loop_done:
    call .next_char
    
    ; jmp back
    mov al, 0xe9
    call .emit_byte
    dec qword [rbp-80]
    mov rcx, [rbp-80]
    lea rdi, [rbp-0x9000]
    mov rax, [rdi + rcx*8]
    mov rcx, [rbp-48]
    sub rax, rcx
    sub rax, 4
    call .emit_dword
    
    ; Patch breaks
    mov rcx, [rbp-88]
    test rcx, rcx
    jz .loop_no_breaks
    lea rsi, [rbp-0x8000]
    xor rdx, rdx
.loop_patch:
    cmp rdx, rcx
    jge .loop_no_breaks
    mov rax, [rsi + rdx*8]
    push rcx
    push rdx
    mov rcx, [rbp-48]
    sub rcx, rax
    sub rcx, 4
    mov rdi, [rbp-24]
    add rdi, rax
    mov [rdi], ecx
    pop rdx
    pop rcx
    inc rdx
    jmp .loop_patch
    
.loop_no_breaks:
    ret

; ───────────────────────────────────────────────────────────────────────────
; Compile 'break'
; ───────────────────────────────────────────────────────────────────────────
.compile_break:
    add qword [rbp-40], 5
    
    mov al, 0xe9
    call .emit_byte
    mov rax, [rbp-48]
    mov rcx, [rbp-88]
    lea rdi, [rbp-0x8000]
    mov [rdi + rcx*8], rax
    inc qword [rbp-88]
    xor eax, eax
    call .emit_dword
    
    ret

; ───────────────────────────────────────────────────────────────────────────
; Compile 'fn name params { ... }'
; ───────────────────────────────────────────────────────────────────────────
.compile_fn:
    add qword [rbp-40], 3
    call .skip_ws
    call .parse_ident
    
    ; Find function
    call .find_func
    cmp rax, -1
    je .fn_error
    push rax
    
    ; jmp over function
    mov al, 0xe9
    call .emit_byte
    mov rax, [rbp-48]
    push rax
    xor eax, eax
    call .emit_dword
    
    ; Set function address
    pop rcx
    pop rax
    push rcx
    push rax
    
    mov rcx, [rbp-48]
    lea rdi, [rbp-0x5000]
    imul r8, rax, 48
    add rdi, r8
    add rdi, 32
    mov [rdi], rcx
    
    ; Skip to {
.fn_skip:
    call .peek_char
    cmp al, '{'
    je .fn_found
    cmp al, 0
    je .fn_error
    inc qword [rbp-40]
    jmp .fn_skip
    
.fn_found:
    call .next_char
    
    ; Function prologue
    mov al, 0x55
    call .emit_byte
    mov al, 0x48
    call .emit_byte
    mov al, 0x89
    call .emit_byte
    mov al, 0xe5
    call .emit_byte
    mov al, 0x48
    call .emit_byte
    mov al, 0x81
    call .emit_byte
    mov al, 0xec
    call .emit_byte
    mov eax, 0x200
    call .emit_dword
    
.fn_body:
    call .skip_ws
    call .peek_char
    cmp al, '}'
    je .fn_done
    cmp al, 0
    je .fn_done
    
    ; Check return
    cmp al, '-'
    jne .fn_not_ret
    mov rax, [rbp-40]
    mov rdi, [rbp-8]
    cmp byte [rdi + rax + 1], '>'
    jne .fn_not_ret
    
    add qword [rbp-40], 2
    call .skip_ws
    call .compile_expr
    
    ; epilogue
    mov al, 0x48
    call .emit_byte
    mov al, 0x81
    call .emit_byte
    mov al, 0xc4
    call .emit_byte
    mov eax, 0x200
    call .emit_dword
    mov al, 0x5d
    call .emit_byte
    mov al, 0xc3
    call .emit_byte
    jmp .fn_body
    
.fn_not_ret:
    call .compile_statement
    jmp .fn_body
    
.fn_done:
    call .next_char
    
    ; Default return
    mov al, 0x48
    call .emit_byte
    mov al, 0x31
    call .emit_byte
    mov al, 0xc0
    call .emit_byte
    mov al, 0x48
    call .emit_byte
    mov al, 0x81
    call .emit_byte
    mov al, 0xc4
    call .emit_byte
    mov eax, 0x200
    call .emit_dword
    mov al, 0x5d
    call .emit_byte
    mov al, 0xc3
    call .emit_byte
    
    ; Patch jmp
    pop rax
    pop rcx
    mov rcx, [rbp-48]
    sub rcx, rax
    sub rcx, 4
    mov rdi, [rbp-24]
    add rdi, rax
    mov [rdi], ecx
    
    ret
    
.fn_error:
    ret

; ───────────────────────────────────────────────────────────────────────────
; Compile function call
; ───────────────────────────────────────────────────────────────────────────
.compile_call:
    call .find_func
    cmp rax, -1
    je .call_skip
    push rax
    
    call .next_char         ; '('
    
    ; Skip args for simplicity
.call_args:
    call .skip_ws
    call .peek_char
    cmp al, ')'
    je .call_do
    inc qword [rbp-40]
    jmp .call_args
    
.call_do:
    call .next_char
    
    pop rax
    lea rdi, [rbp-0x5000]
    imul rcx, rax, 48
    add rdi, rcx
    add rdi, 32
    mov rax, [rdi]
    
    test rax, rax
    jz .call_skip
    
    ; call rel32
    push rax
    mov al, 0xe8
    call .emit_byte
    pop rax
    mov rcx, [rbp-48]
    sub rax, rcx
    sub rax, 4
    call .emit_dword
    ret
    
.call_skip:
    call .next_char
.call_skip_loop:
    call .peek_char
    cmp al, ')'
    je .call_skip_done
    cmp al, 0
    je .call_skip_done
    inc qword [rbp-40]
    jmp .call_skip_loop
.call_skip_done:
    call .next_char
    ret

; ───────────────────────────────────────────────────────────────────────────
; Compile 'unified { ... }'
; ───────────────────────────────────────────────────────────────────────────
.compile_unified:
    add qword [rbp-40], 7
    call .skip_ws
    call .next_char
.unified_loop:
    call .skip_ws
    call .peek_char
    cmp al, '}'
    je .unified_done
    cmp al, 0
    je .unified_done
    inc qword [rbp-40]
    jmp .unified_loop
.unified_done:
    call .next_char
    ret

; ───────────────────────────────────────────────────────────────────────────
; Compile 'fate on/off'
; ───────────────────────────────────────────────────────────────────────────
.compile_fate:
    add qword [rbp-40], 4
    call .skip_ws
    call .peek_char
    cmp al, 'o'
    jne .fate_skip
    inc qword [rbp-40]
    call .peek_char
    cmp al, 'n'
    jne .fate_off
    inc qword [rbp-40]
    mov qword [rbp-120], 1
    ret
.fate_off:
    cmp al, 'f'
    jne .fate_skip
    add qword [rbp-40], 2
    mov qword [rbp-120], 0
    ret
.fate_skip:
    call .skip_line
    ret

; ───────────────────────────────────────────────────────────────────────────
; Compile expression
; ───────────────────────────────────────────────────────────────────────────
.compile_expr:
    call .skip_ws
    call .compile_term
    
.expr_check:
    call .skip_ws
    call .peek_char
    
    cmp al, '+'
    je .expr_add
    cmp al, '-'
    je .expr_sub
    cmp al, '*'
    je .expr_mul
    cmp al, '/'
    je .expr_div
    cmp al, '>'
    je .expr_gt
    cmp al, '<'
    je .expr_lt
    cmp al, '='
    je .expr_eq
    cmp al, '!'
    je .expr_neq
    
    ret
    
.expr_add:
    call .next_char
    mov al, 0x50
    call .emit_byte
    call .compile_term
    mov al, 0x59
    call .emit_byte
    mov al, 0x48
    call .emit_byte
    mov al, 0x01
    call .emit_byte
    mov al, 0xc8
    call .emit_byte
    jmp .expr_check
    
.expr_sub:
    call .next_char
    mov al, 0x50
    call .emit_byte
    call .compile_term
    mov al, 0x48
    call .emit_byte
    mov al, 0x89
    call .emit_byte
    mov al, 0xc1
    call .emit_byte
    mov al, 0x58
    call .emit_byte
    mov al, 0x48
    call .emit_byte
    mov al, 0x29
    call .emit_byte
    mov al, 0xc8
    call .emit_byte
    jmp .expr_check
    
.expr_mul:
    call .next_char
    mov al, 0x50
    call .emit_byte
    call .compile_term
    mov al, 0x59
    call .emit_byte
    mov al, 0x48
    call .emit_byte
    mov al, 0x0f
    call .emit_byte
    mov al, 0xaf
    call .emit_byte
    mov al, 0xc1
    call .emit_byte
    jmp .expr_check
    
.expr_div:
    call .next_char
    mov al, 0x50
    call .emit_byte
    call .compile_term
    mov al, 0x48
    call .emit_byte
    mov al, 0x89
    call .emit_byte
    mov al, 0xc1
    call .emit_byte
    mov al, 0x58
    call .emit_byte
    mov al, 0x48
    call .emit_byte
    mov al, 0x31
    call .emit_byte
    mov al, 0xd2
    call .emit_byte
    mov al, 0x48
    call .emit_byte
    mov al, 0xf7
    call .emit_byte
    mov al, 0xf9
    call .emit_byte
    jmp .expr_check
    
.expr_gt:
    call .next_char
    call .peek_char
    cmp al, '='
    je .expr_gte
    call .expr_cmp
    mov bl, 0x9f
    call .emit_setcc
    jmp .expr_check
.expr_gte:
    call .next_char
    call .expr_cmp
    mov bl, 0x9d
    call .emit_setcc
    jmp .expr_check
    
.expr_lt:
    call .next_char
    call .peek_char
    cmp al, '='
    je .expr_lte
    call .expr_cmp
    mov bl, 0x9c
    call .emit_setcc
    jmp .expr_check
.expr_lte:
    call .next_char
    call .expr_cmp
    mov bl, 0x9e
    call .emit_setcc
    jmp .expr_check
    
.expr_eq:
    mov rax, [rbp-40]
    mov rdi, [rbp-8]
    cmp byte [rdi + rax + 1], '='
    jne .expr_done
    add qword [rbp-40], 2
    call .expr_cmp
    mov bl, 0x94
    call .emit_setcc
    jmp .expr_check
    
.expr_neq:
    mov rax, [rbp-40]
    mov rdi, [rbp-8]
    cmp byte [rdi + rax + 1], '='
    jne .expr_done
    add qword [rbp-40], 2
    call .expr_cmp
    mov bl, 0x95
    call .emit_setcc
    jmp .expr_check
    
.expr_done:
    ret

.expr_cmp:
    mov al, 0x50
    call .emit_byte
    call .compile_term
    mov al, 0x59
    call .emit_byte
    mov al, 0x48
    call .emit_byte
    mov al, 0x39
    call .emit_byte
    mov al, 0xc1
    call .emit_byte
    ret

.emit_setcc:
    mov al, 0x0f
    call .emit_byte
    mov al, bl
    call .emit_byte
    mov al, 0xc0
    call .emit_byte
    mov al, 0x48
    call .emit_byte
    mov al, 0x0f
    call .emit_byte
    mov al, 0xb6
    call .emit_byte
    mov al, 0xc0
    call .emit_byte
    ret

; ───────────────────────────────────────────────────────────────────────────
; Compile term
; ───────────────────────────────────────────────────────────────────────────
.compile_term:
    call .skip_ws
    call .peek_char
    
    cmp al, '0'
    jl .term_not_num
    cmp al, '9'
    jle .term_num
    
.term_not_num:
    cmp al, '-'
    jne .term_ident
    mov rax, [rbp-40]
    mov rdi, [rbp-8]
    movzx eax, byte [rdi + rax + 1]
    cmp al, '0'
    jl .term_ident
    cmp al, '9'
    jg .term_ident
    
.term_num:
    call .parse_number
    mov al, 0x48
    call .emit_byte
    mov al, 0xb8
    call .emit_byte
    mov rax, [rbp-0x9100]
    call .emit_qword
    ret
    
.term_ident:
    call .peek_char
    call .is_alpha
    test al, al
    jz .term_zero
    
    call .parse_ident
    call .skip_ws
    call .peek_char
    cmp al, '('
    je .term_call
    
    call .load_var
    ret
    
.term_call:
    call .compile_call
    ret
    
.term_zero:
    mov al, 0x48
    call .emit_byte
    mov al, 0x31
    call .emit_byte
    mov al, 0xc0
    call .emit_byte
    ret

; ───────────────────────────────────────────────────────────────────────────
; Variable management
; ───────────────────────────────────────────────────────────────────────────
.store_var:
    call .find_var
    cmp rax, -1
    je .store_create
    
    lea rdi, [rbp-0x1000]
    imul rcx, rax, 40
    add rdi, rcx
    add rdi, 32
    mov rcx, [rdi]
    jmp .store_emit
    
.store_create:
    mov rax, [rbp-56]
    cmp rax, MAX_VARS
    jge .store_emit_zero
    
    lea rdi, [rbp-0x1000]
    imul rcx, rax, 40
    add rdi, rcx
    lea rsi, [rbp-0x9200]
    push rdi
    mov rcx, 32
    rep movsb
    pop rdi
    
    mov rcx, [rbp-72]
    mov [rdi + 32], rcx
    add qword [rbp-72], 8
    inc qword [rbp-56]
    
.store_emit:
    mov al, 0x48
    call .emit_byte
    mov al, 0x89
    call .emit_byte
    mov al, 0x85
    call .emit_byte
    neg ecx
    mov eax, ecx
    call .emit_dword
    ret
    
.store_emit_zero:
    ret

.load_var:
    call .find_var
    cmp rax, -1
    je .load_zero
    
    lea rdi, [rbp-0x1000]
    imul rcx, rax, 40
    add rdi, rcx
    add rdi, 32
    mov rcx, [rdi]
    
    mov al, 0x48
    call .emit_byte
    mov al, 0x8b
    call .emit_byte
    mov al, 0x85
    call .emit_byte
    neg ecx
    mov eax, ecx
    call .emit_dword
    ret
    
.load_zero:
    mov al, 0x48
    call .emit_byte
    mov al, 0x31
    call .emit_byte
    mov al, 0xc0
    call .emit_byte
    ret

.find_var:
    xor rcx, rcx
.fv_loop:
    cmp rcx, [rbp-56]
    jge .fv_not_found
    
    lea rdi, [rbp-0x1000]
    imul rax, rcx, 40
    add rdi, rax
    lea rsi, [rbp-0x9200]
    push rcx
    call .strcmp
    pop rcx
    test al, al
    jz .fv_found
    inc rcx
    jmp .fv_loop
    
.fv_found:
    mov rax, rcx
    ret
    
.fv_not_found:
    mov rax, -1
    ret

.find_func:
    xor rcx, rcx
.ff_loop:
    cmp rcx, [rbp-64]
    jge .ff_not_found
    
    lea rdi, [rbp-0x5000]
    imul rax, rcx, 48
    add rdi, rax
    lea rsi, [rbp-0x9200]
    push rcx
    call .strcmp
    pop rcx
    test al, al
    jz .ff_found
    inc rcx
    jmp .ff_loop
    
.ff_found:
    mov rax, rcx
    ret
    
.ff_not_found:
    mov rax, -1
    ret

; ───────────────────────────────────────────────────────────────────────────
; Helpers
; ───────────────────────────────────────────────────────────────────────────
.emit_byte:
    mov rdi, [rbp-24]
    add rdi, [rbp-48]
    mov [rdi], al
    inc qword [rbp-48]
    ret

.emit_dword:
    mov rdi, [rbp-24]
    add rdi, [rbp-48]
    mov [rdi], eax
    add qword [rbp-48], 4
    ret

.emit_qword:
    mov rdi, [rbp-24]
    add rdi, [rbp-48]
    mov [rdi], rax
    add qword [rbp-48], 8
    ret

.peek_char:
    mov rax, [rbp-40]
    cmp rax, [rbp-16]
    jge .pc_eof
    mov rdi, [rbp-8]
    movzx eax, byte [rdi + rax]
    ret
.pc_eof:
    xor eax, eax
    ret

.next_char:
    call .peek_char
    inc qword [rbp-40]
    ret

.skip_ws:
.sw_loop:
    call .peek_char
    cmp al, ' '
    je .sw_skip
    cmp al, 9
    je .sw_skip
    cmp al, 10
    je .sw_skip
    cmp al, 13
    je .sw_skip
    ret
.sw_skip:
    inc qword [rbp-40]
    jmp .sw_loop

.skip_line:
.sl_loop:
    call .peek_char
    cmp al, 10
    je .sl_done
    cmp al, 0
    je .sl_done
    inc qword [rbp-40]
    jmp .sl_loop
.sl_done:
    inc qword [rbp-40]
    ret

.is_alpha:
    cmp al, 'a'
    jl .ia_upper
    cmp al, 'z'
    jle .ia_yes
.ia_upper:
    cmp al, 'A'
    jl .ia_under
    cmp al, 'Z'
    jle .ia_yes
.ia_under:
    cmp al, '_'
    je .ia_yes
    xor eax, eax
    ret
.ia_yes:
    mov eax, 1
    ret

.is_alnum:
    push rax
    call .is_alpha
    test al, al
    jnz .ian_yes_pop
    pop rax
    cmp al, '0'
    jl .ian_no
    cmp al, '9'
    jle .ian_yes
.ian_no:
    xor eax, eax
    ret
.ian_yes_pop:
    pop rax
.ian_yes:
    mov eax, 1
    ret

.parse_ident:
    lea rdi, [rbp-0x9200]
    xor rcx, rcx
.pi_loop:
    call .peek_char
    push rax
    call .is_alnum
    test al, al
    pop rax
    jz .pi_done
    mov [rdi + rcx], al
    inc rcx
    inc qword [rbp-40]
    cmp rcx, 255
    jl .pi_loop
.pi_done:
    mov byte [rdi + rcx], 0
    ret

.parse_number:
    xor r8, r8              ; negative flag
    
    call .peek_char
    cmp al, '-'
    jne .pn_start
    mov r8, 1
    inc qword [rbp-40]
    
.pn_start:
    xor rax, rax            ; 初始化累加器为 0
    
.pn_parse:
    push rax
    call .peek_char
    mov rcx, rax
    pop rax
    cmp cl, '0'
    jl .pn_done
    cmp cl, '9'
    jg .pn_done
    imul rax, 10
    sub cl, '0'
    movzx rcx, cl
    add rax, rcx
    inc qword [rbp-40]
    jmp .pn_parse
    
.pn_done:
    test r8, r8
    jz .pn_pos
    neg rax
.pn_pos:
    mov [rbp-0x9100], rax
    ret

.parse_hex_byte:
    xor rax, rax
    call .peek_char
    inc qword [rbp-40]
    call .hex_digit
    shl al, 4
    mov ah, al
    call .peek_char
    inc qword [rbp-40]
    call .hex_digit
    or al, ah
    ret

.hex_digit:
    cmp al, '0'
    jl .hd_letter
    cmp al, '9'
    jg .hd_letter
    sub al, '0'
    ret
.hd_letter:
    cmp al, 'a'
    jl .hd_upper
    cmp al, 'f'
    jg .hd_upper
    sub al, 'a'
    add al, 10
    ret
.hd_upper:
    cmp al, 'A'
    jl .hd_zero
    cmp al, 'F'
    jg .hd_zero
    sub al, 'A'
    add al, 10
    ret
.hd_zero:
    xor al, al
    ret

.strcmp:
.sc_loop:
    mov al, [rdi]
    mov cl, [rsi]
    cmp al, cl
    jne .sc_neq
    test al, al
    jz .sc_eq
    inc rdi
    inc rsi
    jmp .sc_loop
.sc_eq:
    xor eax, eax
    ret
.sc_neq:
    mov eax, 1
    ret

; ───────────────────────────────────────────────────────────────────────────
; Keyword checks
; ───────────────────────────────────────────────────────────────────────────
.check_out:
    mov rax, [rbp-40]
    mov rdi, [rbp-8]
    add rdi, rax
    cmp byte [rdi], 'o'
    jne .co_no
    cmp byte [rdi+1], 'u'
    jne .co_no
    cmp byte [rdi+2], 't'
    jne .co_no
    mov eax, 1
    ret
.co_no:
    xor eax, eax
    ret

.check_emit:
    mov rax, [rbp-40]
    mov rdi, [rbp-8]
    add rdi, rax
    cmp dword [rdi], 'emit'
    jne .ce_no
    mov eax, 1
    ret
.ce_no:
    xor eax, eax
    ret

.check_byte:
    mov rax, [rbp-40]
    mov rdi, [rbp-8]
    add rdi, rax
    cmp dword [rdi], 'byte'
    jne .cb_no
    mov eax, 1
    ret
.cb_no:
    xor eax, eax
    ret

.check_syscall_exit:
    mov rax, [rbp-40]
    mov rdi, [rbp-8]
    add rdi, rax
    cmp dword [rdi], 'sysc'
    jne .cse_no
    cmp dword [rdi+4], 'all.'
    jne .cse_no
    cmp dword [rdi+8], 'exit'
    jne .cse_no
    mov eax, 1
    ret
.cse_no:
    xor eax, eax
    ret

.check_when:
    mov rax, [rbp-40]
    mov rdi, [rbp-8]
    add rdi, rax
    cmp dword [rdi], 'when'
    jne .cw_no
    mov eax, 1
    ret
.cw_no:
    xor eax, eax
    ret

.check_loop:
    mov rax, [rbp-40]
    mov rdi, [rbp-8]
    add rdi, rax
    cmp dword [rdi], 'loop'
    jne .cl_no
    mov eax, 1
    ret
.cl_no:
    xor eax, eax
    ret

.check_break:
    mov rax, [rbp-40]
    mov rdi, [rbp-8]
    add rdi, rax
    cmp dword [rdi], 'brea'
    jne .cbr_no
    cmp byte [rdi+4], 'k'
    jne .cbr_no
    mov eax, 1
    ret
.cbr_no:
    xor eax, eax
    ret

.check_fn:
    mov rax, [rbp-40]
    mov rdi, [rbp-8]
    add rdi, rax
    cmp byte [rdi], 'f'
    jne .cf_no
    cmp byte [rdi+1], 'n'
    jne .cf_no
    cmp byte [rdi+2], ' '
    jne .cf_no
    mov eax, 1
    ret
.cf_no:
    xor eax, eax
    ret

.check_unified:
    mov rax, [rbp-40]
    mov rdi, [rbp-8]
    add rdi, rax
    cmp dword [rdi], 'unif'
    jne .cu_no
    mov eax, 1
    ret
.cu_no:
    xor eax, eax
    ret

.check_fate:
    mov rax, [rbp-40]
    mov rdi, [rbp-8]
    add rdi, rax
    cmp dword [rdi], 'fate'
    jne .cfa_no
    mov eax, 1
    ret
.cfa_no:
    xor eax, eax
    ret

; ───────────────────────────────────────────────────────────────────────────
; Pad to 8KB
; ───────────────────────────────────────────────────────────────────────────
times 8192 - ($ - $$) db 0
