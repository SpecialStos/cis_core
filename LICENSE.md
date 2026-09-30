# cis_core

Platform services that HOLD DATA. Framework abstraction (ESX / ESX-LEGACY /
QBCore / qbx_core / standalone), the inventory service, the configuration file
you edit, and the migration ledger. It depends on cis_libs and nothing else.

## Attribution

**This notice must be retained in every copy and every distribution of this
software, in source or binary form, and in any substantial portion of it.**

- **Author:** Cisoko
- **Resource name:** `cis_core`
- **Project:** https://github.com/SpecialStos/cis_core
- **Documentation:** https://docs.cisoko.net

You may not remove or alter this notice, and you may not present this software
as your own work.

---

MIT License

Copyright (c) 2024 Cisoko

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

---

## Community

- Documentation: <https://docs.cisoko.net>
- Discord: <https://discord.gg/cisoko>
- Issue tracker: <https://github.com/SpecialStos/cis_core/issues>

## Third-party dependencies

`cis_core` has **no runtime dependencies**. It is designed to run alongside —
not on top of — ox_lib, ox_inventory, ox_target, oxmysql, qb-core, qbx_core or
es_extended, but it does not require, vendor or ship any of them. Those remain
under their own licences, and this project claims no rights in them.
