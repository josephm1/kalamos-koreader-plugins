# Standalone TOC excerpt sharing — research, 15 October 2026

Requested behavior: hold an EPUB entry in KOReader's standard TOC, then receive Android's normal
share sheet containing that section's text. User selected plain text for the first version.
This plugin is separate from `kalamos.koplugin`, needs no Kalamos data, and has no AI dependency.

## Existing solutions checked

- [KOReader contrib](https://github.com/koreader/contrib): the community plugin collection. No exact
  TOC-entry-to-Android-share solution was found in its catalog or targeted public searches. This is
  a search finding, not proof that no private/unlisted implementation exists.
- [KOAssistant](https://github.com/zeeyado/koassistant.koplugin): the closest extraction reference.
  Its [release notes](https://github.com/zeeyado/koassistant.koplugin/releases) describe selecting
  chapters/sections from a hierarchical TOC for scoped artifacts and text context. It is a much
  larger AI assistant, not an identified direct replacement for the requested sharing interaction.
- KOAssistant's current [context extractor](https://github.com/zeeyado/koassistant.koplugin/blob/main/koassistant/request/context_extractor.lua)
  handles XPointer/page ranges, visible flows, and end-of-document detection. Earlier search-indexed
  links to `koassistant_context_extractor.lua` are stale; verify the live tree before reusing examples.
  Its `documentEndXPointer` documents a real last-page omission: `getPageXPointer(lastPage)` returns
  that page's start. It obtains the last glyph boundary via screen selection and restores position.
  Its fallback can retain a shorter range; an excerpt-sharing implementation should instead refuse
  an unverified range rather than quietly share an incomplete chapter.
- [KOHighlights](https://github.com/noembryo/KoHighlights) and KOReader's
  [bundled exporter](https://github.com/koreader/koreader/wiki/Highlight-export) export highlights and
  notes. They are useful export references, but do not implement this chapter-sharing workflow.

## Primary implementation references

1. [Official development guide](https://github.com/koreader/koreader/blob/master/doc/Development_guide.md)
   and [Hello plugin](https://github.com/koreader/koreader/blob/master/plugins/hello.koplugin/main.lua):
   Lua plugin structure; ordinary `*.koplugin` distribution can extend reader behavior.
2. [ReaderToc](https://github.com/koreader/koreader/blob/master/frontend/apps/reader/modules/readertoc.lua):
   `onShowToc` constructs `toc_menu` and its `onMenuHold(item)`. The standard hold currently shows the
   full title, or hidden-flow editing controls. No dedicated chapter-share callback was identified.
   Proposed adapter wraps the current reader's `onShowToc` and the resulting menu's hold handler;
   preserve non-EPUB/non-sharing-device behavior and hidden-flow editing, and restore on close.
3. [CreDocument](https://github.com/koreader/koreader/blob/master/frontend/document/credocument.lua)
   and [CRE Lua binding](https://github.com/koreader/koreader-base/blob/master/cre.cpp):
   `getTextFromXPointers(start, finish, false)` extracts exact DOM ranges without drawing selection.
   `compareXPointers` returns 1 when its second pointer is later, 0 when equal, -1 when earlier.
   Validate first: the extraction binding sorts reversed ranges, which could conceal a wrong bound.
4. [crengine DOM implementation](https://github.com/koreader/crengine/blob/master/crengine/src/lvtinydom.cpp):
   `nextVisibleChar` advances through text including punctuation to the end offset, returning false
   when no further visible text remains. A possible alternative EOF strategy is to walk from the
   final internal page with a strict progress/step guard. This avoids navigating the document;
   it still needs real-engine tests for EPUB flows and layout edge cases.
5. [Android Device](https://github.com/koreader/koreader/blob/master/frontend/device/android/device.lua):
   `canShareText()` and `doShareText(text, reason, title, mimetype)` are already exposed to Lua.
6. [Android launcher](https://github.com/koreader/android-luajit-launcher/blob/master/app/src/main/java/org/koreader/launcher/MainActivity.kt):
   `sendText` builds `ACTION_SEND`, `EXTRA_TEXT`, `text/plain` and `Intent.createChooser`, then starts
   that chooser. The plugin can reuse this directly; a Kalamos JNI bridge is unnecessary. Exceptions
   in this native method are caught internally, so a successful Lua call cannot certify delivery.
7. [Android sharing documentation](https://developer.android.com/develop/ui/compose/sharing/send?hl=en):
   recommends the system Sharesheet, with `ACTION_SEND`, `EXTRA_TEXT`, a specific MIME type, and
   `Intent.createChooser`. Receiver selection and actual sending remain with the user.

## Proposed first version and status

- Independently installed `tocshare.koplugin`, EPUB and Android text sharing only.
- Hold a parent chapter: include descendants, ending immediately before the next TOC entry at
  the same or higher level. Hold a subsection: include that subsection and its descendants only.
- Use the full TOC, not its collapsed/search-visible row positions. Never infer exact cuts from
  rendered page numbers or assume one XHTML spine file equals one chapter.
- Validate boundary order; no whole-book fallback, automatic truncation, AI or map generation.
- Current prototype imposes a conservative 200 KiB text payload limit. This is a plugin policy,
  not a documented universal Android text limit. Larger excerpts need a future file-sharing path
  or a smaller subsection; receiver-side length limits still vary.
- Build 0.1.0 now has 24 range/menu tests and 11 actual KOReader v2026.07.1 engine scenarios.
  Original EPUB 2/3 fixtures verify nested/same-page ranges, a chapter spanning spine files, final
  page text, Unicode, font-size independence and unchanged reading position. The packaged ZIP is
  independent of Kalamos. Hidden-flow editing retains its original hold handler (adapter test);
  advanced hidden/nonlinear EPUB layouts still need broader real-book coverage. Android share-sheet
  interaction and receiver behavior remain unaccepted until the user's physical-device test.

No source was copied from KOAssistant. Its implementation is a behavioral reference, not a runtime
dependency. No changes to Kalamos handwriting or retired app code are part of this plugin work.


## Whole-book action (0.5.0)

- [FileManager public extension hook](https://github.com/koreader/koreader/blob/master/frontend/apps/filemanager/filemanager.lua):
  `addFileDialogButtons(row_id, row_func)` appends a row to the EPUB hold dialog. Returning nil
  leaves directories/other formats alone. The plugin now loads in FileManager as well as ReaderUI.
- [Document registry](https://github.com/koreader/koreader/blob/master/frontend/document/documentregistry.lua)
  owns reference-counted temporary documents; release with `doc:close()`, not registry removal.
- [CreDocument](https://github.com/koreader/koreader/blob/master/frontend/document/credocument.lua)
  exposes loadDocument, render, getProps, getPageXPointer and extraction. Whole-book sharing
  reads from the first document page through the verified final visible position, independent
  of TOC coverage. It launches no ReaderUI and writes no reading position/history.
- Existing chapter metadata/JNI transport remains shared. The title for a whole book is its
  book title, with filename fallback when no title is present. The cover is still UI metadata.

- The 0.5.0 direct-text limit is 256 KiB of UTF-8, raised from 200 KiB. Android serializes text
  strings as UTF-16; the intent also carries bounded cover JSON and chooser data. The buffer is
  shared, so this is conservative headroom, not a guaranteed per-intent capacity. The user chose
  direct text instead of a 2 MiB content-file path. See [TransactionTooLargeException](https://developer.android.com/reference/android/os/TransactionTooLargeException).


## Large text file references (0.6.0)

The user requested file-reference sharing after the direct-text version. Up to 256 KiB still
uses EXTRA_TEXT. Larger readable text uses a retained UTF-8 file and FileProvider content URI in
EXTRA_STREAM, with both source and optional preview in granted ClipData. No full book string goes
through JNI into the Intent. The same public [Android sharing mechanism](https://developer.android.com/training/sharing/send)
works with cooperating receivers and requires no custom launcher. Agora connects incoming text/plain
streams to its existing bounded AttachmentImportProcessor staging/preparation, copies the full file,
and visibly discloses its existing 500,000-character chat-context preparation limit. Generic attachment
processing/context policy is unchanged. Text transfers are bounded to 100 MiB, independent of Binder.
