# ltokei

This directory is reserved for a Tokei-like source code statistics tool written
in Lua.

Purpose:

- exercise medium-size pure Lua packaging
- exercise recursive directory scanning
- exercise optional Lua library dependencies
- provide a realistic CLI application sample

Planned layout:

- `src/` for Lua modules
- `fixtures/` for small source trees used by the sample

The first version should count files, blank lines, comment lines, and code
lines for a small set of languages. Library dependencies are allowed when they
make the sample more realistic.
