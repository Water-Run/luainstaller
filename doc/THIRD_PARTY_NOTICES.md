# Third-party notices

Distributions produced by luainstaller can contain the Lua interpreter runtime
and Lua modules selected on the build host. The distributor remains responsible
for notices required by any additional Lua or native modules included in an
application.

## Official Lua release-qualification sources

- Copyright: Copyright © 1994–2026 Lua.org, PUC-Rio.
- License: MIT; reproduced in `.luai/licenses/Lua-MIT.txt`
- License page: https://www.lua.org/license.html

The native release matrix verifies these archives before use:

| Component | Official source | SHA-256 |
| --- | --- | --- |
| Lua 5.1.5 | https://www.lua.org/ftp/lua-5.1.5.tar.gz | `2640fc56a795f29d28ef15e13c34a47e223960b0240e8cb0a82d9b0738695333` |
| Lua 5.2.4 | https://www.lua.org/ftp/lua-5.2.4.tar.gz | `b9e2e4aad6789b3b63a056d442f7b39f0ecfca3ae0f1fc0ae4e9614401b69f4b` |
| Lua 5.3.6 | https://www.lua.org/ftp/lua-5.3.6.tar.gz | `fc5fd69bb8736323f026672b1b7235da613d7177e72558893a0bdcd320466d60` |
| Lua 5.4.9 | https://www.lua.org/ftp/lua-5.4.9.tar.gz | `2335b6c582a52654f94612bf10d2f4672805d05329aa6568b1d8cd9e5c6fb8e6` |
| Lua 5.5.1 | https://www.lua.org/ftp/lua-5.5.1.tar.gz | `1c4b4068d67061f2a2231ad2b5422e77acea1487ea9890f6320af614f4373dce` |

A generated bundle's `.luai/manifest.lua` identifies the actual Lua
major/minor ABI and runtime link mode selected from its build environment.
Distributors should additionally retain the exact provenance of the runtime
binary they provide, including downstream patches from an operating-system
vendor.

## LuaJIT runtime

LuaJIT bundles use LuaJIT 2.1, under the MIT license. Its complete copyright
notice, including the incorporated Lua license, is reproduced in
`.luai/licenses/LuaJIT-MIT.txt`. Upstream: https://luajit.org/.

The LuaJIT test matrix pins commit `2a8e017ef1ece6a95b983ffca073d30609dce7c4`
from https://github.com/LuaJIT/LuaJIT. The corresponding source archive is
https://codeload.github.com/LuaJIT/LuaJIT/tar.gz/2a8e017ef1ece6a95b983ffca073d30609dce7c4
(SHA-256 `54705d4b1de50a9c668539b9cf0dc3170d94ffdad51fafd1cf4477e498be7144`).
The bundle manifest records its selected runtime kind, version and build
configuration. Distributors should retain provenance for any downstream patches.

## luainstaller generated runtime and launcher

luainstaller is distributed under `LGPL-3.0-or-later`. Generated bundles carry
the LGPL text, the GPLv3 text incorporated by it, generated C source, and
relinking instructions under `.luai/`. See `.luai/build/RELINKING.adoc` and the
top-level project source at https://github.com/Water-Run/luainstaller.

The license texts describe the applicable legal terms. This notice is an
inventory and does not replace them.
