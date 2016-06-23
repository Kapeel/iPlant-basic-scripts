#!/usr/bin/env perl

use Bio::SeqIO;
use Getopt::Long;
use Pod::Usage;

$ENV{PATH} = "/usr/local2/MUMmer3.23:/bin:/usr/bin:$ENV{PATH}";

my $verbose = 0;
my $help;
my $maxun = 10;
my $peral = 0.99;
my $smgap = 1000;
my $gff_file = 0;
my $region = 0;
my $cds = 0;

#pod2usage();

GetOptions(
	   'reference=s' => \$RefFile,
           'assembly=s' => \$AssFile,
           'header=s' => \$header,
           'gff=s' => \$gff_file,
           'region=s' => \$region,
           'cds=s' => \$cds,
           'max_unaligned=i' => \$maxun,
           'per_aligned=f' => \$peral,
           'sm_gap_size' => \$smgap,
           'verbose' => \$verbose,
           'help' => \$help) || pod2usage(2);
           
pod2usage("$0: Reference fasta must be specified.") if !$RefFile;
pod2usage("$0: Assembly fasta must be specified.") if !$AssFile;
pod2usage("$0: If region type is CDS, then the cds option must be specified..") if ($region eq "CDS" && !$cds);
pod2usage(2) if $help;

$outfile = join "", $header, ".report";
$Voutfile = join "", $header, ".details";
open (OFILE, ">$outfile");
open (VFILE, ">$Voutfile");
print OFILE "REPORT FOR $AssFile \n \n";
print OFILE "Settings Chosen: \n Reference=\t $RefFile \n Assembly=\t $AssFile \n Name=    \t $header \n \n";
print OFILE "Options: genome region=$region  cds=$cds  max_unaligned=$maxun  per_aligned=$peral  sm_gap_size=$smgap \n \n";

print OFILE "  ASSEMBLY STATS: \n";

my $total = 0;
my @length  = ();
my $min_size = 100;
my $percent = 50;
open(IN, $AssFile) or die("Couldn't open file -- $AssFile !!\n");
my $long = 0;
my $countr = 0;
while(<IN>){
	if(/^>/){
		if($long >= $min_size){
			$countr++;
			push(@length, $long);
			$total += $long;
		}
		$long = 0;
	} else {
		chomp;
		$long += length($_);
	}
}
if($long >= $min_size){
	push(@length, $long);
	$total += $long;
}
close IN;

@length = sort {$b <=> $a} @length;

my $sum = $total/100*$percent;
my $nSome;
foreach my $l (@length){
	$s += $l;
	if($s>=$sum){
		$nSome = $l;
		last;
	}
}

print OFILE "  #seq = \t$countr\n  Total = \t$total\n  len_cutoff = \t$min_size\n  Longest = \t$length[0]\n  Shortest = \t$length[-1]\n  N$percent = \t$nSome\n";

1;
close (IN);


#Removing very long contig headers.   These can cause problems for nucmer.
print VFILE "Cleaning up contig headers...\n";
if (!-e "$AssFile.clean" ) {
	system "sed 's/>\\([0-9]\\+\\) .*/>\\1/' $AssFile > $AssFile.clean";
} else {
	print VFILE "\tCleaned fasta file exists, skipping cleaning.\n";
}

#Aligning to the reference genome, via nucmer.
print VFILE "Aligning contigs to reference...\n";
if ( !-e "$header.coords" ) {
	if ( -e "${header}.snps" ) {
		system "rm ${header}.snps";
	}
	print VFILE "\tRunning nucmer...\n";
	system "nucmer -o -p $header $RefFile $AssFile.clean";
	if ( !-e "$header.coords") {
		die "Nucmer failed. Exiting.";
	}
} else {
	print VFILE "\t$header.coords exists already, skipping.\n";
}

#Check that nucmer completed successfully
print VFILE "\tChecking nucmer file...\n";
if (`tail -n 1 ${header}.coords | awk '{print VFILE NF}'` < 13) {die "Nucmer ended early.\n"}
print VFILE "\t...nucmer complete.\n";

#Running show-snps
print VFILE "Determing base errors via alignments...\n";
if ( !-e "$header.snps" ) {
	print VFILE "\tRunning show-snps...\n";
	system "(show-snps -T $header.delta > $header.snps) >& show-snps.err";
	$err = `cat show-snps.err`;
	if ($err =~ m/ERROR/) { die "Show-snps failed.  Exiting."; }
} else {
	print VFILE "\t$header.snps exists already, skipping.\n";
}
print VFILE "\t...show-snps complete.\n";

#Loading the alignment files
print VFILE "Parsing coords...\n";
open (COORDS, "<$header.coords");
my $line = <COORDS>;

while ($line !~ /===/) {$line = <COORDS>;}
%aligns = ();

while ($line = <COORDS>){
	#Clear leading spaces from nucmer output
	$line =~ s/^\s+//;	
	#Store nucmer lines in an array
	@line = split(/\s+/, $line);
	push (@{$aligns{$line[12]}}, [@line]);
}

#Loading the assembly contigs
print VFILE "Loading Assembly...\n";
my %assembly;
my %assembly_ns;
my $assembly_seq = Bio::SeqIO->new(-file => $AssFile);
my $counter = 0;
while ( $seq = $assembly_seq->next_seq ){
	$counter++;
	if ($counter%10000 == 0) {print VFILE "\t...$counter contigs loaded.\n";}
	$name = $seq->display_id();
	if (!$name) {$name = "0"; }
	$assembly{$name} = $seq;
	$bases = $seq->seq();
	@bases = split(//, $bases);
	for ($i=0; $i<@bases; $i++){
		if ($bases[$i] =~ /(n|N)/) {
			$assembly_ns{$name}{$i} = $1;
		}
	}
	#$assembly_ns{$name} = ($bases =~ s/N/N/g);
}

#Loading the reference sequences
print VFILE "Loading Reference...\n";
my %reference;
my %ref_aligns;
my %ref_features;
my $ref_seq = Bio::SeqIO->new(-file => $RefFile);
while ( $seq = $ref_seq->next_seq ){
	$name = $seq->display_id();
	print VFILE "\tLoaded [$name]\n";
	$reference{$name} = $seq;
}

#Loading the SNP calls
print VFILE "Loading base errors...\n";
my %snps;
my %snp_locs;
open (SNPS, "<$header.snps");
while ($line = <SNPS>) {
	#print "$line";
	chomp $line;
	if ($line !~ /^\d/) {next;}
	#@line = split(/\t/, $line);
	@line = split (/\s+/, $line);
	$ref = $line[10];
	$ctg = $line[11];
	#print "[$ref]\t[$ctg]\t[$line[11]]\n";
	
	if (! exists $line[11]) { die "Malformed line in SNP file.  Please check that show-snps has completed succesfully.\n$line\n[$line[9]][$line[10]][$line[11]]\n"; }

	if ($line[1] =~ /\./){
		$snps{$ref}{$ctg}{$line[0]} = "I";
	} elsif ($line[2] =~ /\./){
		$snps{$ref}{$ctg}{$line[0]} = "D";	
	} else {
		$snps{$ref}{$ctg}{$line[0]} = "S";	
	}
	$snp_locs{$ref}{$ctg}{$line[0]} = $line[3];	

}

#Loading the regions (if any)
my %regions;
my $total_reg_len = 0;
my $total_regions = 0;
print VFILE "Loading Regions...\n";
if ( $gff_file ){
	#Load regions
	if ( $region ) {
		if ($region eq "CDS"){
			$family = $cds;
			if ($family){
				print VFILE "\tloading $family CDNAs.\n";
			} else {
				die "\tERROR: If parsing CDNA regions, a family must be provided\n";
			}
		}
		print VFILE "\tloading $region regions...\n";
		print VFILE "\tfrom file $gff_file...\n";
		open (REGIONS, "<$gff_file") or die "Can not open region file ($gff_file): $!\n";
		while ($line = <REGIONS>) {
			chomp $line;
			if ($line =~ /^\#/) {next; print VFILE "Skipping: $line\n";}
			@line = split(/\t/, $line);
			#print "[$region][$line[2]]\n";
			if ($region eq $line[2]) {
				if ($family && $line[8] !~ /$family/) {
					next;
				} 
				push (@{$regions{$line[0]}}, [$line[3], $line[4]]);
				$total_reg_len += $line[4]-$line[3]+1;
				$total_regions++;
				if ($total_regions%1000 == 0) {print VFILE "\t... $total_regions regions loaded.\n";}
			}
		}
	} else {
		die "You must provide a region type.\n";
	}
} else {
	print VFILE "\tNo regions given, using whole reference.\n";
	foreach $ref (keys %reference){
		push (@{$regions{$ref}}, [1, $reference{$ref}->length]);
		$total_regions++;
		$total_reg_len += $reference{$ref}->length;
	}
}	

print OFILE "\tTotal Regions: $total_regions\n";
print OFILE "\tTotal Region Length: $total_reg_len\n";

my $aligned = 0;
my $unaligned = 0;
my $partially_unaligned = 0;
my $total_unaligned = 0;
my $ambiguous = 0;
my $total_ambiguous = 0;
my $uncovered_regions = 0;
my $uncovered_region_bases = 0;

print VFILE "Analzing contigs...\n";
foreach $contig (keys %assembly){

	#Recording contig stats
	$ctg_len = $assembly{$contig}->length();
	if ( exists $assembly_ns{$contig} ) { $ns = scalar( keys %{$assembly_ns{$contig}});} else { $ns = 0;}
	if ($verbose) {print VFILE "\tCONTIG: $contig (${ctg_len}bp)\n";}

	#Check if this contig aligned to the reference
	if ( exists $aligns{$contig} ) {
	
		#Pull all aligns for this contig
		@aligns = @{$aligns{$contig}};
		$num_aligns = scalar(@aligns);
		
		#Sort aligns by length and identity
		@sorted = sort {@a = @{$a}; @b = @{$b}; $b[7]*$b[9] <=> $a[7]*$a[9] || $b[7] <=> $a[7]} @{$aligns{$contig}};
		$top_len = $sorted[0][7];
		$top_id = $sorted[0][9];
		@top_aligns = ();
		if ($verbose){print VFILE "\t\tTop Length: $top_len  Top ID: $top_id\n";}		

		#Check that top hit captures most of the contig (>99% or within 10 bases)
		if ( $top_len/$ctg_len > $peral || $ctg_len-$top_len < $maxun ) {
			
			#Reset top aligns: aligns that share the same value of longest and higest identity
			$top_aligns[0] = shift(@sorted);
	
			#Continue grabbing alignments while length and identity are identical
			while ( @sorted && $top_len == $sorted[0][7] && $top_id == $sorted[0][9]){
				push (@top_aligns, shift(@sorted) );
			}
			
			#Mark other alignments as ambiguious
			while (@sorted) {
				@ambig = @{pop(@sorted)};
				if ($verbose) { print VFILE "\t\tMarking alignment as amibguious: @ambig\n";}
				for ($i = $ambig[0]; $i <= $ambig[1]; $i++){
		                	if (! exists $ref_features{$ref}[$i]) {$ref_features{$ref}[$i] = "A";}
				}
			}

			if (@top_aligns < 2){
				#There is only one top align, life is good
				if ($verbose) {print VFILE "\t\tOne align captures most of this contig: @{$top_aligns[0]}\n";}				
				push (@{$ref_aligns{$top_aligns[0][11]}}, [$top_aligns[0][0], $top_aligns[0][1], $contig, $top_aligns[0][3], $top_aligns[0][4]]);
			} else {
				#There is more than one top align
				if ($verbose) {print VFILE "\t\tThis contig has ", scalar(@top_aligns)," significant alignments. [ambiguous]\n";}

				#Record these alignments as ambiguous on the reference
				foreach $align (@top_aligns){
					@alignment = @{$align};
					$ref = $alignment[11];
					if ($verbose) {print VFILE "\t\t\tAmbiguous Alignment: @alignment\n";}
					for ($i=$alignment[0]; $i <= $alignment[1]; $i++){
						if (! exists $ref_features{$ref}[$i]) {$ref_features{$ref}[$i] = "A";}
					}
				}
				
				#Increment count of ambiguous contigs and bases
				$ambiguous++;
				$total_ambiguous += $ctg_len;
			}

		} else {

			#Sort  all aligns by position on contig, then length	
			@sorted = sort {@a = @{$a}; 
					  @b = @{$b}; 
					  if ($a[3] < $a[4]) {$start_a = $a[3];} else {$start_a = $a[4];}
					  if ($b[3] < $b[4]) {$start_b = $b[3];} else {$start_b = $b[4];}
					  $start_a <=> $start_b || $b[7] <=> $a[7] || $b[9] <=> $a[9]} @sorted;
			
			#Push first alignment on to real aligns
			@real_aligns = ();
			push (@real_aligns, [@{$sorted[0]}]);
			if ($verbose) {print VFILE "\t\tReal align: @{$sorted[0]}\n";}
			if ($sorted[0][3] > $sorted[0][4]) { $last_end = $sorted[0][3]; } else { $last_end = $sorted[0][4]; } #determine end from orientation

			#Walk through alignments, if not fully contained within previous, record as real
			for ($i = 1; $i < $num_aligns; $i++) {
				#If this alignment extends past last alignment's endpoint, add to real, else skip
				if ($sorted[$i][3] > $last_end || $sorted[$i][4] > $last_end) {
					unshift (@real_aligns, [@{$sorted[$i]}]);					
					if ($sorted[$i][3] > $sorted[$i][4]) { $last_end = $sorted[$i][3]; } else { $last_end = $sorted[$i][4]; }
                                        if ($verbose) {print VFILE "\t\tReal align: @{$sorted[$i]}\n";}
				} else {
					if ($verbose) {print VFILE "\t\tSkipping [$sorted[$i][0]][$sorted[$i][1]] redundant alignment: ",$i,"@{$sorted[$i]}\n";}
					for ($j = $sorted[$i][0]; $j <= $sorted[$i][1]; $j++){
						if (! exists $ref_features{$ref}[$j]) {$ref_features{$ref}[$j] = "A";}
					}					                                                                                                                                
				}
			}
			
			$num_aligns = scalar(@real_aligns);
			
			if ($num_aligns < 2){
				#There is only one alignment of this contig to the reference

				#Is the contig aligned in the reverse compliment?
				$rc = $sorted[0][3] > $sorted[0][4];
				
				#Record beginning and end of alignment in contig
				if ($rc) {
					$end = $sorted[0][3];
					$begin = $sorted[0][4];
				} else {
					$end = $sorted[0][4];
					$begin = $sorted[0][3];
				}


				if ($begin-1 || $ctg_len-$end) {
					#Increment tally of partially unaligned contigs
					$partially_unaligned++;
					#Increment tally of partially unaligned bases
					$total_unaligned += $begin-1;
					$total_unaligned += $ctg_len-$end;
					if ($verbose) {print VFILE "\t\tThis contig is partially unaligned. ($top_len out of $ctg_len)\n";}
					if ($verbose) {print VFILE "\t\tUnaligned bases: 1 to $begin (", $begin-1, ")\n";}
					if ($verbose) {print VFILE "\t\tUnaligned bases: $end to $ctg_len (", $ctg_len-$end, ")\n";}
				}

				push (@{$ref_aligns{$sorted[0][11]}}, [$sorted[0][0], $sorted[0][1], $contig, $sorted[0][3], $sorted[0][4]]);
				
			} else {
				#There is more than one alignment of this contig to the reference
				if ($verbose) {print VFILE "\t\tThis contig ($contig) is misassembled. $num_aligns total aligns.\n";}
				
				#Reset real alignments and sum of real alignments
				$sum = 0;
			
				#Sort real alignments by position on the reference			
                        	@sorted = sort {@a = @{$a}; @b = @{$b}; $a[11] cmp $b[11] || $a[0] <=> $b[0]} @real_aligns;

				#Walk through real alignemnts, store in ref_aligns hash
				for ($i = 0; $i < @sorted-1; $i++){
					if ($verbose){print VFILE "\t\t\tReal Alignment ",$i+1,": @{$sorted[$i]}\n";}
					
					#Calculate the distance on the reference between the end of the first alignment and the start of the second
					$gap = $sorted[$i+1][0]-$sorted[$i][1];
					
					if ( $sorted[$i][11] ne $sorted[$i+1][11] || abs($gap) > $ns+$smgap ) {
						#Contig spans chromosomes or there is a gap larger than 1kb
						if ($verbose) {print VFILE "\t\t\tExtensive misassembly between these two alignments: [$sorted[$i][11]] @ $sorted[$i][1] and $sorted[$i+1][0] (${gap}bp)\n";}
						push (@{$ref_aligns{$sorted[$i][11]}}, [$sorted[$i][0], $sorted[$i][1], $contig, $sorted[$i][3], $sorted[$i][4]]);
						$ref_features{$sorted[$i][11]}[$sorted[$i][1]] = "M";
						$ref_features{$sorted[$i+1][11]}[$sorted[$i+1][1]] = "M";					       
					} elsif ($gap < 0) {
						#There is overlap between the two alignments, a local misassembly
						if ($verbose) {print VFILE "\t\t\tOverlap between these two alignments (local misassembly): [$sorted[$i][11]] $sorted[$i][1] to $sorted[$i+1][0]\n";}
						push (@{$ref_aligns{$sorted[$i][11]}}, [$sorted[$i][0], $sorted[$i][1], $contig, $sorted[$i][3], $sorted[$i][4]]);
					} else {
						#There is a small gap between the two alignments, a local misassembly
						if ($verbose) {print VFILE "\t\t\tGap in alignment between these two alignments (local misassembly): ${gap}bp\n";}
						push (@{$ref_aligns{$sorted[$i][11]}}, [$sorted[$i][0], $sorted[$i][1], $contig, $sorted[$i][3], $sorted[$i][4]]);
					}	
				}
				
				#Record the very last alignment
				if ($verbose){print VFILE "\t\t\tReal Alignment ",$i+1,": @{$sorted[$i]}\n";}
				push (@{$ref_aligns{$sorted[$i][11]}}, [$sorted[$i][0], $sorted[$i][1], $contig, $sorted[$i][3], $sorted[$i][4]]);
			}
		}
	} else {
		#No aligns to this contig
		if ($verbose) {print VFILE "\t\tThis contig is unaligned. ($ctg_len bp)\n";}

		#Increment unaligned contig count and bases
		$unaligned++;
		$total_unaligned += $ctg_len;
		if ($verbose) {print VFILE "\t\tUnaligned bases: $ctg_len  total: $total_unaligned\n";}
	}
}



print VFILE "Analyzing coverage...\n";

	$region_covered = 0;
	$region_ambig = 0;
	$region_misassemblies = 0;
	$region_snp = 0;
	$region_insertion = 0;
	$region_deletion = 0;
	%misassembled_contigs = ();
	@gaps = ();
	@neg_gaps = ();
	@redundant = ();
	$snip_left = 0;
	$snip_right = 0;



#Go through each header in reference file
foreach $ref (keys %regions){
	

	#Check to make sure this reference ID contains aligns.
	if (! exists $ref_aligns{$ref}) { 
		print VFILE "WARNING: Reference [$ref] does not have any alignments!  If this doesn't make sense, please check that this is the same file used for alignment.\n";
		next; 
	}
	
	#Sort all alignments in this reference by start location
	@sorted = sort {@a = @{$a}; @b = @{$b}; $a[0] <=> $b[0]} @{$ref_aligns{$ref}};
	$total_aligns = scalar(@sorted);
	print VFILE "\tReference $ref: $total_aligns total alignments. ", scalar(@{$regions{$ref}}), " total regions.\n";	

	#Walk through each region on this reference sequence	
	foreach $region ( @{$regions{$ref}} ) {
		
		#Initiate region metrics
		my $end = 0;
		@region = @{$region};
		$reg_length = $region[1]-$region[0];
		if ($verbose) {print VFILE "\t\tRegion: $region[0] to $region[1] ($reg_length bp)\n";}

		#Skipping alignments not in the next region
		while (@sorted && $sorted[0][1] < $region[0]) { 
			@skipped = @{shift @sorted};
			if ($verbose) {print VFILE "\t\t\tThis align occurs before our region of interest, skipping: @skipped\n";  }
		}
		
		if (!@sorted){
			if ($verbose) {print VFILE "\t\t\tThere are no more aligns.  Skipping this region.\n";}
			next; 
		}

		#If region starts in a contig, ignore portion of contig prior to region start
		if (exists $sorted[0] && exists $region[0] && $sorted[0][0] < $region[0]) { 
		
			if ($verbose) {print VFILE "\t\t\tSTART within alignment : @{$sorted[0]}\n";}			
			
			#Track number of bases ignored at the start of the alignment
			$snip_left = $region[0]-$sorted[0][0];
			#Modify to account for any insertions or deletions that are present	
			for ($z = $sorted[0][0]; $z <= $region[0]; $z++){
				if (exists $snps{$ref}{$sorted[0][2]}{$z} && exists $ref_features{$ref}[$i] && $ref_features{$ref}[$i] ne "A") { 
					if ($snps{$ref}{$sorted[0][2]}{$z} eq "I") { $snip_left++; }
					if ($snps{$ref}{$sorted[0][2]}{$z} eq "D") { $snip_left--; }					
				}		
			}
			
			#Modify alignment to start at region
			if ($verbose) { print VFILE "\t\t\t\tMoving reference start from $sorted[0][0] to $region[0]\n";}
			$sorted[0][0] = $region[0];

			#Modify start position in contig
			if ($sorted[0][3] < $sorted[0][4]){
				if ($verbose) { print VFILE "\t\t\t\tMoving contig start from $sorted[0][3] to ", $sorted[0][3]+$snip_left,".\n"; }
				$sorted[0][3] += $snip_left;
			} else {
				if ($verbose) { print VFILE "\t\t\t\tMoving contig start from $sorted[0][3] to ", $sorted[0][3]-$snip_left,".\n"; }
				$sorted[0][3] -= $snip_left;
			}
		}

		#No aligns in this region
		if ($sorted[0][0] > $region[1]){
			if ($verbose) { print VFILE "\t\t\tThere are no aligns within this region.\n";}
			push (@gaps, [$reg_length,"START","END"]);
			#Increment uncovered region count and bases
			$uncovered_regions++;
			$uncovered_region_bases += $reg_length;
			next;
		}

		#Record first gap, and first ambiguous bases within it
		if ($sorted[0][0] > $region[0]) {
		
			$size = $sorted[0][0]-$region[0];
			if ($verbose) { print VFILE "\t\t\tSTART in gap: $region[0] to $sorted[0][0] ($size bp)\n"; }
			push (@gaps, [$size,"START",$sorted[0][2]]);

			#Increment any ambiguously covered bases in this first gap
			for ($i=$region[0]; $i < $sorted[0][1]; $i++){
				if (exists $ref_features{$ref}[$i] && $ref_features{$ref}[$i] eq "A") { $region_ambig++; }
			}
		}
		
		
		#For counting number of alignments
		$counter = 0;
		$negative = 0;
		while ( @sorted && $sorted[0][0] < $region[1] && !$end) {
				
			#Increment alignment count
			$counter++;
			if ($counter%1000 == 0) {print VFILE "\t...$counter of $total_aligns\n";}
			$end = 0;

			#Check to see if previous gap was negative
			if ($negative) {
				if ($verbose) { print VFILE "\t\t\tPrevious gap was negative, modifying coordinates to ignore overlap\n"; }
				#Ignoring OL part of next contig, no SNPs or N's will be recorded
				$snip_left = $current[1]+1 - $sorted[0][0]; 
				
				#Account for any indels that may be present
				for ($z = $sorted[0][0]; $z <= $current[1]+1; $z++){
					if (exists $snps{$ref}{$sorted[0][2]}{$z} ) { 
						if ($snps{$ref}{$sorted[0][2]}{$z} eq "I") { $snip_left++; }
						if ($snps{$ref}{$sorted[0][2]}{$z} eq "D") { $snip_left--; }					
					}		
				}

				#Modifying position in contig of next alignment					
				$sorted[0][0] = $current[1]+1;
				if ($sorted[0][3] < $sorted[0][4]) {
					if ($verbose) { print VFILE "\t\t\t\tMoving contig start from $sorted[0][3] to ", $sorted[0][3]+$snip_left,".\n"; }
				       	$sorted[0][3] += $snip_left;
				} else {
				      	if ($verbose) { print VFILE "\t\t\t\tMoving contig start from $sorted[0][3] to ", $sorted[0][3]-$snip_left,".\n"; }
				        $sorted[0][3] -= $snip_left;
				}
				$negative = 0;
			}
			
			#Pull top alignment
			@current = @{shift @sorted};
			if ($verbose) { print VFILE "\t\t\tAlign ",$counter,": @current\n"; }

			#Check if:
			# A) We have no more aligns to this reference
			# B) The current alignment extends to or past the end of the region
			# C) The next alignment starts after the end of the region
			
			if ( !@sorted || $current[1] >= $region[1] || $sorted[0][0] > $region[1] ){

				#Check if last alignment ends before the regions does (gap at end of the region)
				if ( $current[1] >= $region[1]) {
					#print VFILE "Ends inside current alignment.\n";
					if ($verbose) {print VFILE "\t\t\tEND in current alignment.  Modifying $current[1] to $region[1].\n";}
					
					#Pushing the rest of the alignment back on the stack
        	                       	unshift (@sorted, [@current]);
        	                       	
        	                       	#Flag to end loop through alignment
        	                       	$end = 1;
        	                       	
        	                       	#Clip off right side of contig alignment
                        	        $snip_right = $current[1]-$region[1];
                        	        #End current alignment in region
                                	$current[1] = $region[1];
                                	
                                } else {
					#Region ends in a gap
					$size = $region[1]-$current[1];
					if ($verbose) {print VFILE "\t\t\tEND in gap: $current[1] to $region[1] ($size bp)\n";}

					#Record gap
					if (!@sorted) {
						#No more alignments, region ends in gap.
						push (@gaps, [$size,$current[2],"END"]);
					} else {
						#Gap between end of current and beginning of next alignment.
						push (@gaps, [$size,$current[2],$sorted[0][2]]);
					}
					
					#Increment any ambiguous bases within this gap
	              			for ($i=$current[1]; $i < $region[1]; $i++){
                              			if (exists $ref_features{$ref}[$i] && $ref_features{$ref}[$i] eq "A") { $region_ambig++;}
                        		}
				} 
				
			} else {	
				#Grab next alignment
				@next = @{$sorted[0]};
				if ($verbose) { print VFILE "\t\t\t\tNext Alignment: @next\n";}
				
                         	if ($next[0] >= $current[1]){
					#There is a gap beetween this and the next alignment
					$size = $next[0] - $current[1] - 1;
					push (@gaps, [$size,$current[2],$next[2]]);
					if ($verbose) {print VFILE "\t\t\t\tGap between this and next alignment: $current[1] to $next[0] ($size bp)\n";}
					#Record ambiguous bases in current gap
		        	      	for ($i=$current[1]; $i < $next[0]; $i++){
	                             		if (exists $ref_features{$ref}[$i] && $ref_features{$ref}[$i] eq "A") { $region_ambig++;}
	                        	}
				} elsif ($next[1] <= $current[1] ){
					#The next alignment is redundant to the current alignmentt
					while ($next[1] <= $current[1] && @sorted) {
						if ($verbose) {print VFILE "\t\t\t\tThe next contig is redundant. Skipping.\n";}				
						push (@redundant, $current[2]);
						@next = @{shift @sorted};
						$counter++;
					}
				} else {
					#This alignment overlaps with the next alignment, negative gap
					
					#If contig extends past the region, clip
					if ($current[1] > $region[1]) { $current[1] = $region[1]; }

					#Record gap
					$size = $next[0]-$current[1];
					push (@neg_gaps, [$size,$current[2],$next[2]]);
					if ($verbose) {print VFILE "\t\t\t\tNegative gap between this and next alignment: ${size}bp $current[2] to $next[2]\n";}

					#Mark this alignment as negative so overlap region can be ignored
					$negative = "True";
				}
			}

			#Initiate location of SNP on assembly to be first or last base of contig alignment
			$contig_estimate = $current[3];
			if ($verbose) { print VFILE "\t\t\t\tContig start coord: $contig_estimate\n";}

			#Assess each reference base of the current alignment
			for ($i = $current[0]; $i <= $current[1]; $i++){
			
				#Mark as covered
				$region_covered++;
				
				#If there is a misassembly, increment count and contig length
				if (exists $ref_features{$ref}[$i] && $ref_features{$ref}[$i] eq "M") {
				     
					$region_misassemblies++;
					$misassembled_contigs{$current[2]} = $assembly{$current[2]}->length;
				}
				
				#If there is a SNP, and no alternative alignments over this base, record SNPs
				if (exists $snps{$ref}{$current[2]}{$i}) {
				
					if ($verbose) {print VFILE "\t\t\t\tSNP: $ref, $current[2], $i, $snps{$ref}{$current[2]}{$i}, $contig_estimate, $snp_locs{$ref}{$current[2]}{$i}\n";}
				
					#Capture SNP base
					$snp = $snps{$ref}{$current[2]}{$i};

					#Check that there are not multiple alignments at this location
					if (exists $ref_features{$ref}[$i]) {
						if ($verbose) {print VFILE "\t\t\t\t\tERROR: SNP at a postion where there are multiple alignments ($ref_features{$ref}[$i]).  Skipping.\n";}
						if ($current[3] < $current[4]) { $contig_estimate++; } else { $contig_estimate--; }
						next;
					#Check that the position of the SNP in the contig is close to the position of this SNP
					} elsif (abs ($contig_estimate - $snp_locs{$ref}{$current[2]}{$i}) > 50) {
						if ($verbose) {print VFILE "\t\t\t\t\tERROR: SNP position in contig was off by ", abs($contig_estimate-$snp_locs{$ref}{$current[2]}{$i}), "bp! ($contig_estimate vs $snp_locs{$ref}{$current[2]}{$i})\n";}
						if ($current[3] < $current[4]) { $contig_estimate++; } else { $contig_estimate--; }
						next;
					}
					
					#If SNP is an insertion, record
					if ($snp =~ "I") { 
						$region_insertion++; 
						if ($current[3] < $current[4]) {$contig_estimate++;} else {$contig_estimate--;}
					}
					
					#If SNP is a deletion, record
					if ($snp =~ "D") { 
						$region_deletion++; 
						if ($current[3] < $current[4]) { $contig_estimate--; } else { $contig_estimate++; } 
					}
					
					#If SNP is a mismatch, record
					if ($snp =~ "S") { $region_snp++; }
				}
				if ($current[3] < $current[4]) { $contig_estimate++; } else { $contig_estimate--; }
			}
			
			#Record Ns in current alignment
			if ($current[3] < $current[4]){
				#print VFILE "\t\t(forward)Recording Ns from $current[3]+$snip_left to $current[4]-$snip_right...\n";
				for ($i = $current[3]+$snip_left; $i <= $current[4]-$snip_right; $i++){
					if (exists $assembly_ns{$current[2]}{$i}) { $region_ambig++;}
				}
			} else {
				#print VFILE "\t\t(reverse)Recording Ns from $current[4]+$snip_right to $current[3]-$snip_left...\n";
				for ($i = $current[4]+$snip_right; $i < $current[3]-$snip_left; $i++){
					if (exists $assembly_ns{$current[2]}{$i}) { $region_ambig++;}					
				}
			}
			$snip_left = 0;
			$snip_right = 0;	

		}
	}						
	
}

	$representation = $region_covered/$total_reg_len ;
	
	print OFILE "\tCovered Bases: $region_covered\n";
	print OFILE "\tRepresentation: $representation\n";
	print OFILE "\tAmbiguous Bases: $region_ambig\n";
	print OFILE "\tMisassemblies: $region_misassemblies\n";
	print OFILE "\t\tMisassembled Contigs: ", scalar(keys %misassembled_contigs), "\n";

	$misassembled_bases = 0;
	foreach $ctg (keys %misassembled_contigs){
	        print VFILE "\t\t\t$ctg\t$misassembled_contigs{$ctg}\n";
		$misassembled_bases += $misassembled_contigs{$ctg};
	}
	print OFILE "\t\tMisassembled Contig Bases: $misassembled_bases\n";
	print OFILE "\tSNPs: $region_snp\n";
	print OFILE "\tInsertions: $region_insertion\n";
	print OFILE "\tDeletions: $region_deletion\n";
	print OFILE "\tPositive Gaps: ", scalar(@gaps), "\n";

	$internal = 0;
	$external = 0;
	$sum = 0;
	foreach $gap (@gaps){
		@gap = @{$gap};
		if ($gap[1] eq $gap[2]){
			$internal++;
		} else {
			$external++;
			$sum += $gap[0];
		}
	}	
	
	print OFILE "\t\tInternal Gaps: $internal\n";
	print OFILE "\t\tExternal Gaps: $external\n";
	print OFILE "\t\tExternal Gap Total: $sum\n";
	
	if ($external) {
		$avg = sprintf("%.0f", $sum/$external);
	} else {
		$avg = "0.0";
	}	
	print OFILE "\t\tExternal Gap Average: $avg\n";
	print OFILE "\tNegative Gaps: ", scalar(@neg_gaps), "\n";

	$internal = 0;
	$external = 0;
	$sum = 0;
	foreach $gap (@neg_gaps){
		@gap = @{$gap};
		if ($gap[1] eq $gap[2]){
			$internal++;
		} else {
			$external++;
			$sum += $gap[0];
		}
	}
	
	print OFILE "\t\tInternal Overlaps: $internal\n";
	print OFILE "\t\tExternal Overlaps: $external\n";
	print OFILE "\t\tExternal Overlaps Total: $sum\n";
	
	if ($external) {
		$avg = sprintf("%.0f", $sum/$external);
	} else {
		$avg = 0;
	}
	
	print OFILE "\t\tExternal Overlaps Average: $avg\n";
	print OFILE "\tRedundant Contigs: ", scalar(@redundant), "\n";
	
print OFILE "\n";
print OFILE "Uncovered Regions: $uncovered_regions ($uncovered_region_bases)\n";
print OFILE "Unaligned Contigs: $unaligned ($partially_unaligned partial) ($total_unaligned)\n";
print OFILE "Ambiguous Contigs: $ambiguous ($total_ambiguous)\n";
close (OFILE);

__END__

=head1 NAME

sample - Using GetOpt::Long and Pod::Usage

=head1 SYNOPSIS

assess_assembly.pl [options] --reference [reference_fasta] --assembly [assembly_fasta] --header [header]

Options:

	--reference	STRING	full path to fasta file of the reference sequence
	--assembly 	STRING	fulll path to the fasta file of the assembly
	--header	STRING	header for naming nucmer files
	
	--gff		STRING  full path to gff file containing regions of interest
	--region	STRING	the type of regions you would like to analyze
	--cds		STRING	search term to desigante the CDS type
	
	--sm_gap_size	INTEGER	maximum gap in alignment to be considered a local misassembly (Default = 1000)
	--num_unaligned	INTEGER	maximum number of unaligned bases allowed on the ends of contigs (Default = 10)

	--verbose
       	--help            

=head1 OPTIONS

=over 8

=item B<-help>
Print a brief help message and exits.

=item B<-man>
Prints the manual page and exits.

=back

=head1 DESCRIPTION
    B<This program> will read the given input file(s) and do something
    useful with the contents thereof.

=cut

