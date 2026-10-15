# Plugin Build Strategies

This document describes the common build patterns, frameworks, and pitfalls
encountered when adding LV2 plugins to the builder. All plugins are built
natively on aarch64 (Raspberry Pi 5), not cross-compiled.

## Build Systems Overview

| Build system | Count | Typical flags/patterns |
|---|---|---|
| Make (plain) | ~119 | `make` / `make MOD=1` |
| Rust/Cargo | 17 | `cargo build --release` (nightly) |
| CMake | 13 | `cmake -B build && cmake --build build` |
| Meson | 7 | `meson setup build && meson compile -C build` |
| Make + DPF | 4 | `git submodule update && make` |
| Autotools | 3 | `autoreconf && ./configure && make` |

---

## DPF (DISTRHO Plugin Framework)

DPF is the most common framework for headless LV2 plugins. Plugins use it as
a git submodule and build with plain `make`.

### Key flags

```
HAVE_CAIRO=false      # Disable Cairo graphics (no X11 needed)
HAVE_OPENGL=false     # Disable OpenGL (no GPU/display needed)
MOD_BUILD=true        # Enable MOD-specific tweaks (some plugins)
BUILD_LV2=true        # Build LV2 format
BUILD_CLAP=           # Disable CLAP (empty = off)
BUILD_JACK=           # Disable standalone JACK
BUILD_VST2=           # Disable VST2
BUILD_VST3=           # Disable VST3
HEADLESS=true         # Disable all GUI (Cardinal, etc.)
NOOPT=true            # Disable x86-specific optimizations
```

Not all DPF plugins support all flags — check the Makefile. At minimum,
`HAVE_CAIRO=false HAVE_OPENGL=false` avoids X11 dependencies.

### Output

LV2 bundles land in `bin/*.lv2/`.

### Examples

```yaml
# Dragonfly Reverb
build:
  - make HAVE_CAIRO=false HAVE_OPENGL=false MOD_BUILD=true

# Wolf Shaper (explicit format selection)
build:
  - make BUILD_LV2=true BUILD_CLAP= BUILD_JACK= BUILD_VST2= BUILD_VST3= HAVE_OPENGL=false

# Cardinal (large, needs submodules)
build:
  - git submodule update --init --recursive
  - make -j2 lv2 mini HEADLESS=true NOOPT=true
```

### Submodules

DPF is always a submodule. `build.sh` clones the top-level repo without
recursing into submodules, rewrites any SSH-style URLs in `.gitmodules`
(`user@host:path`, `ssh://user@host/path`) to HTTPS so they can be fetched
without authentication (at every nesting level), and then resolves the
submodule tree itself — each child cloned with depth 1. Descriptor build
lines that also run `submodule update --init --recursive` are harmless no-ops.

---

## JUCE

JUCE-based plugins are the most complex to build headless. JUCE assumes a
desktop environment with display, audio, and MIDI. Building for an embedded
headless LV2 target requires patching.

### Common patches needed

1. **Force LV2-only output** — Override `JUCE_FORMATS`:
   ```cmake
   set(JUCE_FORMATS LV2)
   ```
   Without this, JUCE builds VST3, standalone, etc., pulling in unwanted deps.

2. **Disable GUI** — JUCE plugins typically use `foleys_gui_magic` or custom
   editors. For headless LV2, strip GUI code with `JUCE_AUDIOPROCESSOR_NO_GUI`
   or `CHOWDSP_USE_FOLEYS_CLASSES=0`, and remove `foleys_gui_magic` from
   `juce_add_modules()` and `target_link_libraries()`.

3. **Disable ALSA/JACK** — Prevents pkg-config lookups for audio backends
   that aren't needed for an LV2 plugin:
   ```cmake
   JUCE_JACK=0
   JUCE_ALSA=0
   ```
   Also patch `juce_audio_devices.h` to clear `linuxPackages: alsa`.

4. **Disable LV2 features** — mod-host doesn't use JUCE's latency reporting
   or state management:
   ```c
   JucePlugin_WantsLV2Latency=0
   JucePlugin_WantsLV2State=0
   JucePlugin_WantsLV2TimePos=0
   ```

5. **Disable LTO** — Can cause linker issues on aarch64. Remove `-flto` from
   `juce_recommended_lto_flags`.

6. **Fix RTNeural for ARM64** — Some plugins (AnalogTapeModel) need
   `USE_RTNEURAL_POLY=1` / `USE_RTNEURAL_STATIC=0` for aarch64 builds where
   SIMD intrinsics differ.

7. **Mono channel layout** — Guitar pedal plugins should be mono in/mono out.
   Force `JucePlugin_PreferredChannelConfigurations={1,1}` and patch
   `isBusesLayoutSupported()` to reject stereo.

8. **Bypass parameter** — LV2 expects an explicit bypass parameter. Override
   `getBypassParameter()` to return the plugin's bypass control.

### JUCE version matters

Plugins pin to specific JUCE versions via submodules. The patches are tightly
coupled to the JUCE version. Updating the plugin often means rewriting
patches. The mod-plugin-builder uses a shared system-wide JUCE install
(`find_package(JUCE-6.1.6 REQUIRED)`); for native builds we keep the bundled
JUCE submodule (`add_subdirectory(JUCE)`) which is simpler but means the
patches must match the bundled version.

### Dependencies

Even with GUI stripped, JUCE cmake still probes for X11/freetype:
```
libfreetype-dev libx11-dev libxrandr-dev libxinerama-dev libxcursor-dev
```

### Examples

```yaml
# Chow Centaur (4 patches for headless LV2)
build:
  - git submodule update --init --recursive
  - cmake -Bbuild -DCMAKE_BUILD_TYPE=Release -DSKIP_LV2_TTL_GENERATOR=ON
  - cmake --build build --config Release --parallel

# Surge XT (no patches needed, built-in cmake options)
build:
  - git submodule update --init --recursive
  - cmake -Bbuild -DCMAKE_BUILD_TYPE=Release -DSURGE_BUILD_LV2=TRUE -DSURGE_SKIP_VST3=TRUE -DSURGE_BUILD_CLAP=FALSE -DSURGE_SKIP_STANDALONE=TRUE
  - cmake --build build --config Release --target surge-xt_LV2 surge-fx_LV2 --parallel
```

### DISTRHO Ports (JUCE via Meson)

DISTRHO Ports wraps multiple JUCE plugins in a meson build with
`-Dlinux-headless=true` and pre-generated TTL files. This avoids per-plugin
patching. If a JUCE plugin is in DISTRHO Ports, prefer that route:

```yaml
build:
  - git submodule update --init --recursive
  - meson setup build --buildtype release -Dplugins=vitalium -Dbuild-lv2=true -Dbuild-vst2=false -Dbuild-vst3=false -Dlinux-headless=true
  - ninja -C build
```

---

## Rust/Cargo (davemollen plugins)

All `dm-*` plugins follow an identical pattern. They require Rust nightly.

```yaml
build:
  - source ~/.cargo/env && rustup default nightly
  - cd lv2
  - source ~/.cargo/env && cargo build --release
  - cd ..
  - source ~/.cargo/env && rustup default stable
install:
  - cd lv2
  - cp -v target/release/*.so *.lv2
  - cp -rv *.lv2 ${LV2_DIR}
  - cd ..
```

The `rustup default nightly` / `stable` dance ensures nightly is only used for
the build, not left as system default. Each plugin has the LV2 TTL files
pre-generated alongside the `lv2/` source directory.

No patching needed. No GUI dependencies. These are the easiest plugins to add.

---

## Guitarix Standalone Pedals (brummer10)

The `gx*` plugins are individual guitar pedals extracted from Guitarix. They
all live in separate repos (`github.com/brummer10/Gx*.lv2`) and follow the
same pattern:

```yaml
build:
  - make mod
install:
  - make install INSTALL_DIR=${LV2_DIR}
```

The `mod` target builds a headless LV2-only version without X11. Some older
plugins use `make nogui` instead. Check the Makefile.

No submodules, no external dependencies. To add a new brummer10 pedal:
1. Find the repo at `https://github.com/brummer10/Gx<Name>.lv2`
2. Check the Makefile for the headless target name (`mod` or `nogui`)
3. Check `make install` for the install variable (`INSTALL_DIR` or `PREFIX`)

### Main Guitarix (waf)

The main Guitarix build uses waf (Python-based build system) and produces
dozens of plugins at once:

```yaml
build:
  - cd trunk
  - ./waf configure --optimization --mod-lv2 --no-lv2-gui --no-standalone --prefix=/usr
  - ./waf
```

Key flags: `--mod-lv2` (MOD-compatible output), `--no-lv2-gui` (headless),
`--no-standalone` (skip JACK standalone).

---

## Meson

Meson-based plugins (airwindows, blop, fomp, mda, notes, tal-reverb) are
straightforward:

```yaml
build:
  - meson setup build -Dlv2dir=${LV2_DIR}
  - meson compile -C build
install:
  - meson install -C build
```

Some plugins (airwindows) produce many tiny bundles and need post-processing
to generate modgui TTL.

---

## Autotools

Rare in this collection. The pattern is:

```yaml
build:
  - autoreconf -vif
  - ./configure --disable-jack --disable-lv2-ui-x11 --prefix=/usr
  - make
install:
  - make install DESTDIR=<tmpdir>
  - cp -r <tmpdir>/usr/lib/lv2/*.lv2 ${LV2_DIR}/
```

Autotools plugins often install to a prefix, so use DESTDIR to capture the
output and copy just the LV2 bundles.

Key configure flags for headless builds:
- `--disable-jack` — no standalone
- `--disable-lv2-ui-x11` — no X11 UI
- `--disable-lv2-ui-external` — no external UI
- `--enable-lv2-port-event=no` — disable if not supported by host

---

## CMake (non-JUCE)

Simpler than JUCE. Most just need:

```yaml
build:
  - cmake -S . -B build -DCMAKE_BUILD_TYPE=Release -DBUILD_GUI=off
  - cmake --build build
```

Common cmake flags for headless builds:
- `-DBUILD_GUI=off` or `-DBUILD_GUI=OFF` (Aether, etc.)
- `-DGENERIC_AARCH64=ON` (aidadsp — uses aarch64-generic SIMD)
- `-DRTNEURAL_XSIMD=ON` (neural amp modelers — SIMD backend selection)

Install paths vary. Some use `cmake --install build --prefix=...`, others
use `make -C build install DESTDIR=...`.

---

## LSP Plugins

LSP uses its own build system (make-based with `config` target):

```yaml
build:
  - make config FEATURES='lv2' PREFIX=${PREFIX_DIR}
  - make fetch
  - make
install:
  - make install
```

The `FEATURES='lv2'` flag restricts output to LV2 only. `make fetch`
downloads build dependencies. Produces a single large bundle (`lsp-plugins.lv2`).

---

## Carla

Carla (falkTX) bundles several utility plugins. It has many optional features
that must be explicitly disabled:

```yaml
build:
  - make HAVE_DGL=false HAVE_FFMPEG=false HAVE_FLUIDSYNTH=false HAVE_HYLIA=false HAVE_LIBLO=false HAVE_PYQT=false HAVE_YSFX=false HAVE_X11=false USING_JUCE=false lv2-bundles
```

The `lv2-bundles` target builds only the LV2 plugins. Every `HAVE_*=false`
flag avoids an optional dependency.

---

## Heavy/hvcc (Pure Data to LV2)

Some plugins (wstd-dlay) are written in Pure Data and compiled to C via
the Heavy compiler (`hvcc`), then built as DPF plugins.

```yaml
build:
  - git submodule update --init --recursive
  - pip3 install --user git+https://github.com/Wasted-Audio/hvcc.git
  - make build
```

Requires Python 3 and pip. The `hvcc` tool generates a DPF project from `.pd`
files, then the standard DPF make flow takes over.

---

## modgui (plugin UI metadata)

Plugins need modgui TTL files for the web UI to show proper icons, controls,
and styling. Sources:

1. **Bundled** — Plugin repo includes `modgui/` directory in the LV2 bundle.
   Most MOD-ecosystem plugins (mod-*, brummer10) do this.

2. **Auto-generated** — The builder's `modgui` descriptor field triggers
   automatic modgui generation with brand/color/knob theming:
   ```yaml
   modgui:
     brand: Chow DSP
     color: green
     knob: silver
   ```

3. **From mod-plugin-builder** — The original mod-plugin-builder ships custom
   TTL/modgui overrides in `plugins/package/<name>/<Bundle>.lv2/`. These
   can be copied into an `overlay/` directory in the plugin folder and are
   applied after build.

4. **Missing** — Plugins without modgui get a default thumbnail in the web UI.
   They still work, just look generic.

---

## Common Pitfalls

### ARM64 SIMD
Many DSP plugins have x86 SSE/AVX code paths that fail on aarch64. Look for:
- `NOOPT=true` in make flags (DPF)
- `-DGENERIC_AARCH64=ON` in cmake
- RTNeural: use `POLY` mode instead of `STATIC` on ARM64
- Eigen/XSimd: check that the backend is aarch64-compatible

### LV2 TTL generation
JUCE plugins build a `lv2_ttl_generator` binary that introspects the plugin
`.so` and generates manifest/plugin TTL files. This works natively but fails
in cross-compilation (the generator is built for host arch but the `.so` is
target arch). For native builds, keep the generator; for cross-builds, use
`-DSKIP_LV2_TTL_GENERATOR=ON` and supply pre-generated TTL.

### Submodule depth
Submodule histories can be enormous (JUCE alone is ~1GB). The builder clones
the top level with `--depth 1`, marks every submodule at every nesting level
for a depth-1 clone (`submodule.<name>.shallow`), and only fetches more when
a pinned commit isn't reachable from its default branch tip. If the build
machine's git predates that setting, submodules fall back to full-history
fetches — still correct, just larger.

### Parallel builds
Use `--parallel` or `-jN` for cmake/make. On Pi 5 (4 cores, 8GB RAM),
`-j4` is safe for most plugins. JUCE and Cardinal can use significant RAM
during compilation — if builds fail with OOM, drop to `-j2`.
