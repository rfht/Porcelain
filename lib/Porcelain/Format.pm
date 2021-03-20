package Porcelain::Format;

use strict;
use warnings;

require Exporter;
our @ISA = qw(Exporter);
our @EXPORT = qw(center_text);

use Curses;	# for $COLS

sub center_text {	# string --> string with leading space to position in center of terminal
	my $str = $_[0];
	my $colcenter = int($COLS / 2);
	my $strcenter = int(length($str) / 2);
	my $adjust = $colcenter - $strcenter;	# amount of space to move string by: $center - half the length of the string
	return (" " x $adjust) . $str;
}

1;
