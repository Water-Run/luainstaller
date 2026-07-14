# Lua 5.x Native Platform Compatibility Design

## Status

Approved from the requirements confirmed on 2026-07-14. Implementation may
proceed unattended, including local commits and a final push after every
required gate passes. No release tag or LuaRocks publication is authorized.

## Goal

Make `luainstaller` installable through LuaRocks and usable with every current
official Lua minor release from Lua 5.1 through Lua 5.5, while building native
same-environment bundles on Linux, macOS, Windows, and capability-compatible
POSIX systems. A finished bundle must run on a clean target without a `lua`
command or system Lua runtime.

## Supported Lua Contract

The package dependency is `lua >= 5.1, < 6.0`. The release matrix exercises
these exact upstream patch releases:

- Lua 5.1.5;
- Lua 5.2.4;
- Lua 5.3.6;
- Lua 5.4.8;
- Lua 5.5.0.

The implementation may accept a later Lua 5.x minor when its capabilities are
compatible, but documentation must distinguish accepted version ranges from
the exact versions exercised by the repository.

Lua 5.0 and every LuaJIT ABI are outside this release. A bundle uses the same
Lua major/minor ABI as its build interpreter, headers, runtime library, and
native Lua modules. Lua source semantics are not translated between minor
versions.

## Product and Artifact Portability

`luainstaller` is a portable packaging tool in the same sense that PyInstaller
is portable: the tool can run on multiple host families, but each generated
artifact targets one operating-system family, CPU architecture, system ABI,
and Lua ABI. The project does not claim that one generated executable runs on
unrelated targets.

The implementation must not use the repository's laboratory matrix as a
runtime whitelist. Linux, macOS, and Windows receive native backends. Other
POSIX hosts use capability detection and a generic POSIX backend when the
required compiler, runtime, loader, and filesystem primitives are available.
Unknown host names fail only when a required capability is absent or cannot be
verified.

Cross-compilation is not a product feature. In particular, remove the
Linux-to-Windows MinGW build path. An explicit target option may remain for API
compatibility, but it must either match the detected host family or return a
structured native-build-only diagnostic before any output mutation.

## Installation Contract

LuaRocks is the sole documented installation method:

```sh
luarocks install luainstaller
```

After installation, both `luai` and `luainstaller` must work without a source
checkout. The installed package discovers the active Lua interpreter ABI and
the corresponding header/library configuration through LuaRocks and native
platform capabilities. The user may override compiler and Lua development
locations explicitly, but ordinary LuaRocks installations must not require a
project-specific source installer.

`tools/install-source.sh` is removed from the release workflow and public
documentation. Tests must exercise an isolated `luarocks make`/install tree for
every supported Lua minor.

## Lua Compatibility Architecture

### Source syntax baseline

All files loaded by the product use syntax accepted by Lua 5.1. Product code
must not contain native bitwise operators, `goto`, labels, or other syntax
introduced after Lua 5.1. Test fixtures may contain later syntax only when the
test explicitly verifies version-specific parsing behavior.

### Compatibility module

`luainstaller.compat` owns version-neutral operations used by the rest of the
product:

- exact major/minor detection from `_VERSION`;
- version comparison and display;
- `load`/`loadstring` with text-only and environment behavior;
- `setfenv` behavior for Lua 5.1;
- `table.unpack`/`unpack` selection;
- `package.searchpath` fallback;
- protected close/result normalization where Lua versions differ;
- arithmetic 32-bit operations required by SHA-256 and base64 logic.

Modules consume these helpers instead of scattering `_VERSION` branches.
Cryptographic ownership remains SHA-256; compatibility must not downgrade to a
weaker digest.

### Generated Lua

Bundled bootstrap code is emitted in Lua 5.1-compatible syntax. Its module
loader uses the compatibility behavior needed by the bundle's selected Lua
minor, restores `package.loaded` correctly, preserves multiple return values,
and never loads embedded source as bytecode.

### Generated C

Launcher generation receives the selected Lua major/minor and emits a
compile-time check for that exact ABI. A small C compatibility header maps API
differences such as `luaL_loadbufferx` versus `luaL_loadbuffer` and protected
call signatures without weakening text-only loading guarantees.

The linked-runtime probe executes before publication and must report the same
major/minor as the build interpreter. Error messages name the expected and
observed versions rather than mentioning Lua 5.4 unconditionally.

## Native Platform Architecture

### Shared capability model

Platform detection reports facts rather than support decisions:

- normalized host family and architecture;
- executable suffix and native module extensions;
- compiler family and command;
- Lua include, library, and runtime locations;
- executable-location mechanism;
- filesystem and process capabilities needed by onefile.

The bundler selects a backend from these capabilities. Public validation must
not restrict target OS values to the laboratory matrix.

### Linux and generic POSIX

Prefer the active LuaRocks/Lua development configuration, then `pkg-config`,
then an explicit Lua prefix. Verify headers, link a probe, locate the exact
linked Lua runtime, and copy it into the bundle. Generic POSIX hosts may use an
explicit prefix when their loader inspection command differs from `ldd`.

Executable discovery uses the strongest native mechanism available, with a
verified `argv[0]`/PATH fallback for platforms without Linux `/proc` or macOS
APIs. Onefile compilation is enabled only when its no-follow, private-cache,
atomic-publication, and process-launch requirements can be enforced.

### macOS

Build natively. Continue supporting a static Lua prefix, and also consume the
active LuaRocks configuration when it identifies usable headers and a static
library. Preserve deterministic linker output and the existing executable-path
logic. Signing and notarization remain downstream release responsibilities.

### Windows

Build natively on Windows. Product execution must not require Bash, `find`,
`rm`, `cp`, `chmod`, `stat`, `ldd`, Wine, or other POSIX utilities.

The Windows backend provides native command quoting, regular-file/reparse
checks, directory traversal, private temporary directories, file copying,
compiler execution, and runtime DLL discovery. It accepts compiler information
from LuaRocks/environment configuration and detects GCC/MinGW, Clang, or MSVC
syntax. The physical Windows development machine with its existing GCC is the
required release execution environment; available Clang/MSVC paths receive
compile checks when present.

The generated launcher and onefile extractor retain the current Win32 path,
ACL, reparse-point, cache-pinning, and argument-forwarding defenses. Moving to
wide-character APIs is permitted where required to make native behavior
correct, and documentation must describe any remaining path-representation
condition as a technical constraint rather than a tested-device boundary.

## Clean Target Contract

Every release bundle must execute when:

- `lua`, `luac`, and LuaRocks are absent from `PATH`;
- `LUA_PATH`, `LUA_CPATH`, `LUA_INIT`, and versioned `LUA_INIT_*` variables are
  unset;
- `LD_LIBRARY_PATH`/`DYLD_LIBRARY_PATH` do not provide Lua;
- no system Lua shared library is needed by the launcher;
- only ordinary operating-system runtime libraries remain available.

Tests inspect the launcher's dynamic dependencies and prove that the selected
Lua runtime comes from the bundle or is statically linked. Both onedir and
onefile must pass this contract.

## Native Lua Modules

Native modules remain tied to their Lua ABI and target platform. The product
copies the exact module selected during discovery and does not translate it.
The test matrix builds compatible cjson, LuaFileSystem, LuaSocket/Pegasus, and
SQLite modules for the Lua minors where upstream sources support them.

An unavailable third-party release may be reported as a dependency-specific
matrix limitation, but it must not skip the pure-Lua core, launcher, onedir,
onefile, or clean-target gate for that Lua minor.

## Backward Compatibility

Preserve:

- both CLI personalities and their separate grammars;
- the public Lua API and structured error shape;
- static, runtime, and manual dependency discovery;
- manifest schema version 2 and SHA-256 ownership records;
- generated-output ownership validation;
- safe rebuild/backup semantics;
- onefile content identity and cache defenses;
- existing logs where their format is valid.

Old v2 bundles remain recognizable. Changing the Lua version of an input build
produces a distinct manifest and payload identity and never reuses an
ABI-incompatible onefile cache.

## Test Architecture

### Portable interpreter selection

Every test receives an absolute interpreter command. Child processes inherit
that command even when a test intentionally narrows `PATH`; no test may assume
the executable is named `lua`. Test subprocess quoting is platform-specific.

### Repository transport

Release scripts transmit canonical Git object bytes or enforce LF for every
text source. A Windows checkout with `core.autocrlf=true` must not make a remote
release run fail. `.gitattributes` records explicit line-ending policy for Lua,
shell, C, AsciiDoc, rockspec, and text files.

### Version matrix

For each of Lua 5.1.5, 5.2.4, 5.3.6, 5.4.8, and 5.5.0, run:

1. syntax checks under that interpreter;
2. CLI grammar and version output;
3. documentation contracts;
4. production-edge tests applicable to the platform;
5. static and runtime dependency discovery;
6. isolated LuaRocks installation;
7. native onedir build and clean-target execution;
8. onefile build, cache reuse, and clean-target execution;
9. deterministic rebuild and failed-rebuild preservation.

### Physical device matrix

The complete latest-Lua application and security matrix runs on:

- the local physical Windows x86_64 machine;
- Debian 13.6 x86_64 (`yynicepc`);
- Rocky Linux 10.2 x86_64 (`waterrun`);
- Ubuntu 24.04.4 aarch64 on NVIDIA DGX Spark;
- Apple M4 Mac mini (`yymac06`);
- Apple M4 Max Mac Studio (`yymacstudio`).

Each OS family also runs the complete core/package matrix for every Lua minor.
The physical Windows machine replaces the old Windows VM requirement. Wine is
not a substitute and is no longer a required gate because cross-building is
removed.

No output containing an unexplained skip is a release pass. A deliberately
inapplicable third-party native-module case is recorded separately from core
results.

## Documentation

Update the README, usage guide, bundling guide, platform/native guide,
troubleshooting guide, implementation guide, testing guide, manual page,
rockspec metadata, and test/sample READMEs affected by command changes.

Documentation uses two separate concepts:

- capability contract: what a host and target must provide;
- tested-device matrix: exact hardware, OS, architecture, Lua versions, and
  observed coverage.

Concrete devices never define the support boundary. Remove statements that
present Linux x86_64, Linux ARM64, macOS ARM64, or Windows x86_64 as the only
supported targets. Add a changelog/release note for 1.0.0. Display the license
consistently as `LGPL-3.0-or-later` and include the license texts/notices needed
by that declaration.

## Release and Git Policy

The intended release remains 1.0.0. The rockspec source tag may name `v1.0.0`,
but the tag is created only after all gates pass and is not part of this task.

Implementation may create focused local commits. Before the authorized final
push:

- the primary working tree is clean except for intended committed changes;
- every required local and physical-device gate is green;
- the pushed branch contains the exact verified commit;
- no force push, release tag, LuaRocks publication, or unrelated file is
  included.

If an external physical device is unreachable, the work continues on all
independent areas, but the final push does not claim release readiness until
the required gate is restored and passes.
