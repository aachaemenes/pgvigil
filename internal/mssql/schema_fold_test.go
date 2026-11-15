package mssql

// The build review's B-4 and S-4 (20261115-150515): in a file of their own, so a box job can run them against
// bce3a4d3's schema.go (red there) without the fold's other tests, which need the fold's own types.

import "testing"

// B-4 of the build review: Azure SQL Managed Instance and Azure SQL Database answer Major 12 whatever engine they run,
// so the version refusal asks Kind first (red on bce3a4d3: both refused as 'needs SQL Server 2016').
func TestSchemaAppliesAzure(t *testing.T) {
	for _, c := range []struct {
		info Info
		want bool
	}{
		{Info{Kind: KindAzureMI, Major: 12}, true},
		{Info{Kind: KindAzureDB, Major: 12}, true},
		{Info{Kind: KindServer, Major: 12}, false},
		{Info{Kind: KindServer, Major: 13}, true},
		{Info{Kind: KindServer}, true},
	} {
		if got, why := (schemaCollector{}).Applies(c.info); got != c.want {
			t.Errorf("Applies(%s, %d) = %v (%s), want %v", c.info.Kind, c.info.Major, got, why, c.want)
		}
	}
}

// S-4 of the build review: a database started at the end of the 5-minute pass gets its 120 seconds before the run's
// deadline (red on bce3a4d3: 5m40s, so a database started at 4:59 was cut at 5:40).
func TestSchemaTimeoutCoversTheLastDatabase(t *testing.T) {
	if got, want := (schemaCollector{}).Timeout()-batchMargin, schemaPass+schemaPerDB; got < want {
		t.Errorf("the batch deadline is %v after the start, want at least %v (the pass plus one database)", got, want)
	}
}
