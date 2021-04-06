package Porcelain::Porcelain;

use strict;
use warnings;

require Exporter;
our @ISA = qw(Exporter);
our @EXPORT = qw(append_file gem_host lines readconf readtext sep uri_class url2absolute write_file);

sub gem_host {
	my $out = $_[0];
	$out = substr($out, 9) if substr($out, 0, 9) eq "gemini://";	# remove leading 'gemini://'
	$out =~ s|/.*|/|;
	return $out;
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
	my @r_array;
	open my $fh, '<', $_[0] or die "cannot open $_[0]";
	while (<$fh>) {
		chomp;
		push @r_array, $_;
	}
	close $fh;
	return @r_array;
}

sub append_file {	# append a line to a text file. params: filepath, textline --> return: 1 (success) or 0 (failure)
	my ($filepath, $textline) = @_;
	open my $fh, '>>', $filepath or return 0;
	print $fh $textline . "\n";
	close $fh;
	return 1;
}

sub write_file {	# write/replace a file. params: filepath, array to write linewise, bool raw (opt.) --> return: 1 (success) or 0 (failure)
	my $filepath = $_[0];
	my @w_array = @{$_[1]};
	my $raw;
	$_[2] ? $raw = ':raw' : $raw = '';
	open my $fh, ">$raw", $filepath or return 0;
	foreach my $line (@w_array) {
		print $fh $line . "\n";
	}
	close $fh;
	return 1;
}

sub sep {	# gmi string containing whitespace --> ($first, $rest)
	my $first =	$_[0] =~ s/[[:blank:]].*$//r;
	my $rest =	$_[0] =~ s/^[^[:blank:]]*[[:blank:]]*//r;
	return wantarray ? ($first, $rest) : $first;
}

# TODO: can this be simplified/replaced?
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
	my $cur = $_[0];
	my $new = $_[1];
	if (uri_class($new) eq 'root') {
		$new = "gemini://" . gem_host($cur) . $new;
	} elsif (uri_class($new) eq 'relative') {
		$cur =~ s|/[^/]*$|/|;
		$new = $cur . $new;
		$new =~ s|/[^/]+/\.\./|/|g;		# process '..' as up in url hierarchy
		$new =~ s|/\./|/|g;			# strip '.' in url
	}
	return $new;
}

1;
