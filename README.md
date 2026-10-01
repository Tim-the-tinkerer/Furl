# Furl

Native macOS app with a **custom lossless compressor**. It is not a front end for 7-Zip. The codec is LZ77 matching plus a context-mixing arithmetic coder, packed as a solid `.furl` archive.

**Version:** 1.5.13 — see [CHANGELOG.md](CHANGELOG.md).

## Where Furl should land

On an ordinary folder, Furl should usually sit between ZIP and 7-Zip, and it should not fall badly behind either one. Beating 7-Zip on highly redundant data is a bonus, not the goal. `Scripts/benchmark.sh` prints that comparison. The gap column is how far Furl sits from the larger archive toward the smaller one: 100% matches the smaller tool, 0% matches the larger one.

Large natural-language / source corpora use an order-5 PPM path. A long run of short, similar lines is tried as 1 MB Burrows-Wheeler blocks. Move-to-front zeros in that block are run-coded, and the block is kept only when a sample is clearly smaller than order-5 PPM. Other data uses LZ77 plus context mixing. On the 17 MB “404 sources” text dump Furl is ~5.4 MB vs zip ~6.6 MB vs 7-Zip ultra ~5.0 MB. The **Race 7-Zip** button shows both sizes on whatever you drop.

7-Zip’s LZMA2 can still win on some unique text, source trees, and binaries. Already-compressed media (JPEG, MP4, zip) stays stored once Furl recognizes it, unless those same bytes show up again: a repeated icon is matched, a shared file header is not. The race panel always shows both sizes so you can see who won for *this* payload.

Density 9 can write that report beside the archive as `Name.parse.txt`: which model ran, how long the matches were, how far away they were, how often a previous distance was reused, how many short matches were turned down, and whether the arithmetic coder matched the probabilities it was given. The parser keeps a match only when that token is cheaper than literals. At density 9, a stretch of short matches shortens the hash-chain search; a long match the short chain cannot see restores it. A large block samples LZ, PPM, and the filters, and backs off a choice when the samples agree it is the expensive one. A near-random stretch at the start or end of a large LZ block is stored; the same stretch in the middle stays, so a match can still cross it. The Settings menu turns the file on or off. It is on by default, and it is not part of the archive. The CLI prints the same report.

## Features

- Drag-and-drop files or folders
- Density 1 (fast) through 9 (smallest)
- Stop (⌘.) cancels a running compression, expand, or race
- Solid `.furl` archives
- Unfurl restores the original tree
- Race 7-Zip ultra, multi-threaded LZMA2 (uses `/opt/homebrew/bin/7z` when present; otherwise system LZMA across cores)
- CLI on the same binary
- Skips Apple metadata by default: `._*` AppleDouble, `__MACOSX`, `.DS_Store`, resource forks (Settings menu)
- Settings can turn the density 9 parse report on or off

## Limits (1.x)

Furl 1.x builds one **solid** compressed stream and keeps that payload in memory, along with per-file `Data` from gathering. A multi-gigabyte folder can need several times its size in RAM. Packing fails cleanly above 8 GiB uncompressed or 65,535 files. Streaming the solid input is the main v2 job.

## Requirements

- macOS 13 or later
- Swift toolchain (`xcode-select` / Xcode)
- Optional: 7-Zip (`brew install p7zip`) for the race

## Build & run

```bash
cd ~/Apps-Usefull/Furl
chmod +x build-app.sh
./build-app.sh
```

Build without launching:

```bash
./build-app.sh --no-launch
```

Tests:

```bash
swift run FurlTests
```

## CLI

```bash
.build/release/Furl compress -l 9 notes.json notes.furl
.build/release/Furl expand notes.furl restored
.build/release/Furl race -l 9 notes.json
```

After packaging, the binary is `Furl.app/Contents/MacOS/Furl`.

## Format

See [FORMAT.md](FORMAT.md) for the `FURL` container and `FCM1` stream.

## Tests

Custom executable suite (no XCTest):

```bash
swift run FurlTests
```
