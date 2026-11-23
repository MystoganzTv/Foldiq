// ZipInflate.c
// Decompresses raw DEFLATE data (ZIP compression method 8) using system libz.
// libz ships with every macOS version — no external dependencies or SPM needed.

#include <errno.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <zlib.h>

#define FOLDIQ_INFLATE_OUT_CHUNK (1u << 20)   // 1 MB of output per write
#define FOLDIQ_INFLATE_IN_CHUNK  (1u << 30)   // z_stream counts are 32-bit

static int foldiq_write_all(int fd, const unsigned char *buf, size_t len) {
    while (len > 0) {
        ssize_t n = write(fd, buf, len);
        if (n < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        buf += n;
        len -= (size_t)n;
    }
    return 0;
}

/// Inflate raw-DEFLATE bytes from a ZIP entry straight into a file.
/// Streams in 1 MB pieces, so entries larger than memory (or than 4 GB,
/// as in ZIP64 Google Takeout exports) never need one big buffer.
/// @param inputBuf   Compressed bytes (raw DEFLATE, no zlib header/trailer).
/// @param inputSize  Number of compressed bytes.
/// @param fd         Open, writable file descriptor; it is not closed.
/// @return           Number of bytes written, or -1 on corrupt data or a write error.
long long foldiq_inflate_to_fd(const unsigned char *inputBuf, size_t inputSize, int fd) {
    unsigned char *out = (unsigned char *)malloc(FOLDIQ_INFLATE_OUT_CHUNK);
    if (!out) return -1;

    z_stream strm;
    memset(&strm, 0, sizeof(strm));
    // windowBits = -15 → raw DEFLATE (no zlib header/trailer), window size 32 KB
    if (inflateInit2(&strm, -15) != Z_OK) {
        free(out);
        return -1;
    }

    const unsigned char *next = inputBuf;
    size_t remaining = inputSize;
    long long total = 0;
    int ret;

    do {
        if (strm.avail_in == 0 && remaining > 0) {
            size_t chunk = remaining > FOLDIQ_INFLATE_IN_CHUNK ? FOLDIQ_INFLATE_IN_CHUNK : remaining;
            strm.next_in = (z_const Bytef *)next;
            strm.avail_in = (uInt)chunk;
            next += chunk;
            remaining -= chunk;
        }
        strm.next_out = out;
        strm.avail_out = FOLDIQ_INFLATE_OUT_CHUNK;

        ret = inflate(&strm, Z_NO_FLUSH);
        // Z_BUF_ERROR here means the input ran out before the stream ended:
        // a truncated entry. Anything else but OK/STREAM_END is corrupt data.
        if (ret != Z_OK && ret != Z_STREAM_END) {
            total = -1;
            break;
        }
        size_t have = FOLDIQ_INFLATE_OUT_CHUNK - strm.avail_out;
        if (have > 0 && foldiq_write_all(fd, out, have) != 0) {
            total = -1;
            break;
        }
        total += (long long)have;
    } while (ret != Z_STREAM_END);

    inflateEnd(&strm);
    free(out);
    return total;
}
