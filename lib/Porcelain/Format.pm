package Porcelain::Format;

use strict;
use warnings;

require Exporter;
our @ISA = qw(Exporter);
our @EXPORT = qw(center_text gmiformat preformat_linklist);

use Curses;	# for $COLS
use Text::CharWidth qw(mbswidth);
use Text::Wrap;

sub center_text {	# string --> string with leading space to position in center of terminal
	my $str = $_[0];
	my $colcenter = int($COLS / 2);
	my $strcenter = int(length($str) / 2);
	my $adjust = $colcenter - $strcenter;	# amount of space to move string by: $center - half the length of the string
	return (" " x $adjust) . $str;
}

# format $line by breaking it into multiple line if needed.  $extra is
# the length of the prepended string when rendered, $p1 and $p2 the
# prefixes added to the first and the following lines respectively.
sub fmtline {
	my ($line, $outarray, $extra, $p1, $p2) = @_;
	my $prefix = $p1 || '';
	my $cols = $COLS + $extra;

	if (mbswidth($line) + $extra > $cols) {
		$Text::Wrap::columns = $cols;
		$line = wrap($p1 || '', $p2 || $p1 || '', $line);
		push @$outarray, split("\n", $line);
	} else {
		push @$outarray, $prefix . $line;	# needed to not kill empty lines
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
			next;
		}
		if ($t_preform) {	# preformatted text. Don't mess it up.
			# TODO: use e.g. pad to allow lateral scrolling?
			my $line = $_;
			if (mbswidth($line) > $COLS) {
				$Text::Wrap::columns = $COLS;
				$line = wrap('', '', $line);
				$line = (split("\n", $line))[0];
			}
			push @$outarray, "```" . $line;
		} else {
			# TODO: transform tabs into single space?
			# TODO: collapse multiple blank chars (e.g. '  ') into a single space?
			# TODO: add blank line after all headers and changes in content type
			# TODO: find multiple serial empty lines and transform into just one?
			my $line = $_ =~ s/\s*$//r;	# bye bye trailing whitespace TODO: apply to all lines incl preformatted?
			if ($line =~ /^###\s*[^\s]/) {		# Heading 3	# are there any characters to print at all?
				fmtline($line =~ s/^###\s*//r, $outarray, 0, '###');
			} elsif ($line =~ /^##\s*[^\s]/) {	# Heading 2
				fmtline($line =~ s/^##\s*//r, $outarray, 0, '##');
			} elsif ($line =~ /^#\s*[\s]/) {	# Heading 1
				fmtline($line =~ s/^#\s*//r, $outarray, 0, '#');
			} elsif ($line =~ /^=>/) {		# Link
				$num_links++;
				$line =~ s/^=>\s*//;
				my ($link_url, $link_descr) = Porcelain::Porcelain::sep $line;
				push @$linkarray, $link_url;
				if ($link_descr =~ /^\s*$/) {	# if $link_descr is empty, use $link_url
					$line = $link_url;
				} else {
					$line = $link_descr;
				}
				my $p = "=>[" . $num_links . "] ";
				fmtline($line, $outarray, length($p) - 4, $p, '=>' . ' ' x (length($p) - 2));
			} elsif ($line =~ /^\* /) {		# Unordered List
				fmtline($line =~ s/^\*\s+//r, $outarray, 0, '* ', '**');
			} elsif ($line =~ /^>/) {		# Quote
				fmtline($line =~ s/^>\s*//r, $outarray, 0, '> ');
			} else {				# Regular Text
				fmtline($line =~ s/^\s*//r, $outarray, 0);
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
