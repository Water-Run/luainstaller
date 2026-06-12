# single_file

This directory contains small, independent, single-file Lua programs. They are
intended to be the first smoke tests for `luainstaller` because they do not need
module resolution beyond Lua's standard libraries.

Start here:

```sh
lua test/single_file/01_hello_luainstaller.lua
luai -c test/single_file/01_hello_luainstaller.lua
```

## Coverage

The catalog is arranged like a compact freshman/sophomore programming course.
Every file is standalone and should remain understandable without opening any
other source file.

| File | Topic |
|------|-------|
| `01_hello_luainstaller.lua` | console output |
| `02_calculator.lua` | expressions and command-line arguments |
| `03_guess_number.lua` | branches |
| `04_temperature_converter.lua` | numeric formatting |
| `05_todo_list.lua` | arrays and loops |
| `06_word_counter.lua` | string scanning |
| `07_file_copy.lua` | file I/O |
| `08_csv_summary.lua` | text parsing and aggregation |
| `09_password_generator.lua` | deterministic pseudo-random data |
| `10_prime_numbers.lua` | nested loops |
| `11_table_serializer.lua` | table records |
| `12_markdown_headings.lua` | pattern matching |
| `13_selection_sort.lua` | simple sorting |
| `14_binary_search.lua` | search over sorted arrays |
| `15_recursive_factorial.lua` | recursion |
| `16_gcd_euclid.lua` | Euclidean algorithm |
| `17_fibonacci_memo.lua` | memoization |
| `18_stack_parentheses.lua` | stack |
| `19_queue_simulation.lua` | queue |
| `20_linked_list.lua` | linked list |
| `21_set_operations.lua` | sets |
| `22_frequency_table.lua` | hash table counting |
| `23_binary_tree_traversal.lua` | tree traversal |
| `24_graph_bfs.lua` | breadth-first search |
| `25_graph_dfs.lua` | depth-first search |
| `26_matrix_multiply.lua` | two-dimensional arrays |
| `27_polynomial_eval.lua` | Horner's method |
| `28_coin_change_dp.lua` | dynamic programming |
| `29_lru_cache.lua` | combined table/list data structure |
| `30_topological_sort.lua` | directed acyclic graph ordering |

## Verification

Run a syntax check for all samples:

```sh
for f in test/single_file/*.lua; do luac -p "$f"; done
```

Run a small smoke subset:

```sh
lua test/single_file/01_hello_luainstaller.lua
lua test/single_file/14_binary_search.lua
lua test/single_file/30_topological_sort.lua
```
