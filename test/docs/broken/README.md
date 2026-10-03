# doc-check fixtures

**The mutations live in `tools/doc-check.js`, not in this folder.**

An earlier version kept a small `.md` file per case here. It was theatre: the
selftest never read them, so "the fixture exists" proved nothing about whether the
checker fires, and a file that is never opened is a file that cannot fail.

A standalone fixture is also the wrong shape. A tiny document that mentions
three export names omits the other thirteen, so it raises `DOC_unmentioned` for
all of them and `DOC_stale_count` for nothing — which proves the checker fires
and proves nothing about *which* check fired.

So each case is a **mutation applied to the real DOCUMENTATION.md**: remove the
diagnostics section, corrupt the assertion count, append a dead link, remove the
layout. One defect per case, so "did it raise exactly my code" is a real
question, and no fixture can go stale by duplicating a document that changes.
