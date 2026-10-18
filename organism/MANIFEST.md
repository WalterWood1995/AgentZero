# AgentZero Organism — body map (Explorer scan)

Machine probed over `hw.py` (QEMU-hosted AgentZero kernel, 127.0.0.1:50000).
CPU: GenuineIntel, CPUID leaf1 EAX 0x00000663 (family 6).

| bus:dev.fn | vendor:device | class  | what it is (first guess)        | Agent owner |
|------------|---------------|--------|---------------------------------|-------------|
| 00:00.0    | 8086:1237     | 060000 | Host bridge (i440FX)            | host-bridge |
| 00:01.0    | 8086:7000     | 060100 | ISA bridge (PIIX3)              | isa-bridge  |
| 00:01.1    | 8086:7010     | 010180 | IDE storage (PIIX3) OFF-LIMITS  | (skipped)   |
| 00:01.3    | 8086:7113     | 068000 | ACPI / power mgmt (PIIX4)       | acpi-pm     |
| 00:02.0    | 1234:1111     | 030000 | VGA display controller          | vga-display |
| 00:03.0    | 8086:100e     | 020000 | Ethernet NIC (e1000)            | nic-e1000   |
