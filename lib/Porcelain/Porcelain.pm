package Porcelain::Porcelain;

use strict;
use warnings;

require Exporter;
our @ISA = qw(Exporter);
our @EXPORT = qw(caught_sigint downloader lines readconf sep);

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

sub lines {	# multi-line text scalar --> $first_line / @lines
	my @lines = (split /\n/, $_[0]);
	return wantarray ? @lines : $lines[0];
}

sub readconf {	# filename of file with keys and values separated by ':'--> hash of keys and values
	my $file = $_[0];
	my %retval;
	open(my $in, $file) or die "Can't open $file: $!";
	while (<$in>)
	{
		chomp;
		if ($_ =~ /^\s*#/) {	# ignore comments
			next;
		}
		my ($key, $value) = split /:/;
		next unless defined $value;
		$key =~ s/^\s+//;
		$key =~ s/\s+$//;
		$value =~ s/^\s+//;
		$value =~ s/\s+$//;
		$retval{$key} = $value;
	}
	close $in or die "$in: $!";
	return %retval
}

sub sep {	# gmi string containing whitespace --> ($first, $rest)
	my $first =	$_[0] =~ s/[[:blank:]].*$//r;
	my $rest =	$_[0] =~ s/^[^[:blank:]]*[[:blank:]]*//r;
	return wantarray ? ($first, $rest) : $first;
}

1;
