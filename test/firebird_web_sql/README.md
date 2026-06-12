# firebird_web_sql

This sample is intended to become an interactive web remote SQL shell for a
Firebird database. It should exercise web framework packaging, JSON handling,
database driver discovery, configuration files, and native module behavior.

Current state:

- The initial code was moved from the old `webshell` demo.
- It currently uses Pegasus and `cjson`, but still behaves like a remote command
  shell seed rather than a Firebird SQL shell.
- The next version should replace shell execution with Firebird connection and
  SQL execution flows.

Planned dependencies:

- Pegasus web library
- `cjson`
- Firebird Lua driver or binding
- Firebird client shared library when required by the selected binding

Run directly after installing dependencies:

```sh
cd test/firebird_web_sql
lua server.lua
```

Future packaging targets:

```sh
luai -t test/firebird_web_sql/server.lua
luai -c test/firebird_web_sql/server.lua -o build/firebird-web-sql
```

Packaging notes:

- This sample is expected to expose native dependency problems earlier than
  pure Lua samples.
- Trace output should show whether Pegasus, `cjson`, the Firebird binding, and
  any native libraries were found or skipped.
