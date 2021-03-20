package Porcelain::Porcelain;

use strict;
use warnings;

require Exporter;
our @ISA = qw(Exporter);
our @EXPORT = qw(caught_sigint);

sub caught_sigint {
	Porcelain::CursesUI::clean_exit "Caught SIGINT - aborting...";
}

1;
