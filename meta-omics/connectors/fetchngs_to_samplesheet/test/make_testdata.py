#!/usr/bin/env python3
"""Regenerate testdata/samplesheet.csv: what nf-core/fetchngs 1.12.0 writes for the 12
LMO pilot runs, without downloading anything.

Metadata comes from the ENA portal API with the same field list upstream's run 01 passed
as --ena_metadata_fields (vagkaratzas/meta-omics-sig runs/01_fetchngs/params.yml). The
layout follows fetchngs 1.12.0 modules/local/sra_to_samplesheet: sample (the ERX
accession), fastq_1, fastq_2, then every metadata field, every value double-quoted. FASTQ
paths are written the way fetchngs writes them for --outdir out/r01_fetchngs:
<outdir>/fastq/<ERX>_<ERR>_<mate>.fastq.gz.

Usage: make_testdata.py IDS.csv OUT.csv
"""

import csv
import io
import sys
import urllib.parse
import urllib.request

FIELDS = (
    "run_accession,experiment_accession,sample_accession,secondary_sample_accession,"
    "study_accession,secondary_study_accession,submission_accession,run_alias,"
    "experiment_alias,sample_alias,study_alias,library_layout,library_selection,"
    "library_source,library_strategy,library_name,instrument_model,instrument_platform,"
    "base_count,read_count,tax_id,scientific_name,sample_title,experiment_title,"
    "study_title,sample_description,fastq_md5,fastq_bytes,fastq_ftp,fastq_galaxy,"
    "fastq_aspera,collection_date,lat,lon,depth,environmental_medium"
).split(",")
OUTDIR = "out/r01_fetchngs"


def runinfo(accession):
    query = urllib.parse.urlencode(
        {"accession": accession, "result": "read_run", "fields": ",".join(FIELDS), "format": "tsv"}
    )
    with urllib.request.urlopen(f"https://www.ebi.ac.uk/ena/portal/api/filereport?{query}") as fh:
        rows = list(csv.DictReader(io.StringIO(fh.read().decode()), delimiter="\t"))
    if len(rows) != 1:
        raise SystemExit(f"{accession}: expected 1 ENA row, got {len(rows)}")
    return rows[0]


def main(ids, out):
    accessions = [line.strip() for line in open(ids) if line.strip()]
    header = ["sample", "fastq_1", "fastq_2"] + FIELDS
    lines = [",".join(f'"{h}"' for h in header)]
    for acc in accessions:
        row = runinfo(acc)
        stem = f"{row['experiment_accession']}_{row['run_accession']}"
        values = [
            row["experiment_accession"],
            f"{OUTDIR}/fastq/{stem}_1.fastq.gz",
            f"{OUTDIR}/fastq/{stem}_2.fastq.gz",
        ] + [row.get(f, "") for f in FIELDS]
        lines.append(",".join(f'"{v}"' for v in values))
    with open(out, "w") as fh:
        fh.write("\n".join(lines) + "\n")
    print(f"wrote {len(accessions)} rows x {len(header)} columns to {out}", file=sys.stderr)


if __name__ == "__main__":
    main(*sys.argv[1:3])
