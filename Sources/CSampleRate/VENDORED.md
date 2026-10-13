# libsamplerate (vendored)

- Upstream: https://github.com/libsndfile/libsamplerate
- Version: 0.2.2 (tag `0.2.2`, commit c96f5e3de9c4488f4e6c97f59f5245f22fda22f7)
- License: BSD-2-Clause, see `COPYING`.

## What is included

`samplerate.c`, `src_sinc.c`, `src_linear.c`, `src_zoh.c`, `common.h`, `fastest_coeffs.h`, `mid_qual_coeffs.h`
and `include/samplerate.h`, unmodified. `config.h` is MicBridge's replacement for the CMake-generated one:
it enables only `SRC_SINC_FASTEST` and `SRC_SINC_MEDIUM_QUALITY`, so `high_qual_coeffs.h` (9 MB) is not needed.

## Real-time use in MicBridge

`src_new`/`src_delete` allocate and are only called from the control thread. `src_process` and `src_reset`
do not allocate, lock or perform I/O (checked in 0.2.2: allocations exist only in `sinc_state_new`,
`sinc_filter_new`, `sinc_copy` and `sinc_close`). Note that `src_process` copies as much input as its
internal buffer can hold; MicBridge therefore feeds it only the input needed for each output block.
