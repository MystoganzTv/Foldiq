// ZipInflate.c
// Decompresses raw DEFLATE data (ZIP compression method 8) using system libz.
// libz ships with every macOS version — no external dependencies or SPM needed.

#include <stdlib.h>
#include <string.h>
#include <zlib.h>

/// Inflate raw-DEFLATE bytes from a ZIP entry.
/// @param inputBuf     Compressed bytes (raw DEFLATE, no zlib header/trailer).
/// @param inputSize    Number of compressed bytes.
/// @param outputSize   Expected uncompressed size (from the ZIP local file header).
/// @param outputBuf    On success: points to a malloc'd buffer the caller must free().
/// @return             Number of decompressed bytes written, or 0 on failure.
size_t foldiq_inflate(const unsigned char *inputBuf, size_t inputSize,
                     size_t outputSize, unsigned char **outputBuf) {
    if (outputSize == 0) { *outputBuf = NULL; return 0; }

    *outputBuf = (unsigned char *)malloc(outputSize);
    if (!*outputBuf) return 0;

    z_stream strm;
    memset(&strm, 0, sizeof(strm));
    strm.avail_in  = (uInt)inputSize;
    strm.next_in   = (z_const Bytef *)inputBuf;
    strm.avail_out = (uInt)outputSize;
    strm.next_out  = (Bytef *)*outputBuf;

    // windowBits = -15 → raw DEFLATE (no zlib header/trailer), window size 32 KB
    if (inflateInit2(&strm, -15) != Z_OK) {
        free(*outputBuf); *outputBuf = NULL; return 0;
    }

    int ret = inflate(&strm, Z_FINISH);
    inflateEnd(&strm);

    if (ret != Z_STREAM_END) {
        free(*outputBuf); *outputBuf = NULL; return 0;
    }
    return (size_t)strm.total_out;
}
