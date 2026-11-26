#!/bin/sh
# tune-sync 빌드 (macOS 15+, Apple 실리콘). 저장소 맨 위에서 실행: sh Tools/TuneSync/build.sh
set -e
swiftc -O -target arm64-apple-macos15 -o tune-sync \
  Tune/Services/LyricsParsing.swift \
  Tune/Library/MetadataReader.swift \
  Tune/Services/Aligner/AlignerCore.swift Tune/Services/Aligner/AlignerDSP.swift \
  Tune/Services/Aligner/AlignerPipeline.swift Tune/Services/Aligner/AlignerLyrics.swift \
  Tools/TuneSync/Stubs.swift Tools/TuneSync/main.swift
