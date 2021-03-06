package Porcelain::Format;

use strict;
use warnings;

require Exporter;
our @ISA = qw(Exporter);
our @EXPORT = qw(center_text gmiformat plainformat preformat_linklist);

use Curses;	# for $COLS	# TODO: find a more lightweight way to get $COLS
use Porcelain::Porcelain;	# for sep
use Text::CharWidth qw(mbswidth);
use Text::Wrap;

our %line_prefixes = (
	'`' => '',	# preformatted
	'~' => '',	# preformatted cont.
	'1' => '',	# heading1
	'A' => '',	# heading1 cont.
	'2' => '',	# heading2
	'B' => '',	# heading2 cont.
	'3' => '',	# heading3
	'C' => '',	# heading3 cont.
	'=' => '=> ',	# link
	'+' => '   ',	# link cont.
	'*' => '- ',	# item
	'-' => '  ',	# item cont.
	'>' => '> ',	# quote
	'<' => '  ',	# quote cont.
	':' => '',	# text
	';' => '',	# text cont.
);

sub center_text {	# string --> string with leading space to position in center of terminal
	my $str = $_[0];
	my $colcenter = int($COLS / 2);
	my $strcenter = int(length($str) / 2);
	my $adjust = $colcenter - $strcenter;	# amount of space to move string by: $center - half the length of the string
	return (" " x $adjust) . $str;
}

# format $line by breaking it into multiple line if needed. $p1 and $p2 are the
# prefixes added to the first and the following lines respectively.
sub fmtline {
	my ($line, $outarray, $p1, $p2, $extra) = @_;
	$extra = '' unless $extra;
	$p1 = $p1 || '';
	$p2 = $p2 || '';
	my $cols = $COLS - 1 - length($line_prefixes{$p1});
	if (mbswidth($extra . $line) > $cols) {
		$Text::Wrap::columns = $cols;
		$line = wrap($p1 . $extra, $p2 . $extra, $line);
		push @$outarray, split("\n", $line);
	} else {
		push @$outarray, $p1 . $extra . $line;
	}
}

sub plainformat {	# format plaintext for screen
	my ($inarray, $outarray) = @_;
	foreach (@$inarray) {
		fmtline($_, $outarray);
	}
}

sub gmiformat {	# break down long lines, space correctly: inarray  => outarray (with often different number of lines)
		# ANYTHING that affects the number of lines to be rendered needs to be decided here!
	my ($inarray, $outarray, $linkarray) = @_;
	undef @$outarray;
	undef @$linkarray;
	my $t_preform = 0;
	my $num_links = 0;
	foreach (@$inarray) {
		if ($_ =~ /^```/) {
			$t_preform = not $t_preform;
		} elsif ($t_preform) {	# preformatted text. Don't mess it up.
			# TODO: use e.g. pad to allow lateral scrolling?
			my $line = $_;
			if (mbswidth($line) > $COLS) {
				$Text::Wrap::columns = $COLS;
				$line = wrap('`', '~', $line);
				$line = (split("\n", $line))[0];
			}
			fmtline($line, $outarray, '`', '~');
		} else {
			# TODO: transform tabs into single space?
			# TODO: collapse multiple blank chars (e.g. '  ') into a single space?
			# TODO: add blank line after all headers and changes in content type
			# TODO: find multiple serial empty lines and transform into just one?
			my $line = $_ =~ s/\s*$//r;	# bye bye trailing whitespace TODO: apply to all lines incl preformatted?
			if ($line =~ /^###\s*[^\s]/) {		# Heading 3	# are there any characters to print at all?
				fmtline($line =~ s/^###\s*//r, $outarray, '3', 'C');
			} elsif ($line =~ /^##\s*[^\s]/) {	# Heading 2
				fmtline($line =~ s/^##\s*//r, $outarray, '2', 'B');
			} elsif ($line =~ /^#\s*[\s]/) {	# Heading 1
				fmtline($line =~ s/^#\s*//r, $outarray, '1', 'A');
			} elsif ($line =~ /^=>/) {		# Link
				$num_links++;
				$line =~ s/^=>\s*//;
				my ($link_url, $link_descr) = sep $line;
				push @$linkarray, $link_url;
				if ($link_descr =~ /^\s*$/) {	# if $link_descr is empty, use $link_url
					$line = $link_url;
				} else {
					$line = $link_descr;
				}
				my $p = "=>[" . $num_links . "] ";
				$line = "[" . $num_links . "] " . $line;
				fmtline($line, $outarray, '=', '+');
			} elsif ($line =~ /^\* /) {		# Unordered List
				fmtline($line =~ s/^\*\s+//r, $outarray, '*', '-');
			} elsif ($line =~ /^>/) {		# Quote
				fmtline($line =~ s/^>\s*//r, $outarray, '>', '<');
			} else {				# Regular Text
				fmtline($line =~ s/^\s*//r, $outarray, ':', ';');
			}
		}
	}
}

sub preformat_linklist {	# preformat resources for display in about:... inarray --> outarray
	my $inarray = $_[0];
	${$inarray}[0] = "# " . ${$inarray}[0];	# First line is the page title
	splice @$inarray, 1, 0, "";
	foreach(@$inarray[2..scalar(@$inarray) - 1]) {
		$_ = "=> " . $_;
	}
}

1;
