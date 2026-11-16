package export

import (
	"context"
	"fmt"
	"io"
	"os"
	"sort"
	"strings"

	"github.com/Azure/azure-sdk-for-go/sdk/azcore"
	"github.com/Azure/azure-sdk-for-go/sdk/azidentity"
	"github.com/Azure/azure-sdk-for-go/sdk/storage/azblob"
	"github.com/Azure/azure-sdk-for-go/sdk/storage/azblob/blob"
	"github.com/Azure/azure-sdk-for-go/sdk/storage/azblob/bloberror"
)

// BlobOptions is an Azure Blob destination: a container and a prefix. One of three ways in: a connection string, a
// SAS URL of the account (both resolved from env: or file:, never written in the configuration), or the account's
// URL with the default credential (a managed identity, the environment, the Azure CLI's login).
type BlobOptions struct {
	AccountURL, Container, Prefix string
	ConnectionString, SASURL      string
	Name                          string // the repository's folder under the prefix
}

type blobDest struct {
	c         *azblob.Client
	container string
	root      string
	label     string
}

// NewAzureBlob opens the destination. It makes no request: the first List or Put does.
func NewAzureBlob(o BlobOptions) (Destination, error) {
	var c *azblob.Client
	var err error
	how := ""
	switch {
	case o.ConnectionString != "":
		c, err = azblob.NewClientFromConnectionString(o.ConnectionString, nil)
		how = "a connection string"
	case o.SASURL != "":
		c, err = azblob.NewClientWithNoCredential(o.SASURL, nil)
		how = "a SAS URL"
	case o.AccountURL != "":
		var cred azcore.TokenCredential
		if cred, err = azidentity.NewDefaultAzureCredential(nil); err == nil {
			c, err = azblob.NewClient(o.AccountURL, cred, nil)
		}
		how = o.AccountURL + " with the default credential"
	default:
		return nil, fmt.Errorf("export.destination: azure_blob has no way in: connection_string and sas_url resolve to nothing and account_url is not set")
	}
	if err != nil {
		return nil, fmt.Errorf("export.destination: azure_blob by %s: the client cannot be made", how) // the SDK's message can carry the secret
	}
	root := strings.Trim(o.Prefix, "/")
	if root != "" {
		root += "/"
	}
	root += o.Name + "/"
	return &blobDest{c: c, container: o.Container, root: root, label: "azure blob container " + o.Container + "/" + root + " by " + how}, nil
}

func (d *blobDest) String() string { return d.label }

func (d *blobDest) Upload(ctx context.Context, key, local string) error {
	f, err := os.Open(local)
	if err != nil {
		return err
	}
	defer func() { _ = f.Close() }()
	_, err = d.c.UploadFile(ctx, d.container, d.root+key, f, &azblob.UploadFileOptions{BlockSize: 16 << 20, Concurrency: 2})
	return err
}

func (d *blobDest) Put(ctx context.Context, key string, body []byte, onlyNew bool) error {
	var o *azblob.UploadBufferOptions
	if onlyNew {
		any := azcore.ETagAny
		o = &azblob.UploadBufferOptions{AccessConditions: &blob.AccessConditions{ModifiedAccessConditions: &blob.ModifiedAccessConditions{IfNoneMatch: &any}}}
	}
	_, err := d.c.UploadBuffer(ctx, d.container, d.root+key, body, o)
	if bloberror.HasCode(err, bloberror.BlobAlreadyExists, bloberror.ConditionNotMet) {
		return errExists
	}
	return err
}

func (d *blobDest) Get(ctx context.Context, key string) ([]byte, error) {
	out, err := d.c.DownloadStream(ctx, d.container, d.root+key, nil)
	if err != nil {
		if bloberror.HasCode(err, bloberror.BlobNotFound) {
			return nil, errAbsent
		}
		return nil, err
	}
	defer func() { _ = out.Body.Close() }()
	return io.ReadAll(out.Body)
}

func (d *blobDest) Delete(ctx context.Context, key string) error {
	_, err := d.c.DeleteBlob(ctx, d.container, d.root+key, nil)
	if bloberror.HasCode(err, bloberror.BlobNotFound) {
		return nil
	}
	return err
}

func (d *blobDest) List(ctx context.Context, prefix string) ([]string, error) {
	var keys []string
	p := d.root + prefix
	pager := d.c.NewListBlobsFlatPager(d.container, &azblob.ListBlobsFlatOptions{Prefix: &p})
	for pager.More() {
		page, err := pager.NextPage(ctx)
		if err != nil {
			return nil, err
		}
		for _, b := range page.Segment.BlobItems {
			if b.Name != nil {
				keys = append(keys, strings.TrimPrefix(*b.Name, d.root))
			}
		}
	}
	sort.Strings(keys)
	return keys, nil
}
