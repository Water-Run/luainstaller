# student_management_system

This sample is a classic student management system: list students, view one
student, add, update, delete, and save records.

Current state:

- The existing code has been moved here from the old `management` demo.
- Storage currently uses a text file named `students.txt`.
- The planned structure is to use `cjson` for structured file storage so the
  sample exercises LuaRocks dependency discovery.

Run directly:

```sh
cd test/student_management_system
lua main.lua
```

Future packaging targets:

```sh
luai -a test/student_management_system/main.lua
luai -t test/student_management_system/main.lua
luai -c test/student_management_system/main.lua -o build/student-manager
```

Expected dependency behavior:

- Lua modules: `model`, `service`, `utils`
- Planned LuaRocks module: `cjson`
- Data file: `students.txt`
