nextflow.enable.dsl = 2

// detaxizer outdir -> sample,fastq_1,fastq_2 samplesheet of the filtered reads, for the
// pipelines detaxizer 1.3.0's --generate_pipeline_samplesheets cannot target
// (metatdenovo, ampliseq, viralmetagenome).
//
// The conversion is bin/detaxizer_to_reads_samplesheet.py, a byte-for-byte copy of
// vagkaratzas/meta-omics-sig@8092df6 scripts/converters/. It reads filter/filtered/
// (seqkit and bbmap naming), never filter/removed/, and refuses orphaned mates. It only
// points at files detaxizer already published, so no rewriting is needed.

include { validateParameters; paramsHelp } from 'plugin/nf-schema'

params.detaxizer_outdir = null

process DETAXIZER_TO_SAMPLESHEET {
    publishDir params.outdir, mode: 'copy'

    input:
    path detaxizer_outdir, stageAs: 'input_detaxizer_outdir'

    output:
    path 'samplesheet.csv', emit: samplesheet

    script:
    """
    detaxizer_to_reads_samplesheet.py input_detaxizer_outdir samplesheet.csv
    """

    stub:
    """
    touch samplesheet.csv
    """
}

workflow {
    if (params.help) {
        log.info paramsHelp(command: "nextflow run main.nf --detaxizer_outdir <dir> --outdir <dir>")
        exit 0
    }
    validateParameters()

    DETAXIZER_TO_SAMPLESHEET(file(params.detaxizer_outdir, type: 'dir', checkIfExists: true))
}
