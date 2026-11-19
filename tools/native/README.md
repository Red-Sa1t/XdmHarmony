# Native media processing

`entry/src/main/cpp` contains the production FFmpeg n6.0 / LAME 3.100 implementation.
The application loads `libxdm_media.so`; it never starts a bundled FFmpeg executable.
Host executables in this directory's test workflow are separate validation tools.

The public types are in `entry/src/main/cpp/types/libxdm_media/index.d.ts` and the
application adapter is `entry/src/main/ets/core/media/MediaProcessorNapi.ets`.

## Behavior and ownership

- `remux` maps all streams from two regular local files into MP4 or Matroska without
  decoding/re-encoding the media. It normalizes each input's container start time,
  preserves B-frame timestamps, interleaves both inputs and retains their unequal tails.
- H.264/HEVC TS input may lack dimensions after FFmpeg's decoder-free stream probe.
  The adapter uses the existing public parsers to recover missing dimensions while
  retaining every examined packet. This preparation is limited to 256 packets / 8 MiB,
  including packet side data, per input; exhausting it returns `RESOURCE_LIMIT`.
- `toMp3` selects the audio track using n6.0's default disposition/channel scoring,
  decodes, resamples, buffers complete encoder frames and uses **libmp3lame**. Decoder,
  resampler, FIFO and encoder tails all flush. Inputs above two channels downmix to stereo.
- Supported decoder profile: AAC, Vorbis, Opus, AC3, MP3, PCM16/24/32 and float32 little
  endian. Demuxers: MOV/MP4, Matroska/WebM, MPEG-TS, AAC/ADTS, MP3, WAV and Ogg.
  Capabilities indicate available operations; they do not claim every codec can remux
  into every container. Network demuxing and video decoding are not enabled.
- Metadata is copied. The largest valid supported PNG/JPEG cover can be copied into MP3.
  Encoded-picture headers supply the actual dimensions when the minimal FFmpeg profile
  cannot probe them. This is bounded structural parsing, not pixel decoding or artwork
  transcoding: PNG chunk lengths/order/CRC and JPEG marker/segment bounds are checked,
  including progressive scans, byte stuffing and restart markers. A picture is limited
  to 32 MiB, 32768 pixels per dimension and 64 * 1024 * 1024 pixels total.
  MP3 conversion skips malformed or unsupported optional art with `INVALID_COVER_ART`
  or `UNSUPPORTED_COVER_ART`; audio still converts. Remux retains its all-stream mapping
  contract and rejects malformed PNG/JPEG art with `UNSUPPORTED_STREAM` plus the warning.
  Chapter copying is not implemented; both operations report `CHAPTERS_NOT_COPIED`
  when applicable.
- Matroska's normal codec query omits some VFW/ACM formats accepted by its header writer.
  Only that muxer's public codec-tag table permits such a query rejection to proceed;
  the actual mux header remains authoritative, and MP4 compatibility is unchanged.
  AAC packet bytes survive remux, but this M4A-to-Matroska path does not preserve M4A's
  priming skip. The regression fixture consequently decodes 1024 more audio frames in
  Matroska, exactly matching the original FFmpeg CLI command. MP4 retains input-PCM
  equality. No new sample-trimming behavior is applied.
- Inputs are opened once and read through fd-backed custom AVIO. Output creation uses
  `O_EXCL`. No existing output is truncated, and inputs are never deleted by this layer.
- Success requires trailer/flush/fsync/close and a final path-to-inode/size check. A path
  renamed, unlinked or replaced during processing cannot become a successful result.
  Failure/cancellation removes only an owned pathname with matching device/inode.
  As with all path APIs, this check does not prevent another actor changing a file after
  the call returns; the downloader still owns final publication and conflict resolution.
- `outputPath` is empty on unsuccessful results. `cancel(id)` is true only when that
  call wins the state transition before commit. An accepted cancel and a successful
  commit are exclusive; the Promise settles after actual native cleanup.
- One operation runs process-wide. Cancellation/progress are isolated by NAPI environment.
  The ArkTS adapter has one active and at most 16 waiting jobs. Its optional fallback
  retries MP4 as Matroska only for `UNSUPPORTED_STREAM` or `INVALID_DATA`, using a separate
  caller-provided output path. Other errors and cancellations do not retry.
- Native work runs on a bounded `std::thread`. One completion TSFN and an async environment
  cleanup hook coordinate cancellation, join, registry release and Promise settlement.
  The TSFN queue does not carry per-frame progress. The ArkTS adapter polls at most once
  per second and clears its timer on completion, accepted cancellation or disposal.
  This replaces the initial spike design's `napi_async_work`, whose host teardown drained
  the job before the cleanup hook could cancel it. A `napi_closing` return is never followed
  by a second TSFN release.

## Build the application module

Prerequisites: the existing Windows OpenHarmony native SDK, Python, and the verified
`cpp/thirdparty` files already in the project. No host FFmpeg tool is required to build
or run the HarmonyOS application. The parent build must run different ABIs sequentially.
Do not overlap native builds with hvigor or another native compiler.

From `D:\git\HarmonyPC`, PowerShell:

```powershell
python XdmHarmony/tools/native/verify_artifacts.py
& XdmHarmony/tools/native/build_native.ps1 `
  -SdkRoot 'D:/Tools/DevEco Studio/sdk/default/openharmony/native' `
  -BuildRoot 'D:/git/HarmonyPC/migration-runs/202610080259/native-napi' `
  -Abi both -Runner
python XdmHarmony/tools/native/verify_artifacts.py `
  --sdk 'D:/Tools/DevEco Studio/sdk/default/openharmony/native' `
  --build-root migration-runs/202610080259/native-napi `
  --output migration-runs/202610080259/native-napi/verification.json
```

`-Runner` adds an optional standalone **target** driver for the same C++ implementation.
It does not execute it. CMake has a one-job Ninja compile/link pool and the script builds
the ABIs one after the other with `--parallel 1`.

Integration also requires `entry/build-profile.json5`'s `externalNativeOptions` and
both ABI filters, plus the local `libxdm_media.so` package in `entry/oh-package.json5` and
its generated lockfile. The project owner maintains these files, the P0-U4 ProbeIndex
registration and the localized `probe_p0u4_title` resources.

The tested SDK is OpenHarmony API24 / 6.1.1.125, clang 15.0.4. Its unused
`--gcc-toolchain` option emits an SDK warning; only that warning is exempt from `-Werror`.
Reusing a configured CMake tree can additionally report `CMAKE_TOOLCHAIN_FILE` as unused.
Those diagnostics are retained; this build is not described as warning-free.

## Rebuild FFmpeg and LAME dependencies

`build_dependencies.py` verifies the exact SHA512-pinned archives listed in
`import_artifacts.py`. Use `--archive-dir` for the already verified spike archives or
`--download` to fetch the pinned sources. No upstream source patches or system package
installation are performed. WSL needs Python 3.12+, make and its standard build tools.

For target dependencies, keep the work directory on a Windows-mounted drive so Windows
SDK executables can access it. WSL's `win_tool.py` translates compiler/linker paths.

```powershell
wsl -d Ubuntu -- python3 -u /mnt/d/git/HarmonyPC/XdmHarmony/tools/native/build_dependencies.py `
  --abi both --work /mnt/d/git/HarmonyPC/migration-runs/native-rebuild `
  --sdk '/mnt/d/Tools/DevEco Studio/sdk/default/openharmony/native' `
  --archive-dir /mnt/d/git/HarmonyPC/migration-runs/202610080259/native-spike
python XdmHarmony/tools/native/import_artifacts.py `
  --spike migration-runs/native-rebuild --verify-only
python XdmHarmony/tools/native/import_artifacts.py --spike migration-runs/native-rebuild
```

Both target manifests must be present before packaging. The importer accepts the original
spike layout or the new per-ABI `build-*-manifest.json` files. It verifies source archives
and all ten expected static libraries before copying. It never packages Linux host files.
The currently packaged libraries are from the already completed original dual-ABI spike;
the generalized target rebuild script has not been rerun end-to-end as part of this change.

Upstream licenses, source URLs and archive hashes are in `cpp/thirdparty/NOTICE`,
`licenses/` and `build-manifest.json`. Keep the corresponding source and relink materials
available when distributing these LGPL static dependencies; the surrounding application
retains its own license obligations.

## Reproduce host validation

Use an ext4 WSL scratch directory for host dependency extraction/builds. Extracting the
large upstream tree through `/mnt/d` was prohibitively slow. An interrupted extraction
is rejected on rerun unless its `.archive-sha512` marker matches; select a fresh scratch
directory instead of treating an incomplete tree as verified.

```powershell
wsl -d Ubuntu -- python3 -u /mnt/d/git/HarmonyPC/XdmHarmony/tools/native/build_dependencies.py `
  --abi host --work /tmp/xdm-native-host-20261008-0259 `
  --archive-dir /mnt/d/git/HarmonyPC/migration-runs/202610080259/native-spike
wsl -d Ubuntu -- python3 -u /mnt/d/git/HarmonyPC/XdmHarmony/tools/native/fetch_test_tools.py `
  --output /mnt/d/git/HarmonyPC/migration-runs/202610080259/native-test-tools
wsl -d Ubuntu -- python3 -u /mnt/d/git/HarmonyPC/XdmHarmony/tools/native/build_host_probe.py `
  --dependency-work /tmp/xdm-native-host-20261008-0259
wsl -d Ubuntu -- python3 -u /mnt/d/git/HarmonyPC/XdmHarmony/tools/native/make_fixtures.py `
  --ffmpeg /mnt/d/git/HarmonyPC/migration-runs/202610080259/native-test-tools/ffmpeg `
  --ffprobe /tmp/xdm-native-host-20261008-0259/test-tools/ffprobe `
  --output /mnt/d/git/HarmonyPC/XdmHarmony/tools/native/fixtures
wsl -d Ubuntu -- python3 -u /mnt/d/git/HarmonyPC/XdmHarmony/tools/native/build_host.py `
  --prefix /tmp/xdm-native-host-20261008-0259/prefix/host `
  --output /tmp/xdm-native-host-20261008-0259/core-cover-r2 `
  --node-headers /mnt/d/git/HarmonyPC/migration-runs/202610080259/native-test-tools/node-v18.19.1/include/node
```

Host GCC/binutils required `--disable-inline-asm` for upstream n6.0. This host-only change
is separate from the OHOS dependency configuration. Pinned npm ffmpeg/ffprobe archives
are integrity-verified; both tried npm ffprobe versions crashed on MPEG-TS under this WSL.
The matrix therefore uses the successfully source-built n6.0 ffprobe above, and the pinned
host FFmpeg for generation and independent decoding. No analyzer crash is counted as a pass.

Run the matrix and actual NAPI tests with **fresh output directories** on every execution:

```powershell
wsl -d Ubuntu -- python3 -u /mnt/d/git/HarmonyPC/XdmHarmony/tools/native/tests/media_core_test.py `
  --runner /tmp/xdm-native-host-20261008-0259/core-cover-r2/media_runner `
  --fixtures /mnt/d/git/HarmonyPC/XdmHarmony/tools/native/fixtures `
  --ffmpeg /mnt/d/git/HarmonyPC/migration-runs/202610080259/native-test-tools/ffmpeg `
  --ffprobe /tmp/xdm-native-host-20261008-0259/test-tools/ffprobe `
  --output /mnt/d/git/HarmonyPC/migration-runs/202610080259/native-core-tests/NEW_RUN
wsl -d Ubuntu -- node /mnt/d/git/HarmonyPC/XdmHarmony/tools/native/tests/napi_lifecycle_test.cjs `
  /tmp/xdm-native-host-20261008-0259/core-cover-r2/xdm_media.node `
  /mnt/d/git/HarmonyPC/XdmHarmony/tools/native/fixtures `
  /mnt/d/git/HarmonyPC/migration-runs/202610080259/native-napi-tests/NEW_RUN
node --test XdmHarmony/tools/native/tests/media-queue.test.cjs
```

The affected cover/chapters regression additionally needs Pillow 10.2.0 on the Linux
host to generate deterministic baseline, progressive and restart-marker JPEGs and a
palette PNG. Pillow is not a product dependency. Byte-identical copies of the original
independent-review fixtures and their hashes are persisted under
`native-cover-tests/original-fixtures`; the review's original files remain untouched.

```powershell
wsl -d Ubuntu -- python3 -u /mnt/d/git/HarmonyPC/XdmHarmony/tools/native/tests/media_cover_test.py `
  --runner /tmp/xdm-native-host-20261008-0259/core-cover-r2/media_runner `
  --fixtures /mnt/d/git/HarmonyPC/XdmHarmony/tools/native/fixtures `
  --original-cover-dir /mnt/d/git/HarmonyPC/migration-runs/202610080259/native-cover-tests/original-fixtures `
  --ffmpeg /mnt/d/git/HarmonyPC/migration-runs/202610080259/native-test-tools/ffmpeg `
  --ffprobe /mnt/d/git/HarmonyPC/migration-runs/202610080259/native-test-tools/ffprobe-n6.0 `
  --output /mnt/d/git/HarmonyPC/migration-runs/202610080259/native-cover-tests/NEW_RUN
```

Run its `--sanitizer-subset` against a separately built `build_host.py --sanitize`
runner with the strict environment options below. The subset keeps malformed-header,
dimension/length-overflow, JPEG scan/restart, original PNG/chapters and PNG remux checks;
it omits the extra JPEG M4A/remux and multiple-art cases already in the normal run.

The ArkTS FIFO test uses the project's existing TypeScript loader on Windows. The real
host addon test uses Node v18.19.1 and matching NAPI headers. `build_host.py --sanitize`
in a separate output directory adds AddressSanitizer/UndefinedBehaviorSanitizer to the
production C++ core and standalone driver; the existing dependency archives themselves
are not rebuilt with sanitizers. Run the same media matrix against that runner with
`UBSAN_OPTIONS=halt_on_error=1:print_stacktrace=1` and
`ASAN_OPTIONS=detect_leaks=1:halt_on_error=1` (WSL `env` arguments). The matrix preserves
native stderr and rejects sanitizer diagnostics even if a process returns zero.

Completed evidence for the 202610080259 run:

- `native-core-tests/run-final-01/results.json`: 36 checked cases, independent stream/
  timestamp inspection, decoded PCM/frame equality, MP3 signal/rate/channel/tail checks,
  real MP4 incompatibility/Matroska fallback, eight cancellation phases, IO failures,
  output replacement and input preservation.
- `native-core-tests/run-sanitized-strict-01/results.json`: the same 36 cases with the
  core/driver instrumented and halt-on-error settings. `native-stderr.log` records empty
  stderr for all 35 native invocations; the remaining case verifies input hashes. This
  strict run supersedes the earlier run that did not retain successful-process stderr.
- `native-napi-tests/run-final-01/results.json`: six groups, including 20 sequential jobs
  and 20 worker-environment terminations followed by registry reuse. The historical
  `terminateMs` field includes the follow-up job; the script now names it `terminateAndReuseMs`.
- `native-cover-tests/run-r2-02/results.json`: 30 affected regression cases on the final
  R2 core. Valid picture packets and independently decoded pixels match their originals;
  optional malformed/unsupported art leaves decoded MP3 audio equal to its control.
  PNG/JPEG remux also preserves AAC packet bytes and matches the original CLI's decoded
  audio, with the Matroska priming-frame delta explicitly recorded.
- `native-cover-tests/run-r2-sanitized-strict-01/results.json`: 25 affected cases with
  ASan/UBSan halt-on-error and leak detection. Both runs retain every process's exit and
  stderr in `commands.json`; sanitizer signatures are rejected even with exit zero.
  The failed `run-r2-01` is retained: its Matroska test incorrectly required equality
  with input PCM, whereas native and original-CLI PCM agree. Only that oracle changed.
- `u0-4-native-independent-review.md` and `native-spike/review-*-result.json`: independent
  review/regressions, including HEVC TS + ADTS and decoded-video equality. The reviewed
  C++/host scope closed all identified high/medium findings. Device execution and the new
  probe still need their own integration review.
- `native-napi/verification.json`: all 260 packaged files match their manifest, both shared
  libraries are ELF64 for their stated ABI, bundled symbols are hidden, and DT_NEEDED is
  exactly `libace_napi.z.so`, `libc++_shared.so`, `libc.so`.
- `native-host-builds/`: persistent dependency/core/sanitizer/tool build manifests. The
  verified source-built analyzer is also preserved at `native-test-tools/ffprobe-n6.0`
  (Linux executable, invoke through WSL), independently of the temporary build tree.

## Device acceptance

See [P0-U4 probe instructions](../../docs/probe/PROBE-u0-4-native-media.md) and the
[expectation table](../../docs/probe/EXPECT-u0-4-native-media.json).
The probe uses only three CC0 mathematical samples (121281 media bytes) from
`rawfile/native-media`; the 120-second cancellation input is generated in the sandbox.
Media outputs and detail JSON remain available for export and independent analysis.

Host success, target linking and nonempty files do not establish OHOS runtime or playback
acceptance. U0.4 remains gated on the actual HAP/device results and media checks recorded
by the main migration workflow. The downloader's assembly/publication integration is a
separate caller task; this module does not mark downloads complete or remove segments.
