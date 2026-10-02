# Changelog

## 1.5.17

- The race also runs ZIP -9, with the same flags as the benchmark. The panel shows original, Furl, ZIP, and 7-Zip, and it stays on screen. Settings can save that result as `Name.race.txt` beside the first item. The switch is on by default. The compressor is unchanged.

## 1.5.16

- Return and Space follow the selected row. Opening a .furl reads the file table without freezing the window, and a drop during a read does not dismiss that window. A path that is also a folder is rejected instead of replacing the folder. The compressor is unchanged.

## 1.5.15

- Opening a .furl stays in one window.

## 1.5.14

- You can browse a .furl. Folders, sizes, and dates come from the file table, so the list does not unpack the solid stream. Opening, Quick Look, and Extract read that stream once. The compressor is unchanged.

## 1.5.13

- A Burrows-Wheeler block codes move-to-front zeros as runs, then an order-0 model, instead of order-5 PPM. The sample in the middle of each piece still has to come out clearly smaller than order-5 PPM, or that piece stays on PPM. Archives written without the run coder still unpack. A block that uses it needs this version.

## 1.5.12

- A long run of short, similar lines can be a Burrows-Wheeler block of at most 1 MB, then the usual text coder. A sample in the middle of each piece has to come out clearly smaller than order-5 PPM, or that piece stays on PPM. Prose is left on PPM. Older archives still unpack.

## 1.5.11

- A packed-file header has to be a real header. Gzip needs magic `1F 8B`, DEFLATE method `08`, and clear reserved flag bits. Zip needs a full four-byte local, end-of-directory, or split signature. JPEG needs the start-of-image marker followed by a real marker byte. Two matching bytes no longer store the high-entropy bytes that follow them, so a later copy of those bytes can still match.

## 1.5.10

- Unfurl writes files before symlinks, and it refuses to follow a symlink while creating a path. A link in the archive, or one already in the destination folder, cannot redirect a later file outside that folder. Archive bytes are unchanged.

## 1.5.9

- A file dated before 1970 can be furled, and Unfurl restores that time. A symlink’s modification time is restored on the link itself.
- Cancelling a 7-Zip race waits until the process has a status before the race reports a result. Equal sizes are a tie.
- Unfurl reads and writes off the main thread, and every dropped archive is unpacked. Dropping files works on the whole window.
- A codec stream with extra bytes after the last block is rejected. If the duplicate probe cannot allocate its table, that packed run stays on the parser so a later copy can still match.

## 1.5.8

- At the start or end of a large LZ block, a stretch that is already near 8 bits per byte and has almost no matches is stored on its own. The same stretch in the middle of the block stays there, so a match can still cross it. A 32-byte copy that reaches the rest of the block keeps the stretch on LZ.

## 1.5.7

- A block of 128 KB or more samples LZ, PPM, and the delta and E8 filters, and backs off a choice when every sample is clearly cheaper the other way. A sample does not store the block; that still happens only when the real encode expands.
- A packed run is stored only when a probe finds no copy of 256 bytes or more. The probe follows the bytes, so two copies of a file still match when their size is an awkward length. A shared header is shorter than that and stays stored.
- `Scripts/benchmark.sh` compares ZIP, Furl, and 7-Zip. The gap column is how far Furl sits from the larger archive toward the smaller one.

## 1.5.6

- Density 9 shortens its hash-chain search after a few kilobytes where matches gain very few bytes per candidate. A long match that only the deep chain can see restores the full search. The price test is unchanged. Old archives still unpack.

## 1.5.5

- Dropping several loose files no longer wraps each one in a folder named after its parent. A file stays a file. Two files with the same name become `name.txt` and `name-2.txt`. Folders you drop are unchanged.

## 1.5.4

- Predicted bits now count every LZ arithmetic decision, including literal context-mixing, so they measure the same stream as the coded size.
- The parse report adds match-length buckets, distance buckets, rep0–rep3, short non-repeat matches, and matches rejected because literals were cheaper.
- A match is encoded only when its flag, length, and distance cost less than those bytes as literals. Repeat distances compete with new distances on that price, and the one-byte lazy choice does too. Old archives still unpack.

## 1.5.3

- Settings has a parse-report switch. On, density 9 writes `Name.parse.txt` beside the archive. Off, that file is not written. The switch is on by default and does not change the archive.

## 1.5.2

- Density 9 no longer shows the parse report in the window. It writes `Name.parse.txt` beside the archive. The report is not part of the archive.

## 1.5.1

- The 1.5.0 model switch is reverted. Archives got larger, especially when two copies of the same high-entropy payload were stored and never matched. Compression decisions are the 1.4.3 ones again: long text stays on PPM, packed files are stored when their magic is recognized, and everything else is LZ with the previous lazy rule.
- Density 9 still records the parse: literals, matches, average and longest match, repeat-distance hits, candidates considered, match bytes versus literal bytes, and predicted model cost versus arithmetic-coded bits. The window shows that report after a density 9 Furl. The report does not change the bytes.

## 1.5.0

- Each stretch is classified before it is compressed: ordinary text stays on PPM, already-compressed bytes are stored, numeric runs can take a delta, and executables can take the call-site filter.
- Extremely repetitive blocks, and solid runs of many small files that repeat each other, use a long-match LZ parse so neighboring files share copies.
- Density 9 records the parse. Reverted in 1.5.1 except for that report: the new routes made archives larger.

## 1.4.3

- Skip options (AppleDouble, __MACOSX, .DS_Store, resource forks) live in the Settings menu. They are no longer checkboxes in the window.

## 1.4.2

- The 7-Zip race uses multi-threaded LZMA2 (`-mmt` on every core) instead of a single thread.
- When 7-Zip is not installed, the system LZMA fallback splits payloads of 2 MiB or more across cores.

## 1.4.1

- Stop (⌘.) cancels a running Furl, Unfurl, or 7-Zip race. Nothing is written, and Stop does not show an error.

## 1.4.0

- Archives now store POSIX permissions and symbolic links (container v2). Unfurl restores `+x` on app binaries and scripts, and recreates links such as `.build/release`.
- Existing v1 archives still unpack. Mach-O, shebang, `.sh`, and `Contents/MacOS/` files get execute permission even when the archive had no mode bits — so the current `Sigil.furl` can open its `.app` after a fresh unfurl. Re-furl the folder if you need the SwiftPM `.build` symlink preserved.

## 1.3.5

- Density 9 keeps similar files (three `Foundation-*.pcm` caches, etc.) in the same match window by splitting long runs on a file boundary instead of mid-file.
- Match picker prefers a closer copy unless a far one is clearly longer. Hash tables at density 9 are 23-bit; long copies insert every other byte.

## 1.3.4

- Much faster density 9: word-sized match scans, stop searching once a 64-byte match is found, skip hash inserts in the middle of long copies, and stop allocating the unused CM match window (up to hundreds of MiB per block). Literal coding hoists context hashes that were recomputed for every bit.
- Independent stream blocks encode in parallel (up to four at a time).

## 1.3.3

- Solid archives group files by extension then name so similar binaries (two `AppKit-*.pcm` caches, etc.) sit in the same match window — the same trick 7-Zip uses.
- The stream splits by content: long text runs use PPM, long JPEG/PNG/zip/… runs (detected by magic, then high-entropy body) are stored, the rest stay LZ. Medium-entropy binaries such as Clang `.pcm` stay on LZ so the match window is not shattered.

## 1.3.2

- Distance codes allow matches across the full 64 MiB dense block (slot 0–31). Density 9 on large folders no longer fails with “Could not encode this data.”

## 1.3.1

- Mixed folders (HTML plus images/fonts, etc.) no longer run the whole solid stream through PPM just because the first 4 KiB looked like text. Text detection samples the block; PPM encode failure falls back to LZ.
- Compress errors no longer show as “corrupt or truncated data.”

## 1.3.0

- By default, gathering skips AppleDouble (`._*`), `__MACOSX` folders, `.DS_Store`, and resource forks (`com.apple.ResourceFork` / `..namedfork/rsrc`). Only the data fork is stored.
- Hidden project files such as `.gitignore` are kept (no longer using a blanket “skip hidden files” walk).
- Toggles in the window, all on by default.

## 1.2.0

- Truncated or oversized integer fields now fail with `FurlError.format` instead of trapping on `Data` subscripts.
- Archive paths with `..`, `.`, empty segments, backslashes, colons, or a leading `/` are rejected on pack and unpack.
- Duplicate paths and more than 65,535 files are hard errors.
- File gathering prefixes loose files from different folders so they do not silently overwrite on unfurl.
- Idle UI status no longer claims every drop will beat 7-Zip.
- Tests cover hostile/truncated archives, path traversal, bad CRCs, and duplicate paths.
- CRC-32 is computed in Swift (no zlib import).

## 1.1.0

- Much stronger text path: order-5 PPM on large text (the 17 MB sources corpus drops from ~6.4 MB to ~5.4 MB).
- Larger match window (up to 64 MiB) and 2-byte matches for the LZ path.
- Repeat-distance coding and matched-literal prediction after copies.

## 1.0.0

- First release.
- Custom lossless codec (LZ77 + context-mixing arithmetic coder).
- Solid `.furl` archives of files and folders.
- Race against 7-Zip ultra when `7z` is installed.
- CLI: `compress`, `expand`, `race`.
