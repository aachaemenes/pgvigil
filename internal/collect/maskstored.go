package collect

// MaskStored is the credential mask one stored value takes (maskStored: MaskXML for a value that reads as an XML
// document, MaskCredentials otherwise), for a package that stores a text this package did not collect: the request
// queue's results (CQ task 488, internal/cq.MaskResult).
func MaskStored(s string) string { return maskStored(s) }
