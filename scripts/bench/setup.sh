#!/bin/zsh
# Sets up the speech engines for scripts/bench/compare.py, all on this Mac, in ~/Library/Caches/MumbleBench:
# Whisper large-v3 turbo (WhisperKit, ~630 MB), Parakeet TDT v3 (FluidAudio, ~500 MB) and a helper for Apple's
# engine. Then starts Whisper's local server, which keeps the model loaded (its first load takes a few minutes).
set -euo pipefail
here=${0:A:h}
bench=~/Library/Caches/MumbleBench
model=~/Library/Application\ Support/Mumble/Whisper/models/argmaxinc/whisperkit-coreml/openai_whisper-large-v3-v20240930_turbo_632MB
mkdir -p $bench && cd $bench

command -v whisperkit-cli >/dev/null || brew install whisperkit-cli
[[ -d FluidAudio ]] || git clone --depth 1 https://github.com/FluidInference/FluidAudio.git
[[ -x FluidAudio/.build/release/fluidaudiocli ]] ||
    (cd FluidAudio && swift build -c release --product fluidaudiocli --disable-keychain --disable-netrc)
[[ -x apple-transcribe ]] || swiftc -O -parse-as-library $here/apple-transcribe.swift -o apple-transcribe

if ! curl -s -o /dev/null localhost:50060; then
    if [[ ! -d $model ]]; then
        model_args=(--model large-v3-v20240930_turbo_632MB --download-model-path ~/Library/Application\ Support/Mumble/Whisper)
    else
        model_args=(--model-path $model)
    fi
    nohup whisperkit-cli serve $model_args --port 50060 > whisper-server.log 2>&1 &
    echo "Whisper's server is starting; it's ready when this answers: curl localhost:50060"
fi
