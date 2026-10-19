# Optional reader handwriting

Full-page ink, pen text selection and handwritten sticky notes for EPUB/PDF on the Bigme native
ink backend. Original Kalamos code is AGPL-3.0-or-later; retain the existing JNI MIT notice.

## Components and compatibility

This plugin is one component of the handwriting distribution. Native writing also needs the
version-1 Android activity bridge, optional launcher adapter, three device/bridge AARs and Android
input hook. Copying Lua onto an ordinary APK cannot add that native implementation. The plugin
probes the bridge before changing reader menus, highlights or input. Missing, incompatible and
unsupported bridges leave the reader untouched. It is reader-only, not a file-manager input hook.

The optional launcher build uses -PkalamosInk=true, Android API29+ and the Bigme firmware daemon.
Stock builds retain the upstream API18 floor and omit native/vendor dependencies. Other Android
vendors, Kindle, Kobo and Linux are not supported writing backends in this release. They should
remain usable readers with handwriting unavailable. Successful builds are not hardware acceptance.

The independent native source bundle builds with JDK17, SDK34, Gradle8.14.5, AGP8.2.2 and Kotlin1.9.22.
The upstream submission packet supplies exact reader/base/launcher pins and narrow patches. It
contains no other Kalamos apps, signing keys, private books or firmware binaries.

## Installation

Use the plugin bundled in an explicitly enabled native handwriting reader build. Do not install
another copy in the external plugins directory: bundled and external copies are not deduplicated.
For plugin-only iteration, use exactly one external copy with a matching native bridge.

## Saved data and limits

Book IDs and the established /sdcard/Kalamos/BookData/<book-id>/ink-annotations.json path are retained.
An advanced kalamos_ink_directory setting can explicitly select another absolute directory.
There is no automatic migration; close the reader, back up/copy desired book-ID directories to an
empty destination, then set the path and verify a test book. Removing the setting returns to the
legacy location. This directory also contains existing user handwriting: never delete it to clear retired generated
data. Failed/corrupt reads preserve the original file and refuse new writing until a valid file is
restored and loaded. New-book creation is distinguished from permission/parse failures.

Full-page ink is currently bound to rendered page/view positions. It is not a general semantic
reprojection system: changing font, margins, page mode, zoom, crop, rotation or viewport needs
explicit acceptance testing. Do not claim that marks follow text across arbitrary EPUB reflow or
PDF zoom/crop changes. Sticky-note content and text anchors are a separate mechanism. Reliable
layout-change handling is an open acceptance gate, not evidence established by the engine tests.

## Compact writing and EPUB spaces

Version 0.3 uses a checked page/pen action to enable/disable writing. The rail's own collapse
control shrinks it to a visible edge tab without ending capture. Exit, above Pen, saves ink,
disables Kalamos and hides every tool, like the checked top-menu toggle. It replaces Read.
Normal text selection/navigation returns after exit. Canvas page turns retain the tools.
Tools, quick colours, palettes and dock
side live in the native bridge. Sticky notes receive the same toolbar and preserve page-return
intent through Save/Cancel. EPUB spaces are available from the rail and text selection menu.

Spaces use the prepared CREngine extension and a separate `writing-spaces.json` sidecar. They
insert actual paragraph padding, support live preview/rollback, local ink, resize, collapse,
markers and explicit keep-as-sticky/delete. Supported scope is single-page EPUB view and ordinary
left-to-right paragraphs outside tables/lists/floats. PDF page ink and sticky notes remain.
Canvas borders are solid black. Existing page-position ink is preserved across space changes; new page ink is fenced to its rendering
signature. A space must fit the viewport before handwriting; larger/font-changed spaces keep a
marker/management route. No original EPUB mutation or arbitrary semantic page-ink reprojection.

## Automated tests

From this standalone repository:

    python3 tests/run.py
    python3 tests/run-runtime.py /path/to/extracted/linux/koreader

The first command runs portable lifecycle, capability, saved-ink compatibility and failure tests.
The second uses actual KOReader LuaJIT/RapidJSON with a temporary annotation directory. Backend
motion tests execute the patched upstream input module with simulated Android events; they do not
measure the physical pen, daemon surface, panel latency or firmware behavior.

The actual layout-engine regression checks HTML and a generated EPUB, paragraph-specific CSS,
downstream pagination, stable anchors across a font change, rollback and unsupported blocks:

    ./tests/run-engine.sh /path/to/prepared/koreader /path/to/disposable-output

Run in an environment with CMake, a C++ compiler and CREngine's host dependencies. Native toolbar
Robolectric checks and Bigme input-ownership tests run from the monorepo Gradle build.
