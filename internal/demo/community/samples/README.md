# The demo's stored samples of the community tools

One gzipped JSON file per tool (`<tool>.json.gz`), written by `scripts/capture-community-samples.sh` through the pack
command (`internal/demo/community/pack`) on a test server built for the capture. Never edited by hand: capture again.
The tests of this package (`go test ./internal/demo/community/`) check every file: rows in every sample, the set under
1 MB, and no name of the capture's own machine in any of them.
