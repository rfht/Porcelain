package Porcelain::Porcelain;

use strict;
use warnings;

require Exporter;
our @ISA = qw(Exporter);
our @EXPORT = qw(caught_sigint downloader lines readconf readtext sep);

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
	binmode($fh);
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

sub readtext { # read text file, line by line. param: filepath --> return: array of lines
	my @r_array;	# return array
	open my $fh, '<', $_[0] or die "cannot open $_[0]";
	while (<$fh>) {
		chomp;
		push @r_array, $_;
	}
	close $fh;
	return @r_array;
}

sub sep {	# gmi string containing whitespace --> ($first, $rest)
	my $first =	$_[0] =~ s/[[:blank:]].*$//r;
	my $rest =	$_[0] =~ s/^[^[:blank:]]*[[:blank:]]*//r;
	return wantarray ? ($first, $rest) : $first;
}

sub uri_class {	# URL string --> string of class ('gemini', 'https', etc.)
	if ($_[0] =~ m{^[[:alpha:]]+://}) {
		return $_[0] =~ s/^([[:alpha:]]+):\/\/.*$/$1/r;
	} elsif ($_[0] =~ m{^about:}) {
		return 'about';
	} elsif ($_[0] =~ m{^mailto:}) {
		return 'mailto';
	} elsif ($_[0] =~ m{://}) {		# '' ==  unsupported protocol
		return '';
	} elsif ($_[0] =~ m{^/}) {
		return 'root';
	} elsif ($_[0] =~ m{^[[:alnum:]]}) {
		return 'relative';
	} elsif ($_[0] =~ m{^\.}) {
		return 'relative';
	} else {
		return '';			# '' == unsupported protocol
	}
}

sub url2absolute {	# current URL, new (potentially relative) URL -> new absolute URL
	my $cururl = $_[0];
	my $newurl = $_[1];
	if (uri_class($newurl) eq 'root') {
		$newurl = "gemini://" . gem_host($cururl) . $newurl;
	} elsif (uri_class($newurl) eq 'relative') {
		my $curdir = $cururl;
		if ($curdir =~ m{://.+/}) {
			$curdir = substr($cururl, 0, rindex($cururl, '/'));
		}
		while ($newurl =~ m{^\.{1,2}/?}) {
			$newurl =~ s/^\.\///;
			if ($newurl =~ m{^\.\./?}) {
				$curdir =~ s/\/[^\/]*\/?$//;
				$newurl =~ s/^\.\.\/?//;
			}
		}
		if (not $newurl =~ m{^/} && not $curdir =~ m{/$}) {
			$newurl = $curdir . '/' . $newurl;
		} else {
			$newurl = $curdir . $newurl;
		}
	}
	return $newurl;		# no change if $newurl is already absolute
}

1;
