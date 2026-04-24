# Virtual Camera

Unified repository for the kernel driver and userland capture client.

## Components

- [**Driver**](driver-project/README.md) — Windows virtual camera driver using the AVStream minidriver (avshws).
- [**Software**](software-project/README.md) — High-performance userland capture client and broker system.

## Project Structure

```
virtual-webcam/
├── driver-project/     # Kernel-mode driver source
└── software-project/   # User-mode application and libraries
```

## Quick Start

Refer to the individual component READMEs for specific build and installation instructions.
