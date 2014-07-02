#include "global.h"
#include "commands.h"
#include "util.h"
#include "file_util.h"
#include "db_graph.h"
#include "db_node.h"
#include "binary_kmer.h"
#include "seq_reader.h"
#include "graph_format.h"
#include "async_read_io.h"

#include <libgen.h>

const char reads_usage[] =
"usage: "CMD" reads [options] <in.ctx>[:cols] [in2.ctx ...]\n"
"\n"
"  Filters reads based on which have a kmer in the graph. \n"
"\n"
"  -h, --help                  This help message\n"
"  -m, --memory <mem>          Memory to use\n"
"  -n, --nkmers <kmers>        Number of hash table entries (e.g. 1G ~ 1 billion)\n"
"  -t, --threads <T>           Number of threads to use [default: "QUOTE_VALUE(DEFAULT_NTHREADS)"]\n"
//
"  -f, --fasta                 Output as gzipped FASTA\n"
"  -q, --fastq                 Output as gzipped FASTQ [default]\n"
"  -v, --invert                Print reads/read pairs with no kmer in graph\n"
"  -1, --seq  <in>:<O>         Writes output to <O>.fq.gz\n"
"  -2, --seq2 <in1>:<in2>:<O>  Writes output to <O>.{1,2}.fq.gz\n"
"  -i, --seqi <in>:<O>         Writes output to <O>.{1,2}.fq.gz\n"
"\n"
"  Can specify --seq/--seq2/--seqi multiple times. If either read of a pair\n"
"  touches the graph, both are printed.\n"
"\n";

static struct option longopts[] =
{
// General options
  {"help",         no_argument,       NULL, 'h'},
  {"memory",       required_argument, NULL, 'm'},
  {"nkmers",       required_argument, NULL, 'n'},
// command specific
  {"fasta",        no_argument,       NULL, 'f'},
  {"fastq",        no_argument,       NULL, 'q'},
  {"invert",       no_argument,       NULL, 'v'},
  {"seq",          required_argument, NULL, '1'},
  {"seq2",         required_argument, NULL, '2'},
  {"seqi",         required_argument, NULL, 'i'},
  {NULL, 0, NULL, 0}
};

typedef struct
{
  // Set by command line parsing
  char *out_base;
  bool is_pe;
  char *out_path, *out_path1, *out_path2;
  gzFile gzout, gzout1, gzout2;

  pthread_mutex_t outlock;

  // Stats
  size_t num_of_reads_printed;

  // Global settings
  dBGraph *db_graph;
  volatile size_t *rcounter;
  LoadingStats *stats;
  bool invert, use_fq;

} AlignReadsData;

#include "objbuf_macro.h"
create_objbuf(aln_reads_buf,AlignReadsBuffer,AlignReadsData);
create_objbuf(asyncio_buf,AsyncIOInputBuffer,AsyncIOInput);

static AsyncIOInputBuffer files;
static AlignReadsBuffer inputs;
static size_t nthreads = 0;
static struct MemArgs memargs = MEM_ARGS_INIT;

static size_t num_gfiles = 0;
static char **gfile_paths = NULL;

static volatile size_t read_counter = 0;

static void input_clean_up(AlignReadsData *input, bool rm)
{
  // Clean up input
  if(input->gzout != NULL) { gzclose(input->gzout); }
  if(input->gzout1 != NULL) { gzclose(input->gzout1); }
  if(input->gzout2 != NULL) { gzclose(input->gzout2); }
  if(rm) {
    if(input->gzout != NULL && unlink(input->out_path) != 0)
      warn("Cannot delete file %s", input->out_path);
    if(input->gzout1 != NULL && unlink(input->out_path1) != 0)
      warn("Cannot delete file %s", input->out_path1);
    if(input->gzout2 != NULL && unlink(input->out_path2) != 0)
      warn("Cannot delete file %s", input->out_path2);
  }
  ctx_free(input->out_path);
  ctx_free(input->out_path1);
  ctx_free(input->out_path2);
  pthread_mutex_destroy(&input->outlock);
  memset(input, 0, sizeof(AlignReadsData));
}

static char* input_alloc_path(char *out_base, const char *suffix)
{
  size_t len1 = strlen(out_base), len2 = strlen(suffix);
  char *path = ctx_malloc((len1+len2+1) * sizeof(char));
  memcpy(path, out_base, len1);
  memcpy(path+len1, suffix, len2);
  path[len1+len2] = '\0';
  return path;
}

static gzFile input_output_open(const char *path)
{
  gzFile gzout;

  if(futil_file_exists(path)) {
    warn("Output file already exists: %s", path);
    return NULL;
  }

  // dirname, basename may modify string, so make copy
  char *pathcpy = strdup(path);
  char *fname = basename(pathcpy);

  if(path[0] == '\0' || path[strlen(path)-1] == '\0' ||
     fname[0] == '/' || fname[0] == '.')
  {
    warn("Bad output name: %s", path);
    free(pathcpy);
    return NULL;
  }

  strcpy(pathcpy, path);
  char *dir = dirname(pathcpy);
  futil_mkpath(dir, 0777);
  free(pathcpy);

  if((gzout = gzopen(path, "w")) == NULL) {
    warn("Cannot open %s", path);
    return NULL;
  }

  // Set buffer size
  #if ZLIB_VERNUM >= 0x1240
    gzbuffer(gzout, DEFAULT_IO_BUFSIZE);
  #endif

  return gzout;
}

static bool input_paths_init(AlignReadsData *input)
{
  input->out_path = input->out_path1 = input->out_path2 = NULL;

  input->out_path = input_alloc_path(input->out_base, input->use_fq ? ".fq.gz" : ".fa.gz");
  if((input->gzout = input_output_open(input->out_path)) == NULL) return false;

  if(input->is_pe) {
    input->out_path1 = input_alloc_path(input->out_base, input->use_fq ? ".1.fq.gz" : ".1.fa.gz");
    input->out_path2 = input_alloc_path(input->out_base, input->use_fq ? ".2.fq.gz" : ".2.fa.gz");
    if((input->gzout1 = input_output_open(input->out_path1)) == NULL) return false;
    if((input->gzout2 = input_output_open(input->out_path2)) == NULL) return false;
  }

  if(pthread_mutex_init(&input->outlock, NULL) != 0) die("Mutex init failed");

  return true;
}

static void parse_args(int argc, char **argv)
{
  bool invert = false, fasta_output = false, fastq_output = false;
  size_t i;

  aln_reads_buf_alloc(&inputs, 8);
  asyncio_buf_alloc(&files, 8);

  AlignReadsData input;
  AsyncIOInput seqfiles;

  // Arg parsing
  char cmd[100], shortopts[100];
  cmd_long_opts_to_short(longopts, shortopts, sizeof(shortopts));
  int c;

  while((c = getopt_long_only(argc, argv, shortopts, longopts, NULL)) != -1) {
    cmd_get_longopt_str(longopts, c, cmd, sizeof(cmd));
    switch(c) {
      case 0: /* flag set */ break;
      case 'h': cmd_print_usage(NULL); break;
      case 't': cmd_check(nthreads,cmd); nthreads = cmd_uint32_nonzero(cmd, optarg); break;
      case 'm': cmd_mem_args_set_memory(&memargs, optarg); break;
      case 'n': cmd_mem_args_set_nkmers(&memargs, optarg); break;
      case 'f': cmd_check(fasta_output,cmd); fasta_output = true; break;
      case 'q': cmd_check(fastq_output,cmd); fastq_output = true; break;
      case 'v': cmd_check(invert,cmd); invert = true; break;
      case '1':
      case '2':
      case 'i':
        memset(&input, 0, sizeof(input));
        memset(&seqfiles, 0, sizeof(seqfiles));
        asyncio_task_parse(&seqfiles, c, optarg, 0, &input.out_base);
        input.is_pe = (c == '2' || c == 'i');
        aln_reads_buf_add(&inputs, input);
        asyncio_buf_add(&files, seqfiles);
        break;
      case ':': /* BADARG */
      case '?': /* BADCH getopt_long has already printed error */
        // cmd_print_usage(NULL);
        die("`"CMD" reads -h` for help. Bad option: %s", argv[optind-1]);
      default: abort();
    }
  }

  // Defaults
  if(!nthreads) nthreads = DEFAULT_NTHREADS;
  if(!fasta_output && !fastq_output) fastq_output = true;

  if(inputs.len == 0)
    cmd_print_usage("Please specify at least one sequence file (-1, -2 or -i)");

  if(fasta_output && fastq_output)
    cmd_print_usage("Cannot use both --fasta and --fastq");

  if(optind >= argc)
    cmd_print_usage("Please specify input graph file(s)");

  num_gfiles = (size_t)(argc - optind);
  gfile_paths = argv + optind;

  for(i = 0; i < inputs.len; i++) {
    inputs.data[i].invert = invert;
    inputs.data[i].use_fq = fastq_output;
    files.data[i].ptr = &inputs.data[i];
  }
}

static void inputs_attempt_open()
{
  bool err_occurred = false;
  size_t i;

  for(i = 0; i < inputs.len && !err_occurred; i++)
    err_occurred = !input_paths_init(&inputs.data[i]);

  if(err_occurred) {
    for(i = 0; i < inputs.len; i++)
      input_clean_up(&inputs.data[i], true);
    die("Error creating output files");
  }
}

static bool read_touches_graph(const read_t *r, const dBGraph *db_graph,
                               LoadingStats *stats)
{
  bool found = false;
  BinaryKmer bkmer; Nucleotide nuc; dBNode node;
  const size_t kmer_size = db_graph->kmer_size;
  size_t i, num_contigs = 0, num_kmers_loaded = 0;
  size_t search_pos = 0, start, end = 0, contig_len;

  if(r->seq.end >= kmer_size)
  {
    while((start = seq_contig_start(r, search_pos, kmer_size, 0,0)) < r->seq.end &&
          !found)
    {
      end = seq_contig_end(r, start, kmer_size, 0, 0, &search_pos);
      contig_len = end - start;
      __sync_fetch_and_add((volatile size_t*)&stats->total_bases_loaded, contig_len);

      num_contigs++;

      bkmer = binary_kmer_from_str(r->seq.b + start, kmer_size);
      num_kmers_loaded++;
      node = db_graph_find(db_graph, bkmer);
      if(node.key != HASH_NOT_FOUND) { found = true; break; }

      for(i = start+kmer_size; i < end; i++)
      {
        nuc = dna_char_to_nuc(r->seq.b[i]);
        bkmer = binary_kmer_left_shift_add(bkmer, kmer_size, nuc);
        num_kmers_loaded++;
        node = db_graph_find(db_graph, bkmer);
        if(node.key != HASH_NOT_FOUND) { found = true; break; }
      }
    }
  }

  // Update stats
  __sync_fetch_and_add((volatile size_t*)&stats->total_bases_read, r->seq.end);
  __sync_fetch_and_add((volatile size_t*)&stats->num_kmers_loaded, num_kmers_loaded);
  __sync_fetch_and_add((volatile size_t*)&stats->num_kmers_novel, num_kmers_loaded - found);
  __sync_fetch_and_add((volatile size_t*)&stats->num_good_reads, num_contigs > 0);
  __sync_fetch_and_add((volatile size_t*)&stats->num_bad_reads, num_contigs == 0);

  return found;
}

static inline void print_read(const read_t *r, bool use_fq, gzFile gzout)
{
  if(use_fq) seq_gzprint_fastq(r, gzout, 0);
  else       seq_gzprint_fasta(r, gzout, 0);
}

void filter_reads(AsyncIOData *data, void *arg)
{
  (void)arg;
  read_t *r1 = (read_t*)&data->r1, *r2 = data->r2.seq.end ? (read_t*)&data->r2 : NULL;
  AlignReadsData *input = (AlignReadsData*)data->ptr;
  const dBGraph *db_graph = input->db_graph;
  LoadingStats *stats = input->stats;

  ctx_assert2(r2 == NULL || input->is_pe, "%p %i", r2, (int)input->is_pe);

  bool touches_graph = read_touches_graph(r1, db_graph, stats) ||
                       (r2 != NULL && read_touches_graph(r2, db_graph, stats));

  if(touches_graph != input->invert)
  {
    pthread_mutex_lock(&input->outlock);

    if(r2 == NULL) {
      print_read(r1, input->use_fq, input->gzout);
    } else {
      print_read(r1, input->use_fq, input->gzout1);
      print_read(r2, input->use_fq, input->gzout2);
    }

    pthread_mutex_unlock(&input->outlock);

    input->num_of_reads_printed += 1 + (r2 != NULL);
  }

  if(r2 == NULL) __sync_add_and_fetch((volatile size_t*)&stats->num_se_reads, 1);
  else           __sync_add_and_fetch((volatile size_t*)&stats->num_pe_reads, 2);

  size_t n = __sync_add_and_fetch(&read_counter, 1);
  ctx_update("FilterReads", n);
}

int ctx_reads(int argc, char **argv)
{
  parse_args(argc, argv);

  //
  // Open input graphs
  //
  GraphFileReader *gfiles = ctx_calloc(num_gfiles, sizeof(GraphFileReader));
  size_t i, ctx_max_kmers = 0, ctx_sum_kmers = 0;

  graph_files_open(gfile_paths, gfiles, num_gfiles,
                   &ctx_max_kmers, &ctx_sum_kmers);

  // Will exit and remove output files on error
  inputs_attempt_open();

  //
  // Calculate memory use
  //
  size_t kmers_in_hash, graph_mem, bits_per_kmer = sizeof(BinaryKmer)*8;

  kmers_in_hash = cmd_get_kmers_in_hash(memargs.mem_to_use,
                                        memargs.mem_to_use_set,
                                        memargs.num_kmers,
                                        memargs.num_kmers_set,
                                        bits_per_kmer,
                                        ctx_max_kmers, ctx_sum_kmers,
                                        true, &graph_mem);

  cmd_check_mem_limit(memargs.mem_to_use, graph_mem);

  //
  // Set up graph
  //
  dBGraph db_graph;
  db_graph_alloc(&db_graph, gfiles[0].hdr.kmer_size, 1, 0, kmers_in_hash);

  // Load graphs
  LoadingStats gstats = LOAD_STATS_INIT_MACRO;

  GraphLoadingPrefs gprefs = {.db_graph = &db_graph,
                              .must_exist_in_graph = false,
                              .empty_colours = true,
                              .boolean_covgs = false};

  for(i = 0; i < num_gfiles; i++) {
    gfiles[i].fltr.flatten = true;
    file_filter_update_intocol(&gfiles[i].fltr, 0);
    graph_load(&gfiles[i], gprefs, &gstats);
    graph_file_close(&gfiles[i]);
    gprefs.empty_colours = false;
  }
  ctx_free(gfiles);

  status("Printing reads that do %stouch the graph\n",
         inputs.data[0].invert ? "not " : "");

  //
  // Filter reads using async io
  //
  LoadingStats seq_stats = LOAD_STATS_INIT_MACRO;

  for(i = 0; i < inputs.len; i++) {
    inputs.data[i].stats = &seq_stats;
    inputs.data[i].db_graph = &db_graph;
  }

  // Deal with a set of files at once
  size_t start, end;
  for(start = 0; start < inputs.len; start += MAX_IO_THREADS)
  {
    // Can have different numbers of inputs vs threads
    end = MIN2(inputs.len, start+MAX_IO_THREADS);
    asyncio_run_pool(files.data+start, end-start, filter_reads, NULL, nthreads, 0);
  }

  size_t total_reads_printed = 0;
  size_t total_reads = seq_stats.num_se_reads + seq_stats.num_pe_reads;

  for(i = 0; i < inputs.len; i++)
    total_reads_printed += inputs.data[i].num_of_reads_printed;

  for(i = 0; i < inputs.len; i++) {
    input_clean_up(&inputs.data[i], false);
    asyncio_task_close(&files.data[i]);
  }

  aln_reads_buf_dealloc(&inputs);
  asyncio_buf_dealloc(&files);

  status("Total printed %zu / %zu (%.2f%%) reads\n",
         total_reads_printed, total_reads,
         (100.0 * total_reads_printed) / total_reads);

  db_graph_dealloc(&db_graph);

  return EXIT_SUCCESS;
}
