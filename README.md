# 🌊 Wave-BIN

**Alpha Test 1.0** | Full-featured raw binary compiler

> Complete Wave compiler as a raw binary blob. No OS required.

---

## Features (Full Parity with Wave-C)

- ✅ Variables with stack management
- ✅ Arithmetic: `+`, `-`, `*`, `/`
- ✅ Comparison: `==`, `!=`, `>`, `<`, `>=`, `<=`
- ✅ Conditions: `when { }`
- ✅ Loops: `loop { }`, `break`
- ✅ Functions: `fn name params { }`, `-> return`
- ✅ I/O: `out`, `byte`, `emit`
- ✅ System: `syscall.exit(n)`
- ✅ Unified Field: `unified { i: v, e: v, r: v }`
- ✅ Fate control: `fate on/off`
- ✅ Raw x86-64 output

---

## Build

```bash
# Requires nasm
nasm -f bin src/wavec.asm -o wavec.bin

# Size: 8KB
```

---

## Binary Format

```
Offset  Size  Content
0x00    4     Magic: 'WAVE'
0x04    1     Version: 1
0x05    1     Flags: 0
0x06    2     Entry offset
0x08    8     Reserved
0x10    ...   Compiler code
```

---

## API

```c
// Function signature
long compile(
    char* source,      // rdi - source code pointer
    long  source_len,  // rsi - source length
    char* output,      // rdx - output buffer
    long  output_size  // rcx - output buffer size
);
// Returns: output length, or negative on error
```

---

## Example: Linux Loader

```c
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>

int main() {
    // Load wavec.bin
    FILE* f = fopen("wavec.bin", "rb");
    fseek(f, 0, SEEK_END);
    size_t size = ftell(f);
    fseek(f, 0, SEEK_SET);
    
    // Map executable memory
    void* code = mmap(NULL, size, 
        PROT_READ | PROT_WRITE | PROT_EXEC,
        MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    fread(code, 1, size, f);
    fclose(f);
    
    // Source code
    char* src = 
        "out \"Hello from Wave-BIN!\\n\"\n"
        "x = 10\n"
        "y = 20\n"
        "sum = x + y\n"
        "syscall.exit(0)\n";
    
    char output[65536];
    
    // Call compiler (skip 16-byte header)
    typedef long (*compile_fn)(char*, long, char*, long);
    compile_fn compile = (compile_fn)(code + 16);
    
    long len = compile(src, strlen(src), output, sizeof(output));
    printf("Generated %ld bytes of machine code\n", len);
    
    return 0;
}
```

---

## Use Cases

- **Bootloaders** - Compile Wave before OS loads
- **Embedded** - No OS needed, just RAM
- **Custom OS** - Load and call directly
- **BIOS/UEFI** - Pre-OS compilation
- **JIT** - Runtime code generation

---

## Example Wave Code

```wave
# Works identically to Wave-C

unified {
    i: 0.8
    e: 0.2
    r: 0.9
}

fn add a b {
    -> a + b
}

result = add(10, 20)
out "Result: 30\n"

i = 0
loop {
    i = i + 1
    when i >= 10 { break }
}

syscall.exit(0)
```

---

## License

MIT License

Copyright © 2026 Jouly Mars (ZHUOLI MA)  
Rogue Intelligence LNC.

---

[📦 wave-c](https://github.com/joulyman/wave-c) · [📦 wave-asm](https://github.com/joulyman/wave-asm) · [🌐 Website](https://joulyman.github.io/wave-c)
