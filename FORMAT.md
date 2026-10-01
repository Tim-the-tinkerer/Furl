# Furl format

## Container (`FURL` / `.furl`)

Little-endian.

| Offset | Size | Field |
|--------|------|--------|
| 0 | 4 | Magic `FURL` |
| 4 | 1 | Version (`1` or `2`) |
| 5 | 1 | Flags (bit 0 = solid payload) |
| 6 | 4 | File count (1…65,535; must equal table count) |
| 10 | 4 | Reserved |
| 14 | … | File table |
| … | 8 | Compressed payload length |
| … | n | FCM1 payload |

File table:

| Size | Field |
|------|--------|
| 2 | Table count (must equal file count) |
| 2 | Name length |
| n | UTF-8 relative path (`/` separators) |
| 8 | Uncompressed size |
| 4 | CRC-32 of file bytes |
| 8 | POSIX mtime (whole seconds; a time before 1970 is a signed 64-bit count in these bytes) |
| 2 | Version 2: POSIX mode (`0o644`, `0o755`, …) |
| 1 | Version 2: kind (`0` file, `1` symlink) |
| 2 | Version 2: extra length |
| n | Version 2: extra (symlink target UTF-8) |

Version 1 tables stop at mtime. Unpackers must still read v1; v1 files get inferred `+x` for Mach-O, shebangs, `.sh`, and `Contents/MacOS/`. Symlinks are only stored in v2 — they were skipped in v1, which is why a restored `.app` could lose execute bits and `.build/release` could vanish.

POSIX mtime is whole seconds. A time before 1970 is a signed 64-bit count in the same 8 bytes. A reader from 1.5.8 or earlier would show that count as a date far in the future. Those readers never wrote one: the writer stopped before saving the file. A non-negative time is stored the same way as before.

Paths are relative, unique, at most 65,535 UTF-8 bytes, and must not contain `\\`, `:`, NUL, empty segments, `.`, or `..`. Unpackers must reject those paths rather than rewrite them. Extraction writes files before symlinks and refuses to follow a symlink while creating a path, so a link cannot redirect a later entry outside the destination. Trailing bytes after the compressed payload are invalid.

The payload is the concatenation of file contents, compressed with the FCM1 stream codec. Furl 1.x holds that solid payload in memory (capped at 8 GiB).

## Stream (`FCM1`)

Produced by `furl_compress` in `Sources/CFurl`.

| Offset | Size | Field |
|--------|------|--------|
| 0 | 4 | Magic `FCM1` |
| 4 | 1 | Level 1–9 |
| 5 | 1 | Flags (bit 0 = CRC present) |
| 6 | 2 | Reserved |
| 8 | 8 | Original size |
| 16 | 4 | CRC-32 of original |
| 20 | 4 | Block count |
| 24 | … | Blocks |

Each block (variable size; the compressor may emit several blocks per 64 MiB of input):

| Size | Field |
|------|--------|
| 4 | Raw size |
| 4 | Flags (`RAW`, `BWT`, `E8`, `DELTA`, `MTF`, `PPM`, `ZRLE`) |
| 4 | BWT primary index (0 if unused) |
| 4 | Stored size |
| n | Stored bytes |

Codec, per block:

- Long text runs (`PPM` flag): order-5 PPM with hashed contexts and exclusion, coded through the same arithmetic bit engine. A run of at least 256 KB is cut into pieces of at most 1 MB. A piece whose middle sample is clearly smaller after a Burrows-Wheeler transform and move-to-front is stored with `BWT`, `MTF`, and `ZRLE`: zeros in the move-to-front bytes are run-coded, then an order-0 arithmetic model codes the symbols. The stored bytes start with a 4-byte symbol count. Pieces that lose the sample are joined back into one PPM block. A block that does not set `ZRLE` is the older path (`BWT`+`MTF`+`PPM`, or PPM alone) and still unpacks on readers that understand those flags. `ZRLE` is bit 6 of the block flags. Delta width stays in bits 8–15.
- Long already-packed runs (`RAW` flag): stored bytes (JPEG, PNG, zip, …) recognized by a full header, including the high-entropy body that follows that header. Gzip requires method 8 and clear reserved flags. Zip requires a four-byte signature. JPEG requires a marker after the start-of-image. A two-byte collision does not start a stored run. A run that contains a second copy of 256 bytes or more is matched instead of stored. At the start or end of a large LZ block, a stretch that is already near 8 bits per byte and has almost no matches is stored the same way, unless those bytes also occur elsewhere in the block. The same stretch in the middle of the block stays with the block. A block that expands past the input is stored after the encode.
- Otherwise: LZ77 (2-byte minimum on short distances, 3/4-byte hash chains, lazy parse, last-4 repeat distances) + context-mixing literals. A match is emitted when its token prices below the same bytes as literals; a repeat distance can win over a longer new distance on that price. At density 9 the chain budget shortens after a few kilobytes of search that gain very few match bytes per candidate, and a long match visible only deeper in the chain restores the full budget. A block of 128 KB or more also samples LZ, PPM, and the delta and E8 filters, and backs off a choice when every sample is clearly cheaper the other way. Executables with enough call sites get an E8/E9 filter first. Structured numeric blocks may get a 16-bit or 32-bit delta.
- Density 9 can fill an optional `FurlParseStats` (not stored in the archive) with literal and match counts, length and distance histograms, repeat-distance slots, candidates considered, matches rejected as too expensive, and predicted model cost versus coded bits. Predicted bits include literal context-mixing. When Parse report is on in the Settings menu, the app writes those counters beside the archive as `Name.parse.txt`. That text file is not required to unpack.

Decompressors must honor the stored level so model sizes match.
