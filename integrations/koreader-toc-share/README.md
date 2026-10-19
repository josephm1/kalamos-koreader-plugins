# Share TOC excerpts

A separate KOReader plugin for Android: hold an EPUB table-of-contents entry, then choose **Share excerpt** to send that
chapter or section as plain text through Android's normal share sheet. **Show full title** retains
KOReader's original full-title action. No Kalamos, AI, map data,
custom APK or internet connection is required.

## Build and install

```bash
python3 integrations/koreader-toc-share/package.py
```

Output: `artifacts/koreader-toc-share-0.6.0.zip` and its SHA-256 sidecar. Extract into KOReader's
plugin directory, usually `/sdcard/koreader/plugins/`, to get:

```text
/sdcard/koreader/plugins/tocshare.koplugin/main.lua
```

Restart KOReader, enable **Share TOC excerpts** in plugin management if needed, open an EPUB and
hold its chapter in the standard TOC. Select the destination from Android's share sheet. This is
an independent optional plugin; the Kalamos handwriting build does not bundle it.

Holding a parent chapter includes its subsections and stops before the next chapter. Holding a
subsection stops before the next entry at the same or higher level. Normal taps still navigate.
Full usage, supported behavior and limitations are in the [packaged README](tocshare.koplugin/README.md).

## Share a whole book

Hold an EPUB in KOReader's file browser and select **Share book text**. This sends all readable
text, including front matter outside the TOC, with the book title, author and optional cover.
Text up to 256 KiB is shared directly. Larger text is saved as a UTF-8 TXT file and shared
by a granted content URI; the full file bytes do not enter the Android transaction. The plugin
uses a 100 MiB text limit, matching Agora's attachment storage limit. Agora uses its
existing attachment flow after its incoming-file receiver update. Other targets must support
standard Android text-file sharing for large exports.

## Verification

- 29 range/menu tests pass with Lua 5.4 and KOReader's LuaJIT.
- 16 scenarios pass with the actual official KOReader v2026.07.1 Linux EPUB engine: EPUB 2/3,
  nested and same-page TOC boundaries, chapters spanning spine files, final-page text, Unicode,
  two font sizes and unchanged reading position.
- Android metadata sharing reuses the verified JNI sender, with `Device:doShareText` fallback.
  Chapter sharing and its metadata were accepted on device with 0.4.1. Whole-book interaction
  is new in 0.6.0 and remains for user physical-device testing.
- Text over 256 KiB automatically uses a granted file reference, including large chapters.
- Payloads over 100 MiB and invalid boundaries produce an error instead of silent truncation.

Run portable tests:

```bash
python3 integrations/koreader-toc-share/tests/run.py
```

For real-engine tests, extract an official KOReader Linux AppImage, then supply the runtime directory
containing `luajit`, `setupkoenv.lua`, `fonts` and `libs`:

```bash
python3 integrations/koreader-toc-share/package.py --koreader-runtime /path/to/squashfs-root/usr/lib/koreader
```

The engine test generates five original EPUB fixtures in a temporary directory. No private books,
reader settings, user data or network services are needed. See [research and primary sources](RESEARCH.md).

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
Sharesheet preview receives a granted FileProvider content URI via ClipData. Owned cover files expire after 24 hours, so delayed readers can still open them.

## Android installation: one current copy

Install the latest ZIP in `/sdcard/koreader/plugins/tocshare.koplugin`. A custom KOReader APK must
not also bundle `plugins/tocshare.koplugin`: KOReader loads both locations, and a bundled older
handler can take precedence over the externally updated plugin. The reader candidate verifier
checks that the independent TOC plugin is absent from the APK. Rebuild an older custom APK without
its bundled copy, replace the APK without clearing user data, then fully reopen KOReader.

Android's [sharing guide](https://developer.android.com/develop/ui/compose/sharing/send) specifies
`ACTION_SEND`, `EXTRA_TEXT`, `EXTRA_TITLE` and a granted content URI for a thumbnail preview.
The optional versioned JSON carries chapter/book/author labels for cooperating receivers. Agora
copies the text and cover into private attachment storage; it retains the book cover for display.

For JNI validation, generate the official SDK/JDK method listing shown in
`tests/android-api.py`, then pass `--android-signatures /path/to/android-signatures.txt` when
packaging. The sender checks method IDs and pending exceptions before invocation, uses the
SDK's void signature for `Intent.setClipData`, and leaves its JNI context before reporting failure.
See Android's [JNI exception guidance](https://developer.android.com/ndk/guides/jni-tips#exceptions).


## Large text file lifetime

Owned `tocshare-text-*.txt` exports and cover previews remain available for 24 hours; later shares
remove only expired plugin-owned files. The receiving app must copy granted bytes before its
Activity finishes. Agora uses its existing attachment importer and retains its own private copy.
`EXTRA_STREAM` identifies the text file. Both text and cover URIs are present in ClipData with read
permission; the optional JSON envelope still carries the title, author and bounded cover image.
The same Share book text / Share excerpt actions choose the transport automatically.
