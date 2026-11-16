package format

// The hub's caps on the small files of a bundle, read before anything else is trusted: a drop file past its cap is set
// aside 'too_big' and read no further (a view file's own cap is its manifest bytes). A one-view manifest is about 2 KB;
// a megabyte holds thousands of file entries. An Ed25519 signature line is under 100 bytes.
const (
	// MaxManifestBytes caps manifest.json and SHA256SUMS
	MaxManifestBytes = 1 << 20
	// MaxSigBytes caps manifest.sig
	MaxSigBytes = 4 << 10
)
