# LyraReader naming and upgrade compatibility

The rename spans 11 Rust crates, the CLI, hand-written C ABI and generated UniFFI bindings,
Swift modules and app, bundle identity, fonts, scripts, CI, fixtures and documentation.
The mechanical changes touch roughly 200 source/configuration files; storage compatibility,
FFI regeneration and native functional verification are the main integration work.

| Surface | Current name |
| --- | --- |
| App, bundle and executable | `LyraReader`, `LyraReader.app` |
| Bundle identifier | `com.alex.lyrareader` |
| Rust packages / imports | `lyra-reader-*` / `lyra_reader_*` |
| C ABI functions / types | `lyra_reader_*` / `LyraReader*` |
| Swift modules | `LyraReaderKit`, `LyraReaderFFI`, `LyraReaderBindings` |
| Native regression executable | `LyraReaderChecks` |
| Developer environment variables | `LYRA_READER_*` |
| New annotation / disposable index sidecars | `.lyra-reader-annotations.json` / `.lyra-reader-index.json` |
| Appearance font | `LyraReader Sans SC` / `LyraReaderSansSC-Regular.ttf` |

## Existing installations

On the first launch, non-secret preferences are copied from the former `com.alex.lyra`,
`com.alex.arisreader` and bare `ArisReader` domains. Existing new-domain choices win;
`lyra.*` keys become `lyrareader.*`. A migration marker prevents a cleared setting/history
from being imported again. Reading positions, appearance, layout, AI settings and ChatGPT
account metadata retain their existing values. Cached recent-document covers are disposable
and regenerate under `LyraReader/RecentCovers`.

API keys and ChatGPT tokens are read from the new Keychain service first, falling back to
`com.alex.lyra.ai` only if the item is absent. New saves use `com.alex.lyrareader.ai`;
clearing a credential removes both services so an old token cannot reappear. No secret is
copied to preferences or files. macOS may require authorization to access an existing item
from the renamed executable, according to the item's Keychain access control.

A document with an existing `.aris-annotations.json` continues using that same sidecar,
including its bookmarks, foreign entries and corruption protection. New documents use the
new suffix; if both exist, the new sidecar wins. No sidecar is moved or overwritten merely
by opening a PDF. Disposable old `.aris-index.json` caches are left untouched and rebuilt
under the new suffix. PDF annotation IDs and document content are not rewritten on open.
Existing PDF-embedded fonts and backups remain valid; new writes use the new names.

## Developer upgrade

Rebuild from a clean checkout: `./scripts/build-rust.sh --debug`, then
`./scripts/check.sh` and `./scripts/smoke-launch-app.sh`. Local ignore rules must exclude
`apps/macos/Sources/LyraReaderBindings/` and
`apps/macos/Sources/LyraReaderFFI/include/uniffi_scaffolding.h`.
Update launch scripts to `LYRA_READER_*`; old environment-variable and ABI names are not
aliases. This is a source/API rename before a public versioned release.

GitHub repository administration and existing clone directory names are independent of a
source PR: the remote remains `CafeAuLait-CC/ArisReader` until its owner renames it. The PR
contains all project-level naming changes without changing that remote or moving existing
clones. A checkout can live in any directory.
