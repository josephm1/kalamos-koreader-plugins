# Kalamos KOReader plugins

Source repository for the two currently maintained plugin families, with portable tests
and licensing. These are plugins; the modified reader/native build stays in
[josephm1/kalamos-koreader](https://github.com/josephm1/kalamos-koreader).

## Share TOC excerpts and whole-book text

`integrations/koreader-toc-share/tocshare.koplugin` works on stock Android KOReader. Hold a TOC
entry to Share excerpt; hold an EPUB in the file browser to Share book text. Uses Android sharing,
book/excerpt metadata and optional cover thumbnails. Large text is shared as a granted file.

```sh
python3 integrations/koreader-toc-share/tests/run.py
python3 integrations/koreader-toc-share/package.py --output dist/koreader-toc-share.zip
```

Extract the resulting tocshare.koplugin directory into KOReader's plugin directory (usually
/sdcard/koreader/plugins/) and restart the reader. See its README for range, metadata and limits.

## Kalamos handwriting

`integrations/koreader/kalamos.koplugin` contains page handwriting, sticky notes, EPUB writing
spaces, selection/eraser tools, toolbar, storage and background-save/lifecycle handling. It requires
the matching modified KOReader engine/launcher and selected native InkSDK provider. Copying Lua
into a stock reader does not supply native handwriting or writing-space engine methods.
Generic Android builds use public stylus input; Bigme builds retain their separate daemon path.

```sh
python3 integrations/koreader/tests/run.py
```

Build instructions and pinned upstream revisions belong to kalamos-koreader. Do not install an
external duplicate of a plugin already bundled into that reader. The generic Android pen work is
confirmed by the owner on a Huion Note E; this does not establish universal device compatibility.

No source books, OSCE files, device notebooks, binaries or credentials are included. Original
plugin LICENSE and NOTICE files retain applicable terms.

## Upstream credit and licence

Built for **[KOReader and its contributors](https://github.com/koreader/koreader)**.
Original Kalamos plugin contributions use **[AGPL-3.0-or-later](COPYING)**.
The JNI scaffolding credits **Alexander Mikhailian's MIT-licensed
[Android App Launcher plugin](https://github.com/omer-faruq/android-app-launcher.koplugin)**;
its original notice and full MIT text remain in the handwriting plugin.
Native ink is supplied separately by [Kalamos InkSDK](https://github.com/josephm1/kalamos-inksdk),
built on [InkSDK by Ed Wei](https://github.com/imedwei/inksdk). This is an independent project.

Downloadable plugin ZIPs are under [Releases](https://github.com/josephm1/kalamos-koreader-plugins/releases).
