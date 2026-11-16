package export

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"net/url"
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

// s3CompatibleRegion is the signing region of an S3-compatible store named by its endpoint when neither the
// destination nor the AWS configuration names one: such a store signs with any region, and the SDK needs one. An AWS
// host never takes it (awsHost). It is the one listed exception of the hard-coded partition scan
// (internal/collect/aws_partition_test.go, awsExceptions).
const s3CompatibleRegion = "us-east-1"

// awsHost says whether an endpoint is one of AWS's own hosts, in any partition (China's domain carries one label
// more): such a host is never signed with s3CompatibleRegion. The scan's other listed exception.
func awsHost(endpoint string) bool {
	host := endpoint
	if u, err := url.Parse(endpoint); err == nil && u.Host != "" {
		host = u.Hostname()
	}
	return strings.Contains("."+strings.ToLower(host)+".", ".amazonaws.com.")
}

// NewS3 opens the destination. It makes no request: the first List or Put does. The signing region is the
// destination's own, else the AWS configuration's (AWS_REGION, the profile's region); only then, for an endpoint
// that is not AWS's, s3CompatibleRegion. An AWS destination with no region anywhere is refused: pgvigil picks no
// AWS region (a government endpoint must never sign as a commercial region).
func NewS3(ctx context.Context, o S3Options) (Destination, error) {
	var opts []func(*awsconfig.LoadOptions) error
	if o.Region != "" {
		opts = append(opts, awsconfig.WithRegion(o.Region))
	}
	if o.Profile != "" {
		opts = append(opts, awsconfig.WithSharedConfigProfile(o.Profile))
	}
	cfg, err := awsconfig.LoadDefaultConfig(ctx, opts...)
	if err != nil {
		return nil, fmt.Errorf("export.destination: the AWS configuration: %w", err)
	}
	if cfg.Region == "" {
		if o.Endpoint == "" || awsHost(o.Endpoint) {
			where := "AWS S3"
			if o.Endpoint != "" {
				where = o.Endpoint
			}
			return nil, fmt.Errorf("export.destination: no region for %s: set export.destination.region (or AWS_REGION, or the profile's region) - pgvigil picks no AWS region", where)
		}
		cfg.Region = s3CompatibleRegion
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
	defer func() { _ = f.Close() }()
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
	if s3Code(err, "PreconditionFailed", "ConditionalRequestConflict") {
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
	defer func() { _ = out.Body.Close() }()
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
