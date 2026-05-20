# VirtuaCam Microphone Driver Notice

Portions of this directory are derived from the Microsoft Simple Audio Sample Device Driver in the Windows Driver Samples repository.

Local changes make the sample capture-only for VirtuaCam:

- endpoint name: `VirtuaCam Microphone`
- no render endpoint installed
- fixed `48 kHz / 16-bit / stereo PCM` capture format
- secured IOCTL packet bridge from user-mode WASAPI capture
- silence on underrun with packet, underrun, and drop counters

Original sample license: Microsoft Public License, copied in `LICENSE-MS-PL.txt`.
