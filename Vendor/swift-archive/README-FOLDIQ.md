# Foldiq archive dependency

This directory vendors the `Archive` Swift package sources from
`marcprux/swift-archive` 3.8.9 (libarchive), under the license in `COPYING`.

Foldiq deliberately builds the package without the optional `LZMASupport` and
`ZstdSupport` traits. Those traits link Homebrew libraries by absolute path on
some Xcode CI versions, which makes a signed app fail to launch on Macs that do
not have the same Homebrew installation. Foldiq uses this package for RAR and
uses the separate self-contained SevenZip package for 7z archives.
