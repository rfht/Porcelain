package Porcelain::Porcelain;

use strict;
use warnings;

require Exporter;
our @ISA = qw(Exporter);
our @EXPORT = qw(caught_sigint downloader);

sub caught_sigint {
	Porcelain::CursesUI::clean_exit "Caught SIGINT - aborting...";
}

sub downloader {	# $url, $body --> 0: success, >0: failure
	# TODO: add timeout; progress bar
	my ($dlurl, $dlcont) = @_;
	my $dl_file = $dlurl =~ s|^.*/||r;
	$dl_file = $ENV{'HOME'} . "/Downloads/" . $dl_file;
	Porcelain::CursesUI::c_prompt_ch "Downloading $dlurl ...";
	open my $fh, '>:raw', $dl_file or Porcelain::CursesUI::clean_exit "error opening $dl_file for writing";
	print $fh $dlcont or Porcelain::CursesUI::clean_exit "error writing to file $dl_file";
	close $fh;
	return 0;
}

1;
