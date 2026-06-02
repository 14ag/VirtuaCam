# VirtuaCam Research Paper Notes

Generated after approval for the research blueprint. PDFs in this folder were downloaded for local reference and skimmed with Python `pypdf` using UTF-8 output.

## Downloaded PDFs

| File | Source | Notes |
| --- | --- | --- |
| `gpusync-rtss13c.pdf` | https://www.cs.unc.edu/~anderson/papers/rtss13c.pdf | Real-time GPU management framework. Useful for synchronization, budget, affinity, and DMA-aware scheduling concepts. |
| `globally-scheduled-real-time-multiprocessor-systems-with-gpus-rtns10.pdf` | https://www.cs.unc.edu/~anderson/papers/rtns10.pdf | Models GPU use as shared/non-preemptive resource work. Useful for frame deadline budgeting. |
| `elliott-real-time-gpu-scheduling-dissertation-2015.pdf` | https://www.cs.unc.edu/~anderson/diss/glenndiss.pdf | Broad dissertation covering real-time GPU scheduling, interrupts, closed-source drivers, and jitter reduction. |
| `qos-monitoring-lock-free-streaming-overlays-2021.pdf` | https://link.springer.com/content/pdf/10.1007/s11042-020-10198-9.pdf | Open-access streaming paper using lock-free data structures for responsiveness and QoS monitoring. |
| `exploring-real-time-multi-gpu-configurations-rtss14c-long.pdf` | https://www.cs.unc.edu/~anderson/papers/rtss14c_long.pdf | Extra UNC paper. Useful for transfer-overhead and configuration sensitivity warnings. |

## Table Of Contents / First-Page Notes

### GPUSync

No PDF outline detected. First pages describe GPUSync as a real-time GPU management framework for multi-GPU multicore systems. Relevant concepts: synchronization-focused GPU management, predictable resource access, task/GPU affinity, DMA engine awareness, interrupt/worker thread handling, and budget policing despite non-preemptive GPU access.

### Globally Scheduled GPUs

Detected outline:

- Introduction
- Usage Patterns and Platform Constraints
- Task Model and Scheduling Algorithms
- Analysis Methods
- Shared Resource Method
- Container Method
- Evaluation
- Experimental Setup
- Results
- Implementation
- Future Work
- Conclusion

Implementation insight: model each producer/composite/upload path as periodic work with a deadline. Treat GPU execution and copies as resources with bounded budgets, not invisible implementation details.

### Elliott Dissertation

Detected outline starts with:

- Introduction
- Real-Time Systems
- Graphics Processing Units
- Real-Time GPU Applications
- GPGPU Programming
- Real-Time GPU Scheduling
- Real-Time Multi-GPU Scheduling
- Background and Prior Work
- Multiprocessor Real-Time Scheduling
- Locking Protocols
- Interrupt Handling
- GPGPU Mechanics

Implementation insight: add measurement and synchronization before optimization. For VirtuaCam, QPC-based frame telemetry and bounded publication protocols are safer first steps than speculative zero-copy rewrites.

### Lock-Free Streaming Overlays

Detected outline:

- Abstract
- Introduction
- Related work
- Tree-based overlay for real-time streaming
- QoS assessment
- QoS monitoring module
- Switch-to-fallback procedure
- Lock-free design and implementation
- From single tree to multi-tree overlay
- Experimental tests
- Results
- Conclusions and future work

Implementation insight: use atomic publication for producer status and broker reads. Favor single-writer status sidecars with odd/even sequence validation over mutex-heavy cross-process metadata reads.

### Real-Time Multi-GPU Configurations

No PDF outline detected. First pages emphasize that CPU/GPU organization and GPU management configuration strongly affect schedulability, and overheads matter. For VirtuaCam, this supports measuring copy counts, fence waits, and adapter mismatch failures before changing shared-resource flags.

## Applicability Limits

- UNC GPU scheduling work is mostly Linux/RTOS research. It informs scheduling model, budgeting, and measurement, not direct Windows API choices.
- NVIDIA GPUDirect is an industry reference for avoiding extra copies. VirtuaCam should not assume GPUDirect APIs are available for its virtual AVStream path.
- Microsoft AVStream, Media Foundation, and D3D docs decide Windows-specific implementation behavior.
- Hypothetical rows in `virtuacam-research.md` are search topics only, not citable evidence.
