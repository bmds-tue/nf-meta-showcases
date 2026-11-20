#!/bin/bash
# Head job for the meta-omics metapipeline on the M3C cluster (nf-core/configs profile m3c).
#
# Runs nf-meta, which starts one `nextflow run` at a time; every Nextflow task is submitted
# to SLURM by that Nextflow process, so this job itself stays small. It needs the long
# partition because the whole chain runs for days.
#
# Submit from meta-omics/ after editing the paths below:
#   sbatch run_m3c.sh
# Resubmitting the same script resumes: finished steps are skipped and the interrupted
# step reuses its cached tasks.

#SBATCH --job-name=lmo-nfmeta
#SBATCH --partition=cpu3-long
#SBATCH --time=7-00:00:00
#SBATCH --cpus-per-task=2
#SBATCH --mem=20G
#SBATCH --output=lmo-nfmeta-%j.log

set -euo pipefail

# --- Edit these --------------------------------------------------------------------------
REPO=/path/to/nf-meta-showcases                   # clone of this repository
RUN_DIR=/path/to/lmo-run                          # nf-meta -o: results, work dir, resume state
# The reference inputs (phix_fasta, taxprofiler_databases, ...), one `name: path` per line;
# see inputs.example.yaml. connectors/fetch_references produces all of them (README.md).
INPUTS=/path/to/lmo-inputs.yaml
export NXF_SINGULARITY_CACHEDIR=/path/to/singularity-cache
# source /path/to/miniconda3/bin/activate nf-meta # if nf-meta/nextflow live in a conda env
# ------------------------------------------------------------------------------------------

# Read by the Nextflow launcher before any config, so they can't go in a config file.
export NXF_SYNTAX_PARSER=v1          # fetchngs 1.12.0 and detaxizer 1.3.0 don't parse otherwise
export NXF_OPTS="-Xms2g -Xmx16g"     # r06_proteinfamilies_mg head JVM (proteinfamilies#191)

# Without a terminal, Python buffers stdout in large blocks and the log above would stay
# empty for hours. Unbuffered, `tail -f lmo-nfmeta-<jobid>.log` follows the run live.
export PYTHONUNBUFFERED=1

[[ -f "$REPO/meta-omics/metaomics.yaml" ]] || { echo "missing: $REPO/meta-omics/metaomics.yaml" >&2; exit 1; }
command -v nf-meta   >/dev/null || { echo "nf-meta not on PATH" >&2; exit 1; }
command -v nextflow  >/dev/null || { echo "nextflow not on PATH" >&2; exit 1; }
[[ -f "$INPUTS" ]] || { echo "missing inputs file: $INPUTS" >&2; exit 1; }
mkdir -p "$RUN_DIR" "$NXF_SINGULARITY_CACHEDIR"

echo "job $SLURM_JOB_ID on $(hostname), started $(date -Is)"
echo "repo $(git -C "$REPO" rev-parse HEAD), $(nf-meta --version), $(nextflow -version 2>&1 | grep -o 'version [0-9.]*')"

cd "$REPO/meta-omics"
# exec: nf-meta replaces this shell, so scancel / the time limit signal it directly and
# Nextflow gets the chance to cancel its own SLURM jobs.
exec nf-meta run metaomics.yaml \
    -p m3c \
    --inputs-file "$INPUTS" \
    --input-mode fail \
    -o "$RUN_DIR" \
    --resume
