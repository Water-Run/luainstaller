# Production Hardening Design

## Objective

Bring the current Lua 5.4 packager to a fail-closed, production-grade state for
the supported Linux, macOS, and Windows profiles. The change must fix every
confirmed correctness or safety defect from the audit, add regression evidence
for each defect class, preserve documented behavior where it is intentional,
and push `main` only after the applicable local and remote release gates pass.

This change does not create or push a release tag. The existing rockspec tag is
a separate release action and must not be fabricated as part of a branch push.

## Compatibility Decisions

- Lua 5.4 is the only supported interpreter ABI. Source installation, runtime
  discovery, headers, `pkg-config`, and linked runtimes must all report Lua 5.4.
- Static discovery keeps the documented entry-rooted templates ahead of the
  active `package.path` and `package.cpath`. This is a packager convention, not
  a claim that raw `lua path/to/main.lua` changes Lua's search order.
- The existing `./` and `../` module-name extension remains supported and is
  documented as luainstaller behavior.
- Runtime discovery must use the file actually selected by `require`, even when
  the entry changes `package.path` or uses another Lua 5.4 interpreter.
- Bundle lookup remains same-environment rather than becoming hermetic in this
  change. Embedded modules retain precedence, while undeclared modules may
  still fall through to host searchers as documented.
- Manual includes are Lua source files. Direct inclusion of directories,
  devices, or arbitrary binary files is rejected.
- Existing `luainstaller-generated-output-v1` directories are never trusted for
  automatic replacement after this change. Users remove them explicitly once;
  all newly generated directories use the v2 ownership format.

## Component Boundaries

### Checked filesystem and hashing primitives

Add small internal modules with single responsibilities:

- `luainstaller.fs` performs checked binary reads and writes. It distinguishes
  open, read, write, flush, and close failures and never converts a failed read
  into an empty file.
- `luainstaller.hash` exposes deterministic `sha256(content)` and retains
  `fnv1a32(content)` only where backward-compatible internal tests need it.
  SHA-256 known vectors and differential checks against the host tool prove the
  implementation.

All manifest content hashes, ownership hashes, source-consistency checks, and
onefile payload IDs use SHA-256. Generated Lua source remains dependency-free.

### Source validation and static discovery

Every entry and included Lua source is read successfully and compiled with
`load(..., "t", {})` before a build can succeed. UTF-8 BOM and shebang handling
matches the generated runtime while preserving source line numbering. Invalid
syntax returns a structured `LuaSyntaxError`; unreadable or non-file input
returns a structured filesystem or script error.

The require lexer gains a trivia skipper that understands Lua whitespace,
line comments, and long comments. It must:

- accept comments between `require`, parentheses, commas, and literals;
- decode short and long literals with Lua's own text parser;
- apply Lua long-string initial-newline and newline-normalization rules;
- record the line containing the `require` token;
- accept legal result concatenation such as `require "x" .. suffix`;
- reject concatenation inside a parenthesized require argument;
- ignore identifier references, assignments, and function declarations named
  `require` while still rejecting computed `require(name)` and
  `pcall(require, name)` calls;
- support the documented optional `pcall(require, "name")` form; and
- count CR, LF, CRLF, escaped newlines, form feed, and vertical tab correctly.

`bit32` is not considered a Lua 5.4 builtin. Resolver inputs must be readable
files, not merely paths that `io.open` can open. Root paths and drive roots are
handled without collapsing their parent to `.` or `C:`.

### Module identity and source stability

Dependency paths are canonicalized to absolute normalized paths before manual
include/exclude deduplication. Re-including an automatically discovered source
is idempotent.

A source path maps to a set of requested module aliases, not one last-writer
name. The generated payload stores source bytes once and publishes the same
record under every alias. `/init.lua` manual sources expose both the package
name and the explicit `.init` name when neither conflicts. An alias owned by
two different sources fails with `DuplicateModuleError`. Native libraries are
copied to every traced alias destination with target-aware collision checks.
Static native resolution includes `?/init` templates and Lua's C-root fallback
so multiple literal aliases can bind to one verified library.

Static discovery hashes the exact source bytes it parses, runtime discovery
carries Lua loader-boundary snapshots, and manual mode retains its initially
validated entry. Manifest creation must match that discovery snapshot. The bytes
read for the C bootstrap and every copied native output must then match the
manifest hash. A mutation between discovery, manifest creation, embedding, or
copying fails with `SourceChangedError`; stale analysis can never produce a
success result.

### Runtime and runtime discovery isolation

The pure-Lua runtime and generated bootstrap temporarily clear every bundled
module key in `package.loaded`, execute the payload, and then restore the exact
previous values, including `false` and `nil`. Cleanup occurs on success and
error, nested runs remain valid, and all entry return values are preserved.

Runtime discovery records Lua 5.4's loader-data return from the real `require`.
An existing readable `.lua` loader path is bound to a source snapshot. Native
loader paths are rejected because file reads around `dlopen` cannot prove which
bytes were mapped; static discovery remains the supported native path. Custom
and preload loaders without `.lua` loader data are rejected. A filesystem
module already cached before tracing is rejected before classification because
it has no reproducible execution-time provenance. Every successful non-cached
record must carry a verified Lua snapshot, including when searchers mutate
during traversal. Trace
output writes are checked and end with a completion marker so partial records
cannot be accepted as success.

### Onedir transaction and ownership

The v2 marker starts with `luainstaller-generated-output-v2`. It records the
absolute declared output directory plus every generated regular file and
directory below the output. Each regular file except the marker itself has a
SHA-256 hash. Relative paths are validated before use, duplicates and symlinks
are rejected, and the current tree must equal the marker recursively.

Validation fails closed when `find`, read, type, or permission checks fail. An
unreadable non-empty directory cannot be treated as empty. A file or empty
directory added anywhere under `.luai/` prevents replacement and remains
untouched. Changed generated content also prevents replacement. Marker v1,
malformed markers, unsupported file types, and symlinks are refused.

Writes in staging are checked through `luainstaller.fs`. Compiler permission
changes are checked. Cleanup errors after an atomic commit report
`committed=true`; errors before commit preserve the prior output. Output names
that collide with the reserved `.luai` directory are rejected.
After the old output is moved to a backup, its complete marker-bound inventory
is revalidated before publication and before deletion; a mismatch restores or
retains the backup without recursively deleting concurrent content.

### Path and target portability

`path.dirname`, `path.absolute`, joining, containment, and safe-relative checks
cover POSIX root, Windows drive root, UNC roots, current-directory roots,
trailing separators, drive-relative names, and repeated separators.

Windows-generated filesystem names reject NUL/control bytes, `< > : " | ? *`,
trailing dots/spaces, drive-relative forms, and reserved device basenames.
Windows and default macOS destinations are checked case-insensitively. Native
alias destinations and onefile embedded paths cannot collide after target
canonicalization.

The manifest v2 platform section separates host and target records. macOS
defaults to `static-lua`; Windows target architecture is `x86_64`; native
Linux/macOS targets use the detected host architecture.

### Onefile correctness and determinism

The extractor's null-pointer relational comparison is removed. C strings use a
real byte-wise C encoder rather than Lua `%q`. Empty embedded files produce a
strictly conforming array. Windows child creation does not inherit unrelated
handles.

Cache reuse compares cached bytes directly with the bytes embedded in the
executable, eliminating FNV collision trust. The SHA-256 payload ID covers each
path, mode, size, and content with unambiguous length framing. Non-runtime
onedir artifacts (`.luai/build/` and the ownership marker) are excluded from
the onefile payload. Two builds from the same checkout, options, output path,
compiler, and environment must be byte-identical and reuse one cache directory.

If output publication succeeds but staging cleanup fails, the result identifies
the already committed output. Executable-mode repair sets both executable and
non-executable cached modes exactly.

POSIX extraction validates the parent chain before touching a final path and
uses no-follow, directory-handle-relative operations for file comparison,
temporary creation, mode changes, replacement, and cleanup.

### Logger, installer, and toolchain

Persistent logging uses an inter-process lock around read/trim/write and a
same-directory temporary file plus atomic rename. Writers wait at most five
seconds; a lock older than 120 seconds is moved aside atomically before reuse.
Lock ownership is verified before release. On platforms where rename cannot
replace a file, the prior log is retained as a backup and automatically restored
after an interrupted switch. Failed writes never truncate the last valid log.
Concurrent writers retain all entries up to the documented 1000-entry cap.
`clearLogs` participates in the same lock and leaves both recovery generations
empty on success. Windows log paths reject reparse points.

`tools/install-source.sh` rejects every interpreter other than Lua 5.4 before
writing the prefix. Installed wrappers also reject a `LUAI_LUA` override with a
different ABI. The rockspec constrains Lua to `>= 5.4, < 5.5`.

Linux `pkg-config --modversion lua` must identify 5.4 before compilation. The
launcher has a compile-time `LUA_VERSION_NUM == 504` guard for all profiles.
Every profile also compiles and executes a linked-runtime `_VERSION` probe
before publication, using Wine for Windows, and launchers repeat the check at
startup. macOS and Windows prefixes therefore cannot silently combine 5.4
headers with a different runtime. The generic Linux profile continues to copy
and verify the linked Lua runtime.

### Remote test and supply-chain safety

Remote scripts archive only Git-tracked paths, reading their current worktree
contents. They never transmit `.git`, ignored files, or unrelated untracked
files. Every configurable path passed to a destructive operation must match a
normalized `/tmp/luainstaller-*` (or the documented Windows temporary child)
shape; traversal and unsafe overrides abort before deletion.

Downloads use a temporary file, verify SHA-256 on every cache hit and download,
and rename only after verification. The pinned values are:

- Lua 5.4.8: `4f18ddae154e793e46eeab727c59ef1c0c0c2b744e7b94219710d76f530629ae`
- LuaRocks 3.12.2: `b0e0c85205841ddd7be485f53d6125766d18a81d226588d2366931e9a1484492`
- lsqlite3 v0.9.6 archive: `ecc6e7636a54f021bca5b4a01b35af06fd7a6fc8b21c4b3eccd4fdb5dd32ad82`
- SQLite 3.53.2 amalgamation: `8a310d0a16c7a90cacd4c884e70faa51c902afed2a89f63aaa0126ab83558a32`

LuaRocks dependencies use explicit versions already exercised by the Windows
matrix. Windows SSH mandates strict host-key checking and rejects configurable
options that try to override host-key policy. Key authentication is the default;
password mode is optional and never disables host verification. Linux x64,
Linux ARM64, macOS, Wine, and remote Windows gates reject any unexpected
`skipped` probe. macOS runs the portable core suite in addition to application
bundles.

## Error Handling

Public APIs continue returning `{ok=false,error={...}}` rather than leaking
ordinary filesystem, syntax, compiler, discovery, or source-race exceptions.
New actionable types are added to `ErrorTypes` and documented:

- `LuaSyntaxError`
- `SourceChangedError`

Existing `FilesystemError`, `InvalidOptionsError`, `InvalidOutputError`,
`ToolchainError`, `DuplicateModuleError`, and `DiscoveryError` are reused where
their caller action remains unambiguous. Cleanup and commit state is attached
as structured fields instead of being hidden in text.

## Test Strategy and Release Gates

Tests are written first and observed failing for each confirmed defect. A new
production-edge suite covers lexer differentials, syntax and input types,
aliases in both orders and both bundle modes, dynamic runtime loader paths,
source mutation, root/portable paths, recursive marker ownership, permission
failures, checked writes, logger concurrency, onefile determinism/cache repair,
ABI rejection, and remote-script static safety contracts.

The final evidence set is:

1. Lua and shell syntax checks.
2. `test/cli_split_smoke.lua`, `test/contract_docs.lua`, the new edge suite,
   and `test/smoke_all.lua` from a clean checkout/worktree.
3. Generated launcher and extractor compilation with GCC and Clang using C11,
   `-Wall -Wextra -Werror -pedantic`, plus ASan/UBSan execution on Linux.
4. Isolated source install and LuaRocks install/build checks.
5. Linux onedir/onefile clean-environment and concurrent-cache runs.
6. Local MinGW/Wine builds and argument/cache/security checks.
7. Reachable Linux x64, Linux ARM64, macOS, and Windows lab scripts with no
   skipped probe. An unreachable or failing required lab stops publication.
8. Reproducibility comparison, `git diff --check`, final diff review, and a
   clean status except the user's untouched `.review-patches/` in the primary
   checkout.

Only after every applicable gate is green is the hardening branch integrated
into local `main` and pushed to `origin/main`. No force push, release tag, or
staging of `.review-patches/` is permitted.
