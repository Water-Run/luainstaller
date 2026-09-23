# luainstaller repository notes

Follow `CODING-STYLE.txt` for code. Test commands and CI gates are in
`docs/TESTING.adoc`; public doc wording is guarded by
`test/contract_docs.lua` and `test/release_docs_contract.lua`, so update
those checks together with the docs.

# Documentation style

User docs (`README.adoc`, `docs/*.adoc` except `IMPLEMENTATION` and
`TESTING`) are written for people, not for agents. Keep them that way:

- Current version only. No changelog entries, release evidence, dated test
  reports, or "since 1.x" history. Changes go in `CHANGELOG.adoc`; the rest
  is in git and the GitHub release notes.
- Say what a user needs and stop. Cut edge-case enumeration, option
  semantics nobody asks about, and implementation internals. A detail that
  only matters when something breaks belongs in `TROUBLESHOOTING.adoc`.
- Plain sentences a person would say. No spec-legalese, no stacked
  qualifiers, no "X must Y; Z may differ when..." hedging chains.
- Calm, factual tone: "doesn't" over "never"; describe what the program
  does instead of issuing rules.
- Use AsciiDoc features GitHub renders and Markdown lacks: admonitions
  (with the `env-github` emoji captions), code callouts, `[horizontal]`
  and plain description lists, column-formatted tables, sidebars,
  `[%collapsible]` blocks, footnotes, checklists. Skip `[tabs]` and
  `include::`, which GitHub doesn't render.
- Every file in `docs/` keeps the
  `xref:../README.adoc#documentation-index[Back to documentation index]`
  line at top and bottom.

# Release checklist

- Bump the version in `src/`, `luainstaller.1`, the rockspec file name and
  contents, and the tool scripts together; `test/version_contract.lua` and
  `test/contract_docs.lua` check them.
- The required gates are the GitHub Actions Linux and Windows five-ABI
  matrices and the native Linux x86 job, on the release commit.
- Physical-host runs (ARM64, macOS, FreeBSD, Termux, legacy Windows) are
  supplemental. Record them in the release notes, not in `docs/`. A host
  missing a compiler or headers is a blocked test, not a pass.
- Don't broaden platform claims in the docs from simulated or
  cross-compiled results alone.
- `docs/RELINKING.adoc` is also embedded in `src/distribution_files.lua`
  and shipped inside every bundle; keep the two in step.
- Don't commit machine credentials, chat exports or old `.rock` files.
