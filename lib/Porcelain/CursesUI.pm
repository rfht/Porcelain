package Porcelain::CursesUI;

use strict;
use warnings;

require Exporter;
our @ISA = qw(Exporter);
our @EXPORT = qw(c_fullscr clean_exit);

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

sub c_fullscr {		# Curses fullscreen display; DOESN'T SCROLL! (TODO) --> return user key;
	# NOTE: delwin needs to be called outside!
	my $fullscr = newwin(0, 0, 0, 0);
	if (defined $_[1]) {
		attrset($fullscr, COLOR_PAIR(2));
		attron($fullscr, A_BOLD);
		addstr($fullscr, Porcelain::Main::center_text($_[1]));
		attroff($fullscr, A_BOLD);
		getyx($fullscr, my $y, my $x);
		move($fullscr, $y + 2, 0);
	}
	addstr($fullscr, $_[0]);
	refresh($fullscr);
	return $fullscr;
}

1;
