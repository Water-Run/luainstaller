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
- `docs/zh-CN/` mirrors `docs/` with Simplified Chinese translations, one
  file per English guide, and `README.zh-CN.adoc` is the Chinese entry
  point. Keep the translated set, anchors and code blocks in step with the
  English files; each translation keeps the
  `xref:../../README.zh-CN.adoc#documentation-index[返回文档索引]` line at
  top and bottom. The Chinese README links the bilibili intro video and
  the English README the YouTube one. The bundle-embedded RELINKING copy
  is the English `docs/RELINKING.adoc`; the translation is repo-only.

# Repository layout

- Keep active development plans and audit records in `dev/`. Remove completed
  PLAN documents; Git history preserves them. The roadmap describes future work.
- Keep test instructions and fixtures in `test/`, tools in `tools/`, and user
  guides in `docs/`. Keep generated output and local session files out of commits.

# Release notes

- Write for users. Feature releases use `Major changes` and `Minor changes`;
  patch releases use `Changes`. Add `Notes` only for useful upgrade, usage or
  compatibility information. Use concise bullet points and keep the existing
  English release-note language.
- Describe what changed for the user. Omit development diaries, audit progress,
  CI results, commit hashes, file counts, publishing procedures and future plans.
- Check changes against the release tag; do not attribute later features to an
  older version. Keep verification evidence in audit records and task logs.

# Release checklist

- Bump the version in `src/`, `luainstaller.1`, the rockspec file name and
  contents, and the tool scripts together; `test/version_contract.lua` and
  `test/contract_docs.lua` check them.
- The required gates are the GitHub Actions Linux and Windows five-ABI
  matrices, the native Linux x86 job, and the separate pinned LuaJIT Linux
  and Windows/MSVC matrix, on the release commit.
- Physical-host runs (ARM64, macOS, FreeBSD, Termux, legacy Windows) are
  supplemental. Record them in audit records, not in user guides or release
  notes. A host missing a compiler or headers is a blocked test, not a pass.
- Don't broaden platform claims in the docs from simulated or
  cross-compiled results alone.
- `docs/RELINKING.adoc` is also embedded in `src/distribution_files.lua`
  and shipped inside every bundle; keep the two in step.
- Publish with the ordered steps in `docs/TESTING.adoc`
  (`#testing-luarocks`) and `docs/zh-CN/TESTING.adoc`. Tag the qualified
  commit, attach the five GitHub assets, and check `sha256sum -c SHA256SUMS`
  on a fresh download. Then `luarocks upload ROCKSPEC SRC.ROCK` using that
  downloaded `.src.rock`. If the upload reports `unexpected eof while reading`,
  repeat it with the curl command in that section, and do not pass
  `--verbose`. The LuaRocks bytes must match the GitHub files. A versionless
  install into an empty tree and over the previous install must select this
  version, and `luai -v` must match the tag. Upload any older GitHub rock
  the index does not serve. Leave the API key out of the repository.
- Don't commit machine credentials, chat exports or old `.rock` files.
