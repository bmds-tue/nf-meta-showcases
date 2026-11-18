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
| `configs/` | Per-step Nextflow configs for upstream's workarounds (`nf_config:` in the metapipeline) |

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
nf-meta run metaomics.yaml --dry-run -p singularity
nf-meta run metaomics.yaml -p singularity   # prompts for the databases listed under inputs:
```

Inputs without a default are the reference files upstream downloaded by hand: the phiX FASTA,
the taxprofiler database sheet and sylph taxonomy, and the Pfam/FunFam/InterProScan databases.
Their descriptions in `metaomics.yaml` say where each one comes from.

Connector tests: from a connector's folder, `nf-test test test/main.nf.test`. Every test checks
that the connector's output is **byte-identical to calling the upstream script directly** on the
same input. The fetchngs fixture is a fetchngs 1.12.0-shaped samplesheet built from the real ENA
metadata of the 12 runs (`test/make_testdata.py`). It reproduces the sample names and sheets
upstream documented for runs 02, 04, 05 and 08.

## Live version

Today the connectors are local pipelines (`path: connectors/<name>`), which `nf-meta validate`
flags as not reproducible. Once this repository is pushed, replace each connector's `path:` with:

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
