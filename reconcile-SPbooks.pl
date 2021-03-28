#!/usr/bin/perl -w
########################################################################
# File:     reconcile-SPbooks.pl
#
# Purpose:  To find out which records are missing from the catalogue and whether we've activated titles to which we're not entitled.
#
# Method:   Compares KBART files against list of activated URLs and MARC records to produce reports and output sets of MARC records.
#
# Input: 1) One or more URL export files in CSV format from Alma with three columns: Resource Type,Portfolio ID,URL.
#        2) One or more entitlement files from Scholars Portal admintool
#        3) One or more MARC files from Scholars Portal admintool
#
# Output: 1) a file listing the entitlements filename, URL, title, ISBN and eISBN for titles in the entitlements file with a corresponding activated portfolio URL (SP-books-found.log)
#         2) a file listing the entitlements filename, URL, title, ISBN and eISBN for titles in the entitlements file without a corresponding activated portfolio URL (SP-books-entitled_not_found.log)
#         3) a file of the Portfolio Ids and URLs for portfolios activated in Alma, but that don't appear in the entitlements files (SP-books-activated_not_found.log)
#         4) a error logfile of Portfolio Ids and URLs for URLs that don't match the expected SP Books syntax  (SP-books-errors.log)
#         5) a logfile listing each URL in the CSV file(s) with the number of portfolios found (should be one portfolio per URL)
#
# Copyright (C) 2021 Geoff Sinclair
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston,
# MA 02110-1301, USA.
#
# Author:  Geoff Sinclair
# Date:    March 28, 2021
# Revised:
# Rev:     0.1
########################################################################

use strict;
use File::Basename;
use File::Find::Rule;
use File::Path qw(make_path);
use Text::CSV;
use utf8;
use open ':std', ':encoding(UTF-8)';
use Archive::Zip;
use MARC::File::USMARC;
use MARC::Record;
use MARC::File::XML ( BinaryEncoding => 'utf8', RecordFormat => 'MARC21' );
use Try::Tiny;
use vars qw/ %opt /;
use Getopt::Std;

my $proxy = 'http://proxy.lib.trentu.ca/login?url=';
my $sp_book_url_start = 'http://books.scholarsportal.info/';
my $dirname = dirname(__FILE__);

$| = 1;

sub usage {
    print STDERR << "EOF";

Compares KBART files against list of activated URLs and MARC records to produce reports and output sets of MARC records.

usage: perl $0 [-x] [-d KBART and MARC directory] [-p proxy]

 -d [directory]        : The directory containing KBART and MARC file (optional). Default is the script directory.
 -p [proxy prefix]     : The EZproxy prefix for your institution (optional).
 -x                    : This (help) message.

example:
perl $0 -d"kbart-marc-dir" -p"http://proxy.lib.trentu.ca/login?url="

EOF
    exit;
}

sub init {
    my $opt_string = 'd:p:x';
    getopts( "$opt_string", \%opt ) or usage();
    usage() if ($opt{'x'});
	if ($opt{'d'})
	{
		$dirname = $opt{'d'};
	}
	if ($opt{'p'})
	{
		$proxy = $opt{'p'};
	}
}

init();
my $proxy_sp_book_url = $proxy . $sp_book_url_start;

my $csv = Text::CSV->new (
                           { allow_loose_escapes => 1 },
                           { escape_char => "\\" },
                         );

my @field;
my ($filename,$log_filename);
my $fileCtr = 0;
my $recCtr = 0;
my ($url,$path);
my %url_list;
my %portfolio_id;

open (ERRLOG, "> CSV-errors.log") or die $!;

# Look for CSV files in the current directory. Assume all are URLs from Alma to be processed (typically there is only one).
my @csv_filenames = File::Find::Rule->file()
                                ->name("*.csv")
                                ->in( $dirname );

FILELOOP1:
foreach $filename (@csv_filenames) {
	open (CSVFILE, $filename) or die $!;
	$fileCtr++;
	$recCtr=0;
	print "Now working on file: $filename\n";
	RECORDLOOP1:
	while (<CSVFILE>) {
		my $curLine = $_;
		chomp($curLine);
		$recCtr++;
		# Skip headings line
		next if ($recCtr == 1);
		if ($csv->parse($curLine)) {
			@field = $csv->fields;
			if (scalar(@field) == 3) {
				$url = $field[2];
				if (substr($url, 0, length($proxy_sp_book_url)) eq $proxy_sp_book_url) {
					$path = normalize_SP_link(substr($url, length($proxy)));
					$url_list{$path}++;
					$portfolio_id{$path} = $field[1];
				} elsif (substr($url, 0, length($sp_book_url_start)) eq $sp_book_url_start) {
					$path = normalize_SP_link($url);
					$url_list{$path}++;
					$portfolio_id{$path} = $field[1];
				} else {
					print ERRLOG  "URL not formed as expected for Portfolio ID:\t$field[1]\t$url\n";
				}
			} else {
				print ERRLOG  "Skipping line $recCtr: expected 3 fields and found ", scalar(@field), "\n";
			}
		} else {
			my $err = $csv->error_input;
			print "$filename LINE $recCtr: parse() failed on argument: ", $err, "\n";
		}
	}

	close CSVFILE;

	$log_filename = substr ($filename, 0, -4) . ".log";
	open(LOGFILE, "> $log_filename") or die $!;

	foreach $path ( keys ( %url_list ) ) {
		print LOGFILE "$path\t$url_list{$path}\n";
	}
	close LOGFILE;
}

close ERRLOG;

# Look for text files in the current directory and all subdirectories. Assume all *.txt files are entitlements to be processed.
my @filenames = File::Find::Rule->file()
                                ->name("*.txt")
                                ->in( $dirname );

$fileCtr = 0;
$recCtr = 0;
my $i;
my ($publication_title_index,$print_identifier_index,$online_identifier_index,$title_url_index);
my %entitled_url_list;
my %missing_entitled_url_record;
my %missing_entitled_url_index;

open (FOUND, "> SP-books-entitled-links-found-in-Alma.log") or die $!;
open (NOTFOUND, "> SP-books-entitled-links-NOT-found-in-Alma.log") or die $!;
print FOUND "filename\tURL\ttitle\tISBN\teISBN\n";
print NOTFOUND "filename\tURL\ttitle\tISBN\teISBN\n";

FILELOOP2:
foreach $filename (@filenames) {
	open (TXTFILE, $filename) or die $!;
	$fileCtr++;
	$recCtr=0;
	$publication_title_index = -1;
	$print_identifier_index = -1;
	$online_identifier_index = -1;
	$title_url_index = -1;
	print "Now working on file: $filename\n";
	RECORDLOOP2:
	while (<TXTFILE>) {
		my $curLine = $_;
		$recCtr++;
		if ($recCtr == 1) {
			@field = split("\t",$curLine);
			for ($i=0;$i<(scalar(@field)-1);$i++) {
				$publication_title_index = $i if ($field[$i] eq 'publication_title');
				$print_identifier_index = $i if ($field[$i] eq 'print_identifier');
				$online_identifier_index = $i if ($field[$i] eq 'online_identifier');
				$title_url_index = $i if ($field[$i] eq 'title_url');
			}
			unless (($publication_title_index+1) && ($print_identifier_index+1) && ($online_identifier_index+1) && ($title_url_index+1)) {
				print "Invalid text file: $filename ...skipping...\n";
				next FILELOOP2;
			}
		} else {
			@field = split("\t",$curLine);
			$path = normalize_SP_link($field[$title_url_index]);
			$entitled_url_list{$path}++;
			if ($url_list{$path}) {
				print FOUND "$path\t$filename\t$field[$title_url_index]\t$field[$publication_title_index]\t$field[$print_identifier_index]\t$field[$online_identifier_index]\n";
			} else {
				print NOTFOUND "$path\t$filename\t$field[$title_url_index]\t$field[$publication_title_index]\t$field[$print_identifier_index]\t$field[$online_identifier_index]\n";
				$missing_entitled_url_index{$path}{'title_url'} = $entitled_url_list{$field[$title_url_index]};
				$missing_entitled_url_record{$path}{'filename'} = $filename;
				$missing_entitled_url_record{$path}{'publication_title'} = $field[$publication_title_index];
				$missing_entitled_url_record{$path}{'print_identifier'} = $field[$print_identifier_index];
				$missing_entitled_url_record{$path}{'online_identifier'} = $field[$online_identifier_index];
			}
		}
	}
	close TXTFILE;
}

close FOUND;
close NOTFOUND;

open (ACTIVENOTFOUND, "> SP-books-activated-in-Alma-not-found-in-Entitlements.log") or die $!;
#open (ACTIVEFOUND, "> SP-books-activated_and_found.log") or die $!;
print ACTIVENOTFOUND "Portfolio ID\tURL\n";
foreach $path ( keys ( %url_list ) ) {
	if ($entitled_url_list{$path}) {
		# Everything's good with the world.
#		print ACTIVEFOUND "$portfolio_id{$path}\t$path\n";
	} else {
		print ACTIVENOTFOUND "$portfolio_id{$path}\t$path\n";
	}
}

close ACTIVENOTFOUND;
#close ACTIVEFOUND;

open (ZIPLOG, "> ZIP-files.log") or die $!;

my @zip_filenames = File::Find::Rule->file()
                                ->name("*.zip")
                                ->in( $dirname );

FILELOOP3:
foreach my $filename (@zip_filenames) {
	print ZIPLOG "$filename\n";
	my $zip = Archive::Zip->new();

	my $status  = $zip->read($filename);
  print "Status of read for $filename: $status\n";
	die "Read of $filename failed\n" if $status != '0';

	my $path = $filename;
	$path =~ s/\.zip$//;
	# Create directory path unless it already exists
	make_path($path) unless (-d $path);

	foreach my $memberName ($zip->memberNames()) {
		if (($memberName =~ /.*\.mrc/) || ($memberName =~ /.*\.xml/)) {
			print ZIPLOG "Extracting $memberName\n";
			$memberName =~ /.*\/(.*)/;
			my $path_file = ($1) ? $1 : $memberName;
			my $new_path = $path . "/" . $path_file;
			print ZIPLOG "New path: $new_path\nMember name: $memberName\n";
			$status = $zip->extractMemberWithoutPaths($memberName,$new_path);
			if ($status != 0) {
				die "Extracting $memberName from $filename failed: $status\n";
			}
		} else {
			print ZIPLOG "Skipping $memberName\n";
		}
	}
}

close ZIPLOG;

my @mrc_filenames = File::Find::Rule->file()
                                ->name("*.xml")
                                ->in( $dirname );

open(MRCLOG, "> MRC-files.log") or die $!;

my %mrc_url_ctr;

my $almaLoadFile = 'SP-entitled-not-yet-in-Alma-FOUND-RECORDS.xml';
# my $almaRefFile = 'SP-entitled-links-already-in-ALMA.mrc';
my $badLinkFile = 'SP-BAD-LINKS.xml';
my $noLinkFile = 'SP-NO-LINKS.xml';

#open(LOADLINK, "> $almaLoadFile") or die $!;
my $alma_load_file = MARC::File::XML->out( $almaLoadFile );
# open(NOLOADLINK, "> $almaRefFile") or die $!;
#open(BADLINK, "> $badLinkFile") or die $!;
my $bad_link_file = MARC::File::XML->out( $badLinkFile );
#open(NOLINK, "> $noLinkFile") or die $!;
my $no_link_file = MARC::File::XML->out( $noLinkFile );
my $record;

FILELOOP4:
foreach $filename (@mrc_filenames) {
	print "$filename\n";
	my $file = MARC::File::XML->in( $filename );
	die "No file named $filename found.\n" unless $file;
	my $mrcRecCtr;

	# Catch errors caused by invalid MARC and write to the log.
	while ( try { $record = $file->next(); } catch { print MRCLOG "$_"; } ) {

		$mrcRecCtr++;
		$record->encoding( 'UTF-8' );
		my $title = $record->title();
		my $t856 = $record->field('856');
		if ($t856) {
			my $url = $t856->subfield('u');
			if ($url) {
				if (substr($url, 0, length($sp_book_url_start)) eq $sp_book_url_start) {
					$path = normalize_SP_link($url);
					if ($url_list{$path}) {
						# Everything's good with the world.
						print MRCLOG "RECORD WITH LINK IN ALMA:     File: $filename     Record $mrcRecCtr: $title    Link: $url\n";
						# print NOLOADLINK $record->as_usmarc();
					} else {
						print MRCLOG "NO RECORD WITH LINK IN ALMA:     File: $filename     Record $mrcRecCtr: $title     Link: $url\n";
						unless ($mrc_url_ctr{$path}) {
							# print LOADLINK $record->as_usmarc();
							$alma_load_file->write( $record );
							$mrc_url_ctr{$path}++;
						} else {
							print MRCLOG "Skipping... record already printed.\n";
							$mrc_url_ctr{$path}++;
						}
					}
				} else {
					# print BADLINK $record->as_usmarc();
					$bad_link_file->write( $record );
					print MRCLOG "BAD LINK:     File: $filename     Record $mrcRecCtr: $title     Link: $url\n";
				}
			} else {
				# print NOLINK $record->as_usmarc();
				$no_link_file->write( $record );
				print MRCLOG "NO 856u:     File: $filename     Record $mrcRecCtr: $title     Link: $url\n";
			}
		} else {
			print MRCLOG "NO 856:  Record $mrcRecCtr: $title\n";
		}
	}
}

$alma_load_file->close();
$bad_link_file->close();
$no_link_file->close();

open (ENTITLEDNORECORDS, "> SP-books-entitled-not-in-Alma-NO-RECORDS-FOUND.log") or die $!;
print ENTITLEDNORECORDS "filename\tURL\ttitle\tISBN\teISBN\n";
foreach $path ( keys ( %missing_entitled_url_index ) ) {
	if ($mrc_url_ctr{$path}) {
		# Everything's good with the world.
#		print ENTITLEDNORECORDS "FOUND: $path\n";
	} else {
		print ENTITLEDNORECORDS $missing_entitled_url_record{$path}{'filename'}, "\t",
					$path, "\t",
					$missing_entitled_url_record{$path}{'publication_title'}, "\t",
					$missing_entitled_url_record{$path}{'print_identifier'}, "\t",
					$missing_entitled_url_record{$path}{'online_identifier'}, "\n";
	}
}

# Would it be too much to ask that the URLs in the KBART and MARC files be the same? Yes. Yes it would.
sub normalize_SP_link {

	my $link = shift;

	$link =~ /.*(\/ebooks\/.*)/;
	if ($1) {
		return $1;
	} else {
		return $link;
	}
}
