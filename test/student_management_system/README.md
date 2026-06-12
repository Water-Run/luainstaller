# student_management_system

This sample is a complete terminal student management system. It is larger than
the `single_file` samples and is meant to exercise normal multi-file Lua
packaging plus a LuaRocks dependency.

## Features

- JSON file storage through `cjson`
- interactive menu mode
- command mode for automated checks
- student CRUD
- class filtering and name search
- course grades
- total, average, GPA, pass status
- class summary report
- course and average ranking
- CSV import/export
- timestamped backup
- smoke test with a temporary data file

## Files

- `main.lua` - entry point, command mode, and interactive menu
- `model.lua` - student validation and grade calculations
- `service.lua` - business operations and CSV import/export
- `storage.lua` - JSON persistence with temporary-file save
- `reports.lua` - summary and ranking reports
- `utils.lua` - CLI, CSV, terminal, and file helpers
- `smoke_test.lua` - non-interactive project check

## Dependency

Install `cjson` with LuaRocks if it is not already available:

```sh
luarocks install lua-cjson
```

Check dependency discovery:

```sh
lua -e 'require("cjson"); print("cjson ok")'
```

## Direct Use

Run interactive mode:

```sh
cd test/student_management_system
lua main.lua
```

Seed a JSON file and inspect data from the repository root:

```sh
lua test/student_management_system/main.lua --data /tmp/students.json seed
lua test/student_management_system/main.lua --data /tmp/students.json list
lua test/student_management_system/main.lua --data /tmp/students.json report
lua test/student_management_system/main.lua --data /tmp/students.json rank --course lua
```

Add a student:

```sh
lua test/student_management_system/main.lua \
  --data /tmp/students.json \
  add \
  --name "Ivy Chen" \
  --gender F \
  --class CS2 \
  --birth 2004 \
  --phone 5550109 \
  --email ivy@example.test \
  --grades lua=96,python=91,math=93,english=88
```

CSV import/export:

```sh
lua test/student_management_system/main.lua --data /tmp/students.json export --out /tmp/students.csv
lua test/student_management_system/main.lua --data /tmp/students.json import --file /tmp/students.csv
```

## Verification

Run the project smoke test:

```sh
lua test/student_management_system/smoke_test.lua
```

Run syntax checks:

```sh
find test/student_management_system -maxdepth 1 -name '*.lua' -print0 | xargs -0 -n1 luac -p
```

Future packaging targets:

```sh
luai -a test/student_management_system/main.lua
luai -t test/student_management_system/main.lua
luai -c test/student_management_system/main.lua -o build/student-manager
```

Expected dependency behavior:

- Lua modules: `model`, `service`, `storage`, `reports`, `utils`
- LuaRocks/native module: `cjson`
- Data file: selected by `--data`, defaulting to `students.json`
