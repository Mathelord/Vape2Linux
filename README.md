# Vape2Linux

Proton 11 compatibility patch for running Vape on Linux

The patch implements blocking TCP `MSG_WAITALL` receives for Wine's internally nonblocking host sockets. Without it it will crash the game on injection.

## Tested environment

Tested on Arch linux with Vape Beta on Minecraft 1.8.9 

Vape lite and V3, V2 should also work but i have not tested them yet.
Newer Minecraft versions should also work

## Requirements

- Git, GCC and Make
- Autoconf, Flex, Bison and Python 3
- Standard 64-bit Wine development headers and libraries
- An installed copy of Proton 11.0-1b

## Usage

Make the script executable:

```bash
chmod +x vape2linux.sh
```

Run the script:

```bash
./vape2linux.sh
```

Press 2 for setup:

```text
1) Start Game :)
2) Setup
q) Quit
```

After thats done Run the script again and Press 1 and have fun
