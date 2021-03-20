package Porcelain::CursesUI;

use strict;
use warnings;

require Exporter;
our @ISA = qw(Exporter);
our @EXPORT_OK = qw(clean_exit);

use Curses;

sub clean_exit {
	delwin($Porcelain::Main::win);
	delwin($Porcelain::Main::title_win);
	endwin;
	if ($_[0]) {
		print $_[0] . "\n";
	}
	exit;
}

1;
