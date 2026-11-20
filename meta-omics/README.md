# Meta-omics

The nf-core meta-omics SIG's end-to-end use case
([vagkaratzas/meta-omics-sig](https://github.com/vagkaratzas/meta-omics-sig)), rebuilt as one
nf-meta metapipeline: [`metaomics.yaml`](metaomics.yaml). The dataset is the LMO pilot: 12 ENA
runs ([`ids.csv`](ids.csv)) covering 3 dates and 3 omics layers (16S amplicon, metagenome,
metatranscriptome) from the Baltic Sea.

Upstream ran each pipeline by hand on Seqera Platform and called a Python converter in between.
Here those converters are pipeline steps, and every pipeline version and parameter is taken from
upstream's `runs/NN_*/params.yml` at commit `8092df6`.

```
r01 fetchngs 1.12.0
 ├─ c01_mt_reads ─────► r02 metatdenovo ─► c02_mt_proteins ─► r03 proteinfamilies ─► r07 proteinannotator
 ├─ c01_mt_detaxizer ─► r04 detaxizer ───────────────────────────────────────────► r09 taxprofiler
 │                        └─► c04_mt_filtered_reads ─► x01 metatdenovo           (not run upstream)
 ├─ c01_mg_reads ─────► r05 mag ─────────► c05_mg_proteins ─► r06 proteinfamilies ─► x02 proteinannotator (not run upstream)
 └─ c01_amp_reads ────► r08 ampliseq
```

Step ids carry upstream's run numbers from `RUNS.md`:
- `rNN`: runs upstream executed.
- `cNN`: connectors; `NN` is the run they read from.
- `xNN`: edges that have no upstream results to compare against.

## Layout

| Path | What |
|---|---|
| `metaomics.yaml` | The metapipeline |
| `connectors/<name>/` | One small Nextflow pipeline per converter: `main.nf`, `nextflow.config`, `nextflow_schema.json`, `test/` (nf-test) |
| `connectors/<name>/bin/*.py` | Upstream's `scripts/converters/*.py`, **copied byte-for-byte**. Nextflow puts `bin/` on the task PATH and mounts it into containers |
| `connectors/base.config` | Shared by all connectors: nf-schema, profiles, nf-core institutional configs, the `python:3.12-slim` container |
| `connectors/fetch_references/` | Not a step: a standalone pipeline that downloads, verifies and unpacks the reference inputs (see [Reference data](#reference-data)) |
| `inputs.example.yaml` | The reference inputs as laid out by `fetch_references`, for `--inputs-file` |
| `configs/` | Per-step Nextflow configs for upstream's workarounds (`nf_config:` in the metapipeline) |
| `run_m3c.sh` | SLURM head job for the M3C cluster |

The connectors add only wiring around the scripts. There is one exception:
`mag_to_proteinfamilies` creates the pooled FASTA, and the script records it at its work-directory
path. The connector rewrites that path to the published copy, keeping the script's `\r\n` line
endings.

## Run

```bash
# Read by the Nextflow launcher itself, so a config file can't set them (see "nf-meta gaps"):
export NXF_SYNTAX_PARSER=v1         # fetchngs 1.12.0 and detaxizer 1.3.0 don't parse otherwise
export NXF_OPTS="-Xms2g -Xmx16g"    # r06_proteinfamilies_mg head JVM (proteinfamilies#191)

nf-meta validate metaomics.yaml
nf-meta run metaomics.yaml --dry-run -p m3c
nf-meta run metaomics.yaml -p m3c --inputs-file lmo-inputs.yaml
```

The reference databases upstream downloaded by hand are inputs without a default: `phix_fasta`,
`taxprofiler_databases`, `sylph_taxonomy`, `pfam_db`, `funfam_db` and `interproscan_db`. Their
descriptions in `metaomics.yaml` give each one's URL and checksum. Without `--inputs-file`,
nf-meta asks for them.

On M3C, submit `run_m3c.sh` instead (edit its paths first).

## Reference data

All six reference inputs, about 46 GB and ~60 GB unpacked, can be fetched with
`connectors/fetch_references`, a standalone Nextflow pipeline:

```bash
nextflow run connectors/fetch_references/main.nf -profile m3c --outdir /shared/meta-omics-refs
sed 's#/refs#/shared/meta-omics-refs#' inputs.example.yaml > lmo-inputs.yaml
```

It reads `assets/references.tsv`: fixed URLs and pinned checksums.

| Reference | Input | Checksum source |
|---|---|---|
| phiX174 NC_001422.1 | `phix_fasta` | sha256 recorded here, two downloads agree |
| Kraken2 PlusPF-16 2026-06-26, sylph GTDB r232 c200 | `taxprofiler_databases` | sha256 recorded here |
| sylph-tax GTDB r232 metadata | `sylph_taxonomy` | md5 from Zenodo |
| Pfam 38.0 | `pfam_db` | md5 from EBI's `md5_checksums` |
| FunFam v4.3.0 | `funfam_db` | sha256 recorded here; byte count = Content-Length, gzip CRC ok |
| InterProScan 5.59-91.0 | `interproscan_db` | md5 from EBI's `.md5` file; sha256 recorded here |

What the pipeline does:
- **Verification:** files are checked while they download. A mismatch fails the task and stores
  nothing.
- **Dropped transfers:** resumed with HTTP Range requests. download.cathdb.info cuts FunFam off
  after a few MB every time.
- **InterProScan:** the release is pressed with its own `setup.py`, inside the container that
  proteinannotator's INTERPROSCAN module uses.
- **Taxprofiler sheet:** `taxprofiler_databases.csv` is written with absolute paths into `--outdir`.
- **Caching:** outputs are written with Nextflow's `storeDir`, so whatever is already in `--outdir`
  is not downloaded again. Delete `<outdir>/<name>/` to force a fresh download.
- **Provenance:** each reference directory has a `SOURCE.json`. `references.tsv` next to them lists
  every URL, size and checksum, and which checksums were verified.

Files downloaded by hand work just as well. Check them against the checksums in the input
descriptions.

References this metapipeline does not pin:
- **NMPFams and metagRoot:** proteinannotator downloads these itself from unversioned "latest"
  links, as in upstream's run 07. The files are at
  `https://pavlopoulos-lab.org/envofams/databases/hmmer/{nmpfamsdb,metagroot}.hmm.gz`. To pin
  them, add rows to `references.tsv` and pass them as `nmpfams_db` / `metagroot_db`.
- **BUSCO lineages** (r05 mag): fetched by BUSCO at run time.

Connector tests: from a connector's folder, `nf-test test test/main.nf.test`. Every converter
test checks that the connector's output is **byte-identical to calling the upstream script
directly** on the same input. The fetchngs fixture is a fetchngs 1.12.0-shaped samplesheet built from the real ENA
metadata of the 12 runs (`test/make_testdata.py`). It reproduces the sample names and sheets
upstream documented for runs 02, 04, 05 and 08. `fetch_references` is tested with `file://`
fixtures, and `bin/fetch_reference.py --selftest` covers dropped transfers, Range resumes and
checksum failures against a local HTTP server.

## Live version

The connectors run from GitHub at a pinned commit. A connector added locally
(`path: connectors/<name>`, which `nf-meta validate` flags as not reproducible) is switched over
once it is pushed, by replacing its `path:` with:

```yaml
    url: https://github.com/bmds-tue/nf-meta-showcases
    version: <full 40-character commit hash>
    main_script: meta-omics/connectors/<name>/main.nf
```

With `-main-script`, Nextflow (checked on 26.10) uses the `nextflow.config`, `bin/` and
`projectDir` next to that script, not those at the repository root. nf-meta looks for
`nextflow_schema.json` next to the script too, so the connectors need no changes.

## Reproducing upstream: expected differences

- **Absolute paths** in samplesheets depend on the launch directory.
- **Pooled FASTA bytes:** gzip writes a timestamp into its header, so compare
  `LMO_MG_pooled.faa.gz` decompressed.
- **Thread counts:** MEGAHIT and mmseqs results can depend on them. Resource configs are site
  configs, not part of this metapipeline.
- **Reference numbers** to compare against, from `RUNS.md`:
  - r02: 198,252 proteins
  - r03: 405 families
  - r05: 160 bins and 2,513,059 proteins
  - c05: 1,073,177 IDs recurring across samples before prefixing
  - r06: 5,864 families
  - r08: 1,755 ASVs
  - r04: 172 phiX pairs out of 161,043,840

`test_step.yaml` is the earlier draft that points at the `brovolia/meta-omics-sig` fork; this
config supersedes it.
