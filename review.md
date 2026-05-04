## Memory Management and Resource Safety
Manual memory management is the primary vector for critical failures in C++ applications. A technical review must audit the lifecycle of every heap-allocated object.

*   **Smart Pointer Utilization:** Verify that `std::unique_ptr` and `std::shared_ptr` are used to enforce ownership semantics. Raw pointers should only be used for non-owning observers. Check for `new` and `delete` calls, which indicate a failure to follow RAII (Resource Acquisition Is Initialization) principles.
*   **Buffer Bounds:** Identify `memcpy`, `strcpy`, or direct array indexing that lacks explicit bounds checking. Modern alternatives like `std::copy`, `std::string`, or `std::vector::at()` are required for safety.
*   **Object Lifetime:** Search for potential use-after-free scenarios where a reference or pointer outlives the object it points to, particularly in asynchronous callbacks or multi-threaded contexts.

## Concurrency and Synchronization
C++ does not provide memory safety across threads by default. Reviewing the threading model is essential to prevent non-deterministic crashes.

*   **Race Conditions:** Audit shared mutable state. Every access to a shared variable must be protected by a `std::mutex`, `std::shared_mutex`, or implemented using `std::atomic` operations.
*   **Deadlock Risks:** Examine lock acquisition orders. Nested locks should follow a consistent hierarchy or use `std::scoped_lock` to acquire multiple mutexes atomically.
*   **Thread Safety of Dependencies:** Confirm that third-party libraries or internal components called from multiple threads are explicitly thread-safe or encapsulated within a thread-safe wrapper.

## Undefined Behavior and Integer Safety
C++ allows for operations that result in undefined behavior (UB), which compilers may optimize in ways that introduce security flaws.

*   **Integer Overflow/Underflow:** Arithmetic operations on `int` or `size_t` must be checked if they originate from external input. Use `std::numeric_limits` to validate bounds before execution.
*   **Strict Aliasing:** Ensure the code does not violate strict aliasing rules by casting pointers to unrelated types, which can cause the compiler to generate incorrect machine code.
*   **Uninitialized Variables:** Verify that all member variables are initialized in constructors. Use tools like `valgrind` or AddressSanitizer (ASan) during the dynamic analysis phase to catch uninitialized reads.

## Modern Standards Adherence
Code written in C++20 or C++23 should leverage language features that reduce boilerplate and improve type safety.

*   **The Rule of Five/Zero:** If a class defines a destructor, it must also define or delete the copy/move constructors and assignment operators. Ideally, classes should follow the Rule of Zero by using components that manage their own resources.
*   **Const Correctness:** Audit the usage of `const` for member functions and parameters. Lack of `const` correctness indicates poor encapsulation and allows for unintended state mutations.
*   **Type Safety:** Prefer `enum class` over plain `enum` to prevent implicit integer conversions. Use `std::variant` or `std::optional` instead of sentinel values (like `nullptr` or `-1`) to represent optional or multi-type data.

## Static and Dynamic Analysis Integration
A manual review should be supplemented by automated tooling output.

*   **Static Analysis:** Review reports from `clang-tidy`, `Cppcheck`, or MSVC static analyzer. Pay specific attention to "High" or "Critical" severity warnings regarding API misuse or logic errors.
*   **Runtime Sanitizers:** Analyze logs from AddressSanitizer (ASan), ThreadSanitizer (TSan), and UndefinedBehaviorSanitizer (UBSan). These tools catch issues that are often invisible during a static code walk, such as data races or heap buffer overflows.

## API and Logic Security
*   **Input Validation:** Every data point entering the application via network sockets, files, or IPC must be treated as untrusted. Validate lengths, types, and ranges before processing.
*   **Exception Safety:** Ensure the application maintains a consistent state when an exception is thrown. Functions should provide at least the basic exception guarantee, ensuring no resources are leaked.