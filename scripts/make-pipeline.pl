#!/usr/bin/env perl

use strict;
use warnings;

# Use current directory to find modules
use FindBin;
use lib $FindBin::Bin;

use POSIX qw/strftime/;
use CortexScripts;

sub print_usage
{
  for my $err (@_) { print STDERR "Error: $err\n"; }
  print STDERR "" .
"Usage: ./make-pipeline.pl [options] <list-of-kmers> <proj> <sample-file>
  Generate a Makefile to run common McCortex pipelines

  Options:
    -r,--ref <ref.fa>  Reference sequence

  Example:
    ./make-pipeline.pl 31:39:2 proj samples.txt > job.mk
    make -f job.mk bubblevcf

  To list all the commands without running:
    make -f job.mk --always-make --dry-run bubblevcf

  <kmers> specifies which kmers are to be used. It must be a comma separated
  list e.g. '21,33', or of the form <firstK[:lastK[:stepK]]>. Examples:
    '27' => 27;  '27:31' => 27,29,31; '27:39:4' => 27,31,35,49

  samples.txt should space or tab separated with 2-4 columns of the format:
    # comment
    <sample-name> <se_file,...> <pefile1:pefile2,...> <interleaved_file,...>
    ...
";
  exit(-1);
}

my $args = "$0 @ARGV";

my $default_mem = "1G";
my $default_ctxdir = "~/mccortex/";
my $default_nthreads = 2;
# Sample 5000 kmers to pick link threshold limit
my $default_link_clean_nkmers = 5000;

my $ref_path; # path to reference FASTA if available

# Parse command line args
while(@ARGV > 3) {
  my $arg = shift;
  if($arg =~ /^(-r|--ref)$/) { $ref_path = shift; }
  else { print_usage("Unknown argument: $arg"); }
}

if(@ARGV != 3) { print_usage(); }

my @kmers = parse_kmer_list($ARGV[0]);
my $proj = $ARGV[1];
my $sample_path = $ARGV[2];

print STDERR "kmers: @kmers\n";
print STDERR "proj: $proj\n";
print STDERR "sample_file: $sample_path\n";

# Set up paths to executables, defaults etc.
my $link_thresh_script = "\$(CTXDIR)/scripts/R/make_link_cutoffs.R";


# Load sample file
# ## Comment lines
# <sample>  <se_file,...>  <pe_file1:file2,...>  <interleaved_files,...>
my @samples = (); # ({'name','se_files','pe_files','i_files'}, ...)
my %sample_names = ();
my $sfh = open_file($sample_path);
while(defined(my $line = <$sfh>)) {
  if($line !~ /^\s*$/ && $line !~ /^#/) {
    my @cols = split(/\s/, $line);
    if(@cols < 2 || @cols > 4) { die("Bad line"); }
    my ($sname, $se_txt, $pe_txt, $i_txt) = @cols;
    # Check sample name is sane and unique
    if($sname !~ /^[a-z0-9_\-\.]+$/i) { print STDERR "Bad name: $sname"; exit(-1); }
    if(defined($sample_names{$sname})) { die("Duplicate sample name"); }
    # Parse file lists
    my @se_files = parse_file_list($se_txt);
    my @pe_files = parse_pe_file_list($pe_txt);
    my @i_files  = parse_file_list($i_txt);
    push(@samples, {'name'     => $sname,
                    'se_files' => \@se_files,
                    'pe_files' => \@pe_files,
                    'i_files'  => \@i_files});
  }
}
close($sfh);

my $union_bubble_vcf = "$proj/vcfs/bubbles.".join('.',map {"k$_"} @kmers).".vcf.gz";
my $union_brkpnt_vcf = "$proj/vcfs/breakpoints.".join('.',map {"k$_"} @kmers).".vcf.gz";

print '# '.strftime("%F %T", localtime($^T)).'
#
# Generated with:
#     make-pipeline.pl $args
#
# To use this file:
#     make -f <thisfile> graphs        <- build graphs
#     make -f <thisfile> links         <- build links
#     make -f <thisfile> bubbles       <- make bubble calls
#     make -f <thisfile> breakpoints   <- make breakpoint calls
#     make -f <thisfile> bubblevcf     <- make bubble vcf
#     make -f <thisfile> breakpointvcf <- make breakpoint vcf
#     make -f <thisfile> vcfs          <- make all vcfs including union
#
# Make will automatically generate dependencies.
# Add option --dry-run to print commands but not run them. Include option
# --always-make to list all commands even if dependencies exist.
#
# Other options:
#    CTXDIR=<path-to-ctx-dir>
#    MEM=<mem-to-use>
#    NTHREADS=<nthreads>


SHELL=/bin/bash -eou pipefail

# Override these values when running
CTXDIR='.$default_ctxdir.'
MEM='.$default_mem.'
NTHREADS='.$default_nthreads.'
LINK_THRESH=0.001
CLEANING_ARGS=
LINK_CLEAN_NKMERS='.$default_link_clean_nkmers.'
REF_FILE='.(defined($ref_path) ? $ref_path : '').'

# Paths to scripts
CTXLINKS=$(CTXDIR)/scripts/cortex_links.pl
MEDIAN_LINK_THRESH=$(CTXDIR)/scripts/median-link-threshold.sh
CTXFLANKS=$(CTXDIR)/scripts/cortex_print_flanks.sh
VCFSORT=$(CTXDIR)/scripts/bash/vcf-sort
VCFRENAME=$(CTXDIR)/scripts/bash/vcf-rename

# Third lib paths
BWA=$(CTXDIR)/libs/bwa/bwa
BGZIP=$(CTXDIR)/libs/htslib/bgzip
BCFTOOLS=$(CTXDIR)/libs/bcftools/bcftools

';

for my $k (@kmers) {
  print "# Files at k=$k\n";
  print "RAW_GRAPHS_K$k=".join(' ', map {"$proj/k$k/graphs/$_->{'name'}.raw.ctx"} @samples)."\n";
  print "CLEAN_GRAPHS_K$k=\$(RAW_GRAPHS_K$k:.raw.ctx=.clean.ctx)\n";
  print "RAW_LINKS_K$k=". join(' ', map {"$proj/k$k/links/$_->{'name'}.raw.ctp.gz"}   @samples)."\n";
  print "CLEAN_LINKS_K$k=\$(RAW_LINKS_K$k:.raw.ctp.gz=.clean.ctp.gz)\n";
  print "BUBBLES_K$k=$proj/k$k/bubbles/bubbles.txt.gz\n";
  if(defined($ref_path)) {
    print "BREAKPOINTS_K$k=$proj/k$k/breakpoints/breakpoints.txt.gz\n";
  } else {
    print "BREAKPOINTS_K$k=\n";
  }
  print "\n";
}
print "RAW_GRAPHS=" .join(' ', map {"\$(RAW_GRAPHS_K$_)"}  @kmers)."\n";
print "CLEAN_GRAPHS=\$(RAW_GRAPHS:.raw.ctx=.clean.ctx)\n";
print "RAW_LINKS="  .join(' ', map {"\$(RAW_LINKS_K$_)"}   @kmers)."\n";
print "CLEAN_LINKS=\$(RAW_LINKS:.raw.ctp.gz=.clean.ctp.gz)\n";
print "BUBBLES="    .join(' ', map {"\$(BUBBLES_K$_)"}     @kmers)."\n";
print "BREAKPOINTS=".join(' ', map {"\$(BREAKPOINTS_K$_)"} @kmers)."\n";

my @dirlist = ();
for my $k (@kmers) {
  my $dirs = join(' ', "$proj/k$k/graphs/", "$proj/k$k/links/",
                       "$proj/k$k/bubbles/", "$proj/k$k/breakpoints/",
                       "$proj/k$k/ref/");
  push(@dirlist, $dirs);
}
push(@dirlist, "$proj/vcfs/");

print 'DIRS='.join(" \\\n     ", @dirlist).'

COVG_CSV_FILES=$(RAW_GRAPHS:.raw.ctx=.raw.covg.csv)

LINK_TMP_FILES=$(RAW_LINKS:.raw.ctp.gz=.effcovg.csv) \
               $(RAW_LINKS:.raw.ctp.gz=.tree.csv) \
               $(RAW_LINKS:.raw.ctp.gz=.thresh.txt)

BUBBLE_VCFS=$(BUBBLES:.txt.gz=.norm.vcf.gz)
BREAKPOINT_VCFS=$(BREAKPOINTS:.txt.gz=.norm.vcf.gz)
CALL_FILES=$(BUBBLES) $(BREAKPOINTS)
VCF_TMP_FILES=$(BUBBLES:.txt.gz=.flanks.fa.gz) $(BUBBLES:.txt.gz=.flanks.sam) \
              $(CALL_FILES:.txt.gz=.raw.vcf) $(CALL_FILES:.txt.gz=.sort.vcf) \
              $(CALL_FILES:.txt.gz=.norm.vcf)

# Referece Graphs
';

if(defined($ref_path)) {
  for my $k (@kmers) { print "REF_K$k=$proj/k$k/ref/ref.ctx\n"; }
} else {
  for my $k (@kmers) { print "REF_K$k=\n"; }
}

print 'REF_GRAPHS='.join(' ', map {'$(REF_K'.$_.')'} @kmers).'

HAVE_LOGS=$(RAW_GRAPHS) $(CLEAN_GRAPHS) $(RAW_LINKS) $(CLEAN_LINKS) $(LINK_TMP_FILES) $(CALL_FILES)
LOG_FILES=$(HAVE_LOGS:=.log)

.SECONDARY: $(RAW_GRAPHS) $(COVG_CSV_FILES) $(RAW_LINKS) $(LINK_TMP_FILES) $(VCF_TMP_FILES)
.DELETE_ON_ERROR:

all: checks graphs links bubbles breakpoints bubblevcf breakpointvcf

graphs: $(CLEAN_GRAPHS)

links: $(CLEAN_LINKS)

bubbles: $(BUBBLES)

checks:'."\n";
my @ctx_maxks = get_maxk_values(@kmers);
for my $maxk (@ctx_maxks) {
  print "\t@[ -x \$(CTXDIR)/bin/ctx$maxk ] || ( echo 'Error: Please compile cortex with `make MAXK=$maxk` or pass CTXDIR= [cortex: \$(CTXDIR)]' 1>&2 && false )\n";
}
print "\n";

# Can only create VCFs if we have a reference
if(defined($ref_path)) {
  print "breakpoints: \$(BREAKPOINTS)\n\n";
  print "bubblevcf: $union_bubble_vcf\n\n";
  print "breakpointvcf: $union_brkpnt_vcf\n\n";
} else {
  for my $tgt (qw(breakpoints bubblevcf breakpointvcf)) {
    print "$tgt:\n\t\@echo 'Need to give make-pipeline.pl --ref <r.fa> to run $tgt 2>1 && false\n\n";
  }
}

print "\$(DIRS):
\tmkdir -p \$@

clean:
\trm -rf \$(RAW_GRAPHS) \$(CLEAN_GRAPHS) \$(COVG_CSV_FILES)
\trm -rf \$(RAW_LINKS) \$(CLEAN_LINKS) \$(LINK_TMP_FILES)
\trm -rf \$(BUBBLES) \$(BREAKPOINTS)
\trm -rf \$(CALL_VCFS) \$(VCF_TMP_FILES) \$(LOG_FILES)

.PHONY: all clean checks graphs links bubbles breakpoints bubblevcf breakpointvcf

";

# Create and clean graph files
print "#\n# Build graph files\n#\n";
for my $k (@kmers) {
  my $ctx = get_ctx($k);

  # Build reference
  if(defined($ref_path)) {
    print "# reference at k=$k\n";
    print "$proj/k$k/ref/ref.ctx: $ref_path\n";
    print "\t$ctx build -m \$(MEM) -t \$(NTHREADS) -k $k -s \$< \$@ >& \$@.log\n\n";
  }

  print "# building graphs at k=$k\n";
  for my $sample (@samples) {
    # Create raw graph file
    my $sname = $sample->{'name'};
    my @files = get_all_sample_files($sample);

    print "$proj/k$k/graphs/$sname.raw.ctx: ".join(' ', @files)." | \$(DIRS)\n";
    print "\t$ctx build -m \$(MEM) -t \$(NTHREADS) -k $k --sample $sname";
    for my $file  (@{$sample->{'se_files'}}) { print " --seq $file";   }
    for my $files (@{$sample->{'pe_files'}}) { print " --seq2 $files"; }
    for my $ifile (@{$sample->{'i_files'}})  { print " --seqi $ifile"; }
    print ' $@ >& $@.log'."\n\n";
  }

  # Clean graph files at k=$k
  print "# graph cleaning at k=$k\n";
  print "$proj/k$k/graphs/%.raw.covg.csv $proj/k$k/graphs/%.clean.ctx: $proj/k$k/graphs/%.raw.ctx\n";
  print "\t$ctx clean -m \$(MEM) -t \$(NTHREADS) --covg-before $proj/k$k/graphs/\$*.raw.covg.csv -o $proj/k$k/graphs/\$*.clean.ctx \$(CLEANING_ARGS) \$< >& $proj/k$k/graphs/\$*.clean.ctx.log\n\n";
}

# Create and clean link files
print "#\n# Generate link files\n#\n";
for my $k (@kmers) {
  print "# creating links at k=$k\n";
  my $ctx = get_ctx($k);

  for my $sample (@samples) {
    my $sname = $sample->{'name'};
    my @files = get_all_sample_files($sample);

    my $ctx_clean_file = "$proj/k$k/graphs/$sname.clean.ctx";
    my $ctp_raw_file   = "$proj/k$k/links/$sname.raw.ctp.gz";

    print "$ctp_raw_file: $ctx_clean_file ".join(' ', @files)." | \$(DIRS)\n";
    print "\t$ctx thread -m \$(MEM) -t \$(NTHREADS)";
    for my $f (@{$sample->{'se_files'}}) { print " --seq $f";   }
    for my $f (@{$sample->{'pe_files'}}) { print " --seq2 $f->[0]:$f->[1]"; }
    for my $f (@{$sample->{'i_files'}})  { print " --seqi $f"; }
    print ' -o $@ $< >& $@.log'."\n\n";
  }

  # Clean link files at k=$k
  my $ctp_raw_file     = "$proj/k$k/links/%.raw.ctp.gz";
  my $ctp_clean_file   = "$proj/k$k/links/%.clean.ctp.gz";
  my $ctp_effcovg_file = "$proj/k$k/links/%.effcovg.csv";
  my $ctp_tree_file    = "$proj/k$k/links/%.tree.csv";
  my $ctp_thresh_file  = "$proj/k$k/links/%.thresh.txt";

  # Generate coverage CSV from first N kmers with links
  print "# link cleaning at k=$k\n";
  print "$ctp_effcovg_file $ctp_tree_file: $ctp_raw_file\n";
  print "\t\$(CTXLINKS) list --limit \$(LINK_CLEAN_NKMERS) <(gzip -fcd \$<) $proj/k$k/links/\$*.effcovg.csv $proj/k$k/links/\$*.tree.csv >& $proj/k$k/links/\$*.tree.csv.log\n\n";

  # Removed R dependency to fit a model and pick threshold
  # Can use any version of cortex for this
  print "$ctp_thresh_file: $ctp_tree_file\n";
  print "\t".'$(MEDIAN_LINK_THRESH) $(LINK_THRESH) '.$k.' $< > $@'."\n\n";

  # Clean links
  # $(word 1,$^) is the 1st dependency, $(word 2,$^) is the 2nd ...
  print "$ctp_clean_file: $ctp_raw_file $ctp_thresh_file\n";
  print "\t".'($(CTXLINKS) clean <(gzip -fcd $(word 1,$^)) `tail -1 $(word 2,$^)` | gzip -c) > $@ 2> $@.log'."\n\n";
}

# Generate buble calls
print "#\n# Make bubble calls\n#\n";
for my $k (@kmers) {
  my $ctx = get_ctx($k);
  my $ctp_txt = get_p_args($k);
  print "# bubble calls k=$k\n";
  print "$proj/k$k/bubbles/bubbles.txt.gz: \$(CLEAN_GRAPHS_K$k) \$(REF_K$k) \$(CLEAN_LINKS_K$k) | \$(DIRS)\n";
  print "\t$ctx bubbles -m \$(MEM) -t \$(NTHREADS) -o \$@ $ctp_txt \$(CLEAN_GRAPHS_K$k) \$(REF_K$k) >& \$@.log\n\n";
}

# Some things require a reference to be used
if(defined($ref_path))
{
  # Generate breakpoint calls
  print "#\n# Make breakpoint calls\n#\n";
  for my $k (@kmers) {
    my $ctx = get_ctx($k);
    my $ctp_txt = get_p_args($k);
    my $brkpnt_file = "$proj/k$k/breakpoints/breakpoints.txt.gz";

    print "# breakpoint calls k=$k\n";
    print "$brkpnt_file: \$(CLEAN_GRAPHS_K$k) \$(REF_K$k) \$(CLEAN_LINKS_K$k) | \$(DIRS)\n";
    print "\t$ctx breakpoints -m \$(MEM) -t \$(NTHREADS) -s \$(REF_FILE) -o \$@ $ctp_txt \$(CLEAN_GRAPHS_K$k) \$(REF_K$k) >& \$@.log\n\n";
  }

  # Generate buble VCFs
  print "#\n# Make bubble raw VCFs\n#\n";
  for my $k (@kmers) {
    my $ctx = get_ctx($k);
    my $bubbles_file = "$proj/k$k/bubbles/bubbles.txt.gz";

    my $bubble_flanks_fa_file  = "$proj/k$k/bubbles/bubbles.flanks.fa.gz";
    my $bubble_flanks_sam_file = "$proj/k$k/bubbles/bubbles.flanks.sam";
    my $raw_bubble_vcf         = "$proj/k$k/bubbles/bubbles.raw.vcf";

    print "# bubbles raw VCF k=$k\n";
    print "$bubble_flanks_fa_file: $bubbles_file\n";
    print "\t\$(CTXFLANKS) \$< > \$@\n\n";

    print "$bubble_flanks_sam_file: $bubble_flanks_fa_file \$(REF_FILE)\n";
    print "\t\$(BWA) index \$(REF_FILE)\n";
    print "\t\$(BWA) mem \$(REF_FILE) \$< > \$@\n\n";

    print "$raw_bubble_vcf: $bubbles_file $bubble_flanks_sam_file \$(REF_FILE)\n";
    print "\t$ctx calls2vcf -F $bubble_flanks_sam_file -o \$@ \$< \$(REF_FILE) >& \$@.log\n\n";
  }

  # Generate breakpoint VCFs
  print "#\n# Make breakpoint raw VCFs\n#\n";
  for my $k (@kmers) {
    my $ctx = get_ctx($k);
    my $breakpoint_file    = "$proj/k$k/breakpoints/breakpoints.txt.gz";
    my $breakpoint_raw_vcf = "$proj/k$k/breakpoints/breakpoints.raw.vcf";

    print "# breakpoints raw VCF k=$k\n";
    print "$breakpoint_raw_vcf: $breakpoint_file \$(REF_FILE)\n";
    print "\t$ctx calls2vcf -o \$@ \$< \$(REF_FILE) >& \$@.log\n\n";
  }

  # Post-processing rules for VCFs
  print "#\n# Post-processing for raw VCFs\n#\n";
  print "$proj/%.sort.vcf: $proj/%.raw.vcf\n";
  print "\t\$(VCFSORT) \$< > \$@\n\n";

  print "$proj/%.norm.vcf: $proj/%.sort.vcf \$(REF_FILE)\n";
  print "\t\$(BCFTOOLS) norm --remove-duplicates --fasta-ref \$(REF_FILE) --multiallelics +both \$< | \\\n";
  print "\t\$(VCFRENAME) > \$@\n\n";

  print "$proj/%.norm.vcf.gz: $proj/%.norm.vcf\n";
  print "\t\$(BGZIP) -f \$<\n";
  print "\t\$(BCFTOOLS) index \$@\n\n";

  # Generate union VCF
  print "#\n# Create union compressed VCF\n#\n";
  print "$proj/vcfs/bubbles.".join('.',map {"k$_"} @kmers).".vcf.gz: \$(BUBBLE_VCFS)\n";
  print "\t\$(BCFTOOLS) concat --output-type z --output \$@ \$(BUBBLE_VCFS)\n\n";
  print "$proj/vcfs/breakpoints.".join('.',map {"k$_"} @kmers).".vcf.gz: \$(BREAKPOINT_VCFS)\n";
  print "\t\$(BCFTOOLS) concat --output-type z --output \$@ \$(BREAKPOINT_VCFS)\n\n";
}


# Done!
exit(0);


sub print_vcf_post_processing
{
  my ($raw,$sort,$norm,$norm_gz) = @_;

  print "$sort: $raw\n";
  print "\t\$(VCFSORT) \$< > \$@\n\n";

  print "$norm: $sort \$(REF_FILE)\n";
  print "\t\$(BCFTOOLS) norm --remove-duplicates --fasta-ref \$(REF_FILE) --multiallelics +both \$< | \\\n";
  print "\t\$(VCFRENAME) > \$@\n\n";

  print "$norm_gz: $norm\n";
  print "\t\$(BGZIP) -f \$<\n";
  print "\t\$(BCFTOOLS) index \$@\n";
}

sub get_p_args
{
  my ($k) = @_;
  return join(' ', map {"-p $_:$proj/k$k/links/$samples[$_]->{'name'}.clean.ctp.gz"} 0..$#samples);
}

sub get_all_sample_files
{
  my ($sample) = @_;
  return (@{$sample->{'se_files'}}, @{$sample->{'pe_files'}}, @{$sample->{'i_files'}});
}

sub get_required_binaries
{
  return map { get_ctx($_) } keys get_maxk_values(@_);
}

sub get_maxk_values
{
  my %maxks = ();
  for my $k (@_) { $maxks{(int(($k+31)/32) * 32 - 1)} = 1; }
  return keys %maxks;
}

sub get_ctx
{
  my ($k) = @_;
  return "\$(CTXDIR)/bin/ctx".(int(($k+31)/32) * 32 - 1);
}

# Split a comma separated, colon delimited list of PE files
# "A.1.fa:A.2.fa,B.1.fa:B.2.fa"
#  => (["A.1.fa","A.2.fa"],["B.1.fa","B.2.fa"])
sub parse_pe_file_list
{
  my ($txt) = @_;
  my @files = parse_file_list($txt);
  my @pe_files = ();
  for my $f (@files) {
    if($f =~ /^([^:]+):([^:]+)$/) { push(@pe_files, [$1, $2]); }
    else { die("Bad PE line: $txt"); }
  }
  return @pe_files;
}

# Split a list of files by commas. Check there are not empty entries
sub parse_file_list
{
  my ($txt) = @_;
  if(!defined($txt) || $txt eq "" || $txt eq ".") { return (); }
  my @files = split(',', $txt);
  for my $f (@files) { if($f eq "") { die("Empty file entry: $txt"); } }
  return @files;
}

# '31'      => (31)
# '31:41'   => (31,33,35,37,39,41)
# '31:41:4' => (31,35,39)
sub parse_kmer_list
{
  my ($txt) = @_;
  if($txt =~ /^(\d+(,\d+)*)$/) {
    my @ks = split(',',$txt);
    for my $k (@ks) { if($k % 2 == 0) { die("Kmers must not be odd: $txt"); }}
    return @ks;
  }
  elsif($txt =~ /^(\d+)(?::(\d+)(?::(\d+))?)?$/)
  {
    my ($start,$end,$step) = ($1,$1,2);
    if(defined($2)) { $end  = $2; }
    if(defined($3)) { $step = $3; }
    if($step  % 2 != 0) { die("Kmer step must be even: $txt"); }
    if($start % 2 == 0) { die("Kmer start must be odd: $txt"); }
    if($end   % 2 == 0) { die("Kmer end must be odd: $txt"); }
    my @ks = ();
    for(my $k=$start; $k <= $end; $k += $step) { push(@ks, $k); }
    return @ks;
  }
  else { die("Poorly formatted kmer list: $txt"); }
}
