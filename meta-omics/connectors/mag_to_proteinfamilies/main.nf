nextflow.enable.dsl = 2

// mag outdir -> pooled, sample-prefixed protein FASTA + one-row nf-core/proteinfamilies
// samplesheet (sample,fasta).
//
// The conversion is bin/mag_to_proteinfamilies.py, a byte-for-byte copy of
// vagkaratzas/meta-omics-sig@8092df6 scripts/converters/. See its docstring for why the
// per-sample Prodigal FASTAs are not simply concatenated (MEGAHIT/Prodigal IDs recur
// across samples; every header gets a `<sample>-` prefix).
//
// Unlike the other connectors this one creates a new file, and the script records that
// file's resolved path -- which, inside a Nextflow task, is the task's work directory.
// The one addition here is rewriting that path to where publishDir puts the FASTA, so
// the samplesheet stays valid after the work directory is cleaned.

include { validateParameters; paramsHelp } from 'plugin/nf-schema'

params.mag_outdir = null
params.sample     = 'LMO_MG_pooled'
params.assembler  = 'MEGAHIT'
params.expect     = null

process MAG_TO_PROTEINFAMILIES {
    tag "${sample}"
    publishDir params.outdir, mode: 'copy'

    input:
    path mag_outdir, stageAs: 'input_mag_outdir'
    val sample
    val assembler
    val expect
    val published_fasta   // absolute path the pooled FASTA is published to

    output:
    path 'samplesheet.csv',  emit: samplesheet
    path "${sample}.faa.gz", emit: pooled_fasta

    script:
    def expect_arg = expect != null ? "--expect ${expect}" : ''
    """
    mag_to_proteinfamilies.py \\
        input_mag_outdir samplesheet.csv '${sample}.faa.gz' \\
        --sample '${sample}' --assembler '${assembler}' ${expect_arg}

    # Point the fasta column at the published copy instead of this work directory.
    # The script's csv writer ends lines with \\r\\n; keep that on the rewritten row.
    awk -F, -v OFS=, -v fasta='${published_fasta}' \\
        'NR == 1 { print; next } { cr = sub(/\\r\$/, ""); \$2 = fasta; print \$0 (cr ? "\\r" : "") }' \\
        samplesheet.csv > samplesheet.published.csv
    mv samplesheet.published.csv samplesheet.csv
    """

    stub:
    """
    touch samplesheet.csv '${sample}.faa.gz'
    """
}

workflow {
    if (params.help) {
        log.info paramsHelp(command: "nextflow run main.nf --mag_outdir <dir> --expect 3 --outdir <dir>")
        exit 0
    }
    validateParameters()

    def published_fasta = file(params.outdir).toAbsolutePath().normalize().resolve("${params.sample}.faa.gz").toString()

    MAG_TO_PROTEINFAMILIES(
        file(params.mag_outdir, type: 'dir', checkIfExists: true),
        params.sample,
        params.assembler,
        params.expect,
        published_fasta,
    )
}
