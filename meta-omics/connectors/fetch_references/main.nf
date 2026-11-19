nextflow.enable.dsl = 2

// Downloads, verifies and unpacks the reference data of the meta-omics metapipeline into
// one directory, driven by assets/references.tsv (one row per reference, with the
// expected md5 and/or sha256).
//
// Outputs go to `storeDir params.outdir`: a reference whose <outdir>/<name>/ already
// exists is not downloaded again. Pointing outdir at a shared directory therefore makes
// it a reference cache across runs. Delete <outdir>/<name>/ to force a fresh download.
//
// Besides the references themselves it writes, next to them:
//   references.tsv               name, url, bytes, md5, sha256, which checksums were checked
//   taxprofiler_databases.csv    the --databases sheet for nf-core/taxprofiler, with
//                                absolute paths into outdir (assets/taxprofiler_databases.csv)

include { validateParameters; paramsHelp } from 'plugin/nf-schema'

params.manifest          = "${projectDir}/assets/references.tsv"
params.taxprofiler_sheet = "${projectDir}/assets/taxprofiler_databases.csv"
params.require_checksums = true
params.keep_archives     = false

def fetchArgs(row) {
    def args = ["--url '${row.url}'", "--filename '${row.filename}'", "--outdir '${row.name}'"]
    if (row.md5)    args << "--md5 '${row.md5}'"
    if (row.sha256) args << "--sha256 '${row.sha256}'"
    if (params.require_checksums) args << '--require-checksum'
    if (row.unpack) args << "--unpack '${row.unpack}'"
    if (params.keep_archives) args << '--keep-archive'
    return args.join(' ')
}

// Rows without a setup step; runs in the plain Python container (base.config).
process FETCH_REFERENCE {
    tag "${row.name}"
    storeDir params.outdir

    input:
    val row

    output:
    path "${row.name}", emit: reference

    script:
    """
    fetch_reference.py ${fetchArgs(row)}
    """

    stub:
    """
    mkdir -p '${row.name}' && touch '${row.name}/${row.filename}' && echo '{}' > '${row.name}/SOURCE.json'
    """
}

// setup = interproscan: InterProScan release tarball, pressed with its own setup.py in
// the same task, so the stored data/ folder is complete and never modified afterwards.
// The container is the one nf-core/proteinannotator 1.1.0's INTERPROSCAN module runs
// (see nextflow.config), i.e. the environment that later reads these files.
process FETCH_INTERPROSCAN {
    tag "${row.name}"
    storeDir params.outdir

    input:
    val row

    output:
    path "${row.name}", emit: reference

    script:
    """
    fetch_reference.py ${fetchArgs(row)}

    release=\$(dirname "\$(ls ${row.name}/*/setup.py)")
    ( cd "\$release" && python3 setup.py -f interproscan.properties )
    """

    stub:
    """
    mkdir -p '${row.name}/release/data' && echo '{}' > '${row.name}/SOURCE.json'
    """
}

def readManifest(path) {
    def rows = file(path, checkIfExists: true).splitCsv(header: true, sep: '\t')
    def required = ['name', 'url', 'filename', 'md5', 'sha256', 'unpack', 'setup']
    if (!rows) error "Manifest ${path} has no rows"
    def missing = required - rows[0].keySet()
    if (missing) error "Manifest ${path} lacks column(s): ${missing.join(', ')}"
    rows = rows.collect { r -> r.collectEntries { k, v -> [(k): (v?.trim() in [null, '', '-']) ? '' : v.trim()] } }
    rows.each { r ->
        if (!(r.name ==~ /^[A-Za-z0-9._-]+$/)) error "Manifest: invalid name '${r.name}' (letters, digits, . _ - only)"
        if (!r.url || !r.filename)             error "Manifest: '${r.name}' needs url and filename"
        if (!(r.unpack in ['', 'none', 'tar'])) error "Manifest: '${r.name}' unpack must be none or tar, got '${r.unpack}'"
        if (!(r.setup in ['', 'interproscan'])) error "Manifest: '${r.name}' setup must be empty or interproscan, got '${r.setup}'"
        if (r.setup == 'interproscan' && r.unpack != 'tar') error "Manifest: '${r.name}' setup interproscan needs unpack tar"
    }
    def dupes = rows*.name.countBy { it }.findAll { k, n -> n > 1 }.keySet()
    if (dupes) error "Manifest: duplicate name(s) ${dupes.join(', ')}"
    return rows
}

workflow {
    if (params.help) {
        log.info paramsHelp(command: "nextflow run main.nf --outdir <shared-references-dir>")
        exit 0
    }
    validateParameters()

    def rows    = readManifest(params.manifest)
    def refsDir = file(params.outdir).toAbsolutePath().normalize()

    def ch_rows = channel.fromList(rows).branch { r ->
        interproscan: r.setup == 'interproscan'
        plain: true
    }
    FETCH_REFERENCE(ch_rows.plain)
    FETCH_INTERPROSCAN(ch_rows.interproscan)

    def ch_stored = FETCH_REFERENCE.out.reference.mix(FETCH_INTERPROSCAN.out.reference)

    // Provenance table, one line per reference, from each reference's SOURCE.json.
    def header = ['name', 'url', 'bytes', 'md5', 'sha256', 'verified', 'downloaded'].join('\t')
    ch_stored
        .map { dir ->
            def json = dir.resolve('SOURCE.json')
            if (!json.exists()) {
                // put into outdir by hand: storeDir skips it, but nothing vouches for it
                log.warn "${dir.name}: no SOURCE.json -- not downloaded by this pipeline, unverified"
                return [dir.name, '', '', '', '', 'none (no SOURCE.json)', ''].join('\t')
            }
            def s = new groovy.json.JsonSlurper().parse(json.toFile())
            [dir.name, s.url, s.bytes, s.md5, s.sha256, (s.verified ?: ['none']).join(','), s.downloaded].join('\t')
        }
        .collect(sort: true)
        .map { lines -> ([header] + lines).join('\n') + '\n' }
        .collectFile(name: 'references.tsv', storeDir: refsDir)

    // taxprofiler's database sheet, once everything is in place.
    ch_stored
        .collect()
        .map { _all -> file(params.taxprofiler_sheet, checkIfExists: true).text.replace('{refs}', refsDir.toString()) }
        .collectFile(name: 'taxprofiler_databases.csv', storeDir: refsDir)
}
