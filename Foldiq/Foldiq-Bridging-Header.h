#ifndef Foldiq_Bridging_Header_h
#define Foldiq_Bridging_Header_h

#include <stddef.h>

/// Inflate raw-DEFLATE bytes from a ZIP entry (compression method 8).
/// @param inputBuf     Compressed bytes (raw DEFLATE, no zlib header/trailer).
/// @param inputSize    Number of compressed bytes.
/// @param outputSize   Expected uncompressed size (from the ZIP local file header).
/// @param outputBuf    On success: points to a malloc'd buffer the caller must free().
/// @return             Number of decompressed bytes written, or 0 on failure.
size_t foldiq_inflate(const unsigned char *inputBuf, size_t inputSize,
                     size_t outputSize, unsigned char **outputBuf);

#endif /* Foldiq_Bridging_Header_h */
