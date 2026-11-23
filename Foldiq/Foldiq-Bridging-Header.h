#ifndef Foldiq_Bridging_Header_h
#define Foldiq_Bridging_Header_h

#include <stddef.h>

/// Inflate raw-DEFLATE bytes from a ZIP entry (compression method 8) straight
/// into an open file, in 1 MB pieces. Works for entries larger than 4 GB.
/// @param inputBuf   Compressed bytes (raw DEFLATE, no zlib header/trailer).
/// @param inputSize  Number of compressed bytes.
/// @param fd         Open, writable file descriptor; it is not closed.
/// @return           Number of bytes written, or -1 on corrupt data or a write error.
long long foldiq_inflate_to_fd(const unsigned char *inputBuf, size_t inputSize, int fd);

#endif /* Foldiq_Bridging_Header_h */
