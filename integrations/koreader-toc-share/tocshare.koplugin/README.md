# Share TOC excerpts 0.6.0

A standalone KOReader plugin for Android. Hold an EPUB table-of-contents entry and choose **Share excerpt** to open Android's
normal share sheet with that chapter or section's plain text. **Show full title** opens the original
KOReader title popup. Holding a row alone does not extract or share text.

## Install and use

1. Extract the ZIP into KOReader's plugin directory, usually `/sdcard/koreader/plugins/`.
2. Check that the resulting path is `plugins/tocshare.koplugin/main.lua` (not a double-nested folder).
3. Keep one current copy: custom APKs must omit a bundled copy when this external plugin is installed.
4. Restart KOReader. If needed, enable **Share TOC excerpts** in KOReader's plugin management.
5. Open an EPUB, open its standard table of contents and hold the desired entry.
6. Choose **Share excerpt**, then select the receiving app from Android's share sheet. Sending is controlled by that app.

Holding a chapter includes its subsections and stops before the next chapter. Holding a subsection
includes its descendants and stops before the next entry at the same or higher level. Ordinary TOC
taps still navigate. Supported EPUB holds offer an explicit action chooser with **Share excerpt** and **Show full title**.
PDFs, other formats, non-sharing devices and hidden-flow editing keep their usual behavior.

## Share a whole book

In KOReader's file browser, hold an EPUB and choose **Share book text**. The normal Android
share sheet receives the complete readable text, book title, author and optional cover thumbnail,
using the same metadata as chapter sharing. No chapter selection or TOC is required. Text before
the first TOC entry is included. Agora receives an unsent attachment with the book title and cover.

Text up to 256 KiB uses ordinary direct text sharing. Larger books use a UTF-8 TXT file
shared by a granted Android content URI. The full text remains on the device until the receiver
copies it; only the URI and small metadata enter the transaction. The plugin accepts text up to
100 MiB. This shares extracted plain text, not the EPUB file. Opening the hold menu alone does not extract or send anything.

## Scope and limits

- Works independently of Kalamos, including on a stock KOReader Android build. No custom APK,
  AI provider, generated book data, internet connection or settings file is required.
- Shares readable text, including headings and paragraph breaks. Inline chapter images, EPUB styling and a new
  EPUB attachment are not included; an optional book cover is shared as display metadata. The chapter name is sent as the share preview title.
- Uses document positions rather than rounded page numbers, so same-page chapter starts and
  chapters spanning XHTML files can be separated. Collapsed and filtered TOCs use the full hierarchy.
- Refuses invalid/ambiguous ranges and text larger than 100 MiB. No text is silently truncated.
  Direct-text shares stay within 256 KiB; larger shares use the Android file-sharing mechanism.
  If file sharing fails, large text is never retried as an oversized inline intent.
- Agora copies the full file through its existing bounded attachment importer before the incoming
  share Activity finishes. Its normal text-file processing includes at most 500,000 characters
  in chat context. When this applies, the destination dialog and attachment text explicitly say
  so. The complete source file is retained; a successful transfer does not mean the model receives
  every character. Provider context limits are separate. Small inline text retains existing behavior.
- The final chapter runs to the last visible text in the document. Following material without its
  own TOC entry is consequently part of that final TOC range. Incorrect publisher TOCs cannot be
  corrected automatically.
- Another plugin that replaces TOC menus can conflict; this plugin wraps reader/menu instances and
  restores its own handlers on close. Disable this plugin and restart to restore standard holds.
- The source does not write book files, highlights or annotation stores.

## Validation

29 chapter range/menu tests, ten whole-book tests, twelve metadata/JNI scenarios, and 19 method-descriptor checks against the
official Android SDK/JDK pass. Sixteen engine scenarios pass with official KOReader v2026.07.1
on Linux: EPUB 2/3, nested/same-page boundaries, split spine, final page, Unicode, two font sizes
and unchanged reading position. Real BlitBuffer/JPEG/Base64 encoding also passes.

On 15 October 2026 the user performed a fresh TOC share on Android 14. Agora displayed the cover
and retained chapter title, book title, author and its own private cover copy in an unsent
attachment. Broader KOReader/device compatibility and physical pen/e-ink acceptance remain
separate checks. No model request is needed for chapter sharing.

This version retains the 0.4.1 fix for the void JNI signature of Intent.setClipData and checks method lookups
before invocation. Failed lookups clear pending exceptions and release the JNI context before
ordinary text fallback. Custom reader packaging omits the older bundled copy, leaving the
standalone plugin as the single current installation.

## Excerpt metadata (0.6.0)

Shares include the book and excerpt titles in Android's title/subject fields. A cooperating receiver
such as Agora also receives `org.koreader.extra.EXCERPT_METADATA`, JSON with schema
`org.koreader.excerpt/v1`, `title`, `bookTitle`, `authors` and optional `thumbnailBase64` (JPEG).
The thumbnail is resized to fit 160×220 pixels and bounded to 90,000 encoded-file bytes. Missing or
unreadable covers are omitted. Metadata never replaces the ordinary shared text. If the optional
stock-JNI sender fails, ordinary KOReader text sharing remains available with the combined title.
No custom launcher or Kalamos native bridge is required.

Agora imports shared text as an unsent file attachment in a chosen draft. It retains the source
metadata and uses the cover only for display; provider image input does not include that cover.
Other share targets receive the plain text and can ignore the optional extra. The Android system
Sharesheet preview receives a granted FileProvider content URI via ClipData. Cover files remain available for delayed readers; the next share removes owned previews older than 24 hours.


## Large text file lifetime

Owned `tocshare-text-*.txt` exports and cover previews remain available for 24 hours; later shares
remove only expired plugin-owned files. The receiving app must copy granted bytes before its
Activity finishes. Agora uses its existing attachment importer and retains its own private copy.
`EXTRA_STREAM` identifies the text file. Both text and cover URIs are present in ClipData with read
permission; the optional JSON envelope still carries the title, author and bounded cover image.
The same Share book text / Share excerpt actions choose the transport automatically.
