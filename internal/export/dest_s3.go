package export

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"sort"
	"strings"

	"github.com/aws/aws-sdk-go-v2/aws"
	awsconfig "github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/service/s3"
	"github.com/aws/aws-sdk-go-v2/service/s3/types"
	"github.com/aws/smithy-go"
)

// S3Options is an S3 destination: a bucket and a prefix, on AWS or on an S3-compatible store named by its endpoint.
// The credentials come from the AWS default chain (the environment, a profile, an instance role), never from the
// configuration file.
type S3Options struct {
	Bucket, Prefix, Region, Endpoint, Profile string
	Name                                      string // the repository's folder under the prefix
}

// The sizes of an upload: a file over s3PartLine goes up in parts of s3PartSize.
const (
	s3PartLine = 64 << 20
	s3PartSize = 16 << 20
)

type s3Dest struct {
	c      *s3.Client
	bucket string
	root   string // "<prefix>/<name>/"
	label  string
}

// NewS3 opens the destination. It makes no request: the first List or Put does.
func NewS3(ctx context.Context, o S3Options) (Destination, error) {
	var opts []func(*awsconfig.LoadOptions) error
	region := o.Region
	if region == "" && o.Endpoint != "" {
		region = "us-east-1" // a store named by its endpoint signs with any region; the SDK needs one
	}
	if region != "" {
		opts = append(opts, awsconfig.WithRegion(region))
	}
	if o.Profile != "" {
		opts = append(opts, awsconfig.WithSharedConfigProfile(o.Profile))
	}
	cfg, err := awsconfig.LoadDefaultConfig(ctx, opts...)
	if err != nil {
		return nil, fmt.Errorf("export.destination: the AWS configuration: %w", err)
	}
	client := s3.NewFromConfig(cfg, func(so *s3.Options) {
		if o.Endpoint != "" {
			so.BaseEndpoint = aws.String(o.Endpoint)
			so.UsePathStyle = true
		}
		// no checksum trailer of the SDK's own: S3-compatible stores differ on them, and every file's sha256 is in
		// the manifest for the consumer to hold the file to
		so.RequestChecksumCalculation = aws.RequestChecksumCalculationWhenRequired
		so.ResponseChecksumValidation = aws.ResponseChecksumValidationWhenRequired
	})
	root := strings.Trim(o.Prefix, "/")
	if root != "" {
		root += "/"
	}
	root += o.Name + "/"
	label := "s3://" + o.Bucket + "/" + root
	if o.Endpoint != "" {
		label += " at " + o.Endpoint
	}
	return &s3Dest{c: client, bucket: o.Bucket, root: root, label: label}, nil
}

func (d *s3Dest) String() string { return d.label }

func (d *s3Dest) Upload(ctx context.Context, key, local string) error {
	f, err := os.Open(local)
	if err != nil {
		return err
	}
	defer f.Close()
	st, err := f.Stat()
	if err != nil {
		return err
	}
	k := aws.String(d.root + key)
	if st.Size() <= s3PartLine {
		_, err = d.c.PutObject(ctx, &s3.PutObjectInput{Bucket: &d.bucket, Key: k, Body: f, ContentLength: aws.Int64(st.Size())})
		return err
	}
	up, err := d.c.CreateMultipartUpload(ctx, &s3.CreateMultipartUploadInput{Bucket: &d.bucket, Key: k})
	if err != nil {
		return err
	}
	var parts []types.CompletedPart
	for off, n := int64(0), int32(1); off < st.Size(); off, n = off+s3PartSize, n+1 {
		size := min(int64(s3PartSize), st.Size()-off)
		out, err := d.c.UploadPart(ctx, &s3.UploadPartInput{Bucket: &d.bucket, Key: k, UploadId: up.UploadId, PartNumber: aws.Int32(n),
			Body: io.NewSectionReader(f, off, size), ContentLength: aws.Int64(size)})
		if err != nil {
			// the parts already sent are given back: a store bills them until the upload is ended
			_, _ = d.c.AbortMultipartUpload(context.WithoutCancel(ctx), &s3.AbortMultipartUploadInput{Bucket: &d.bucket, Key: k, UploadId: up.UploadId})
			return fmt.Errorf("part %d: %w", n, err)
		}
		parts = append(parts, types.CompletedPart{ETag: out.ETag, PartNumber: aws.Int32(n)})
	}
	_, err = d.c.CompleteMultipartUpload(ctx, &s3.CompleteMultipartUploadInput{Bucket: &d.bucket, Key: k, UploadId: up.UploadId,
		MultipartUpload: &types.CompletedMultipartUpload{Parts: parts}})
	if err != nil {
		_, _ = d.c.AbortMultipartUpload(context.WithoutCancel(ctx), &s3.AbortMultipartUploadInput{Bucket: &d.bucket, Key: k, UploadId: up.UploadId})
	}
	return err
}

func (d *s3Dest) Put(ctx context.Context, key string, body []byte, onlyNew bool) error {
	in := &s3.PutObjectInput{Bucket: &d.bucket, Key: aws.String(d.root + key), Body: bytes.NewReader(body), ContentLength: aws.Int64(int64(len(body)))}
	if onlyNew {
		in.IfNoneMatch = aws.String("*")
	}
	_, err := d.c.PutObject(ctx, in)
	if s3Code(err, "PreconditionFailed") {
		return errExists
	}
	return err
}

func (d *s3Dest) Get(ctx context.Context, key string) ([]byte, error) {
	out, err := d.c.GetObject(ctx, &s3.GetObjectInput{Bucket: &d.bucket, Key: aws.String(d.root + key)})
	if err != nil {
		if s3Code(err, "NoSuchKey", "NotFound") {
			return nil, errAbsent
		}
		return nil, err
	}
	defer out.Body.Close()
	return io.ReadAll(out.Body)
}

func (d *s3Dest) Delete(ctx context.Context, key string) error {
	_, err := d.c.DeleteObject(ctx, &s3.DeleteObjectInput{Bucket: &d.bucket, Key: aws.String(d.root + key)})
	if s3Code(err, "NoSuchKey", "NotFound") {
		return nil
	}
	return err
}

func (d *s3Dest) List(ctx context.Context, prefix string) ([]string, error) {
	var keys []string
	p := s3.NewListObjectsV2Paginator(d.c, &s3.ListObjectsV2Input{Bucket: &d.bucket, Prefix: aws.String(d.root + prefix)})
	for p.HasMorePages() {
		page, err := p.NextPage(ctx)
		if err != nil {
			return nil, err
		}
		for _, o := range page.Contents {
			keys = append(keys, strings.TrimPrefix(aws.ToString(o.Key), d.root))
		}
	}
	sort.Strings(keys)
	return keys, nil
}

func s3Code(err error, codes ...string) bool {
	var ae smithy.APIError
	if err == nil || !errors.As(err, &ae) {
		return false
	}
	for _, c := range codes {
		if ae.ErrorCode() == c {
			return true
		}
	}
	return false
}
