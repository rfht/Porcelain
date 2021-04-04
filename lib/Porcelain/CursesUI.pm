package Porcelain::CursesUI;

use strict;
use warnings;

require Exporter;
our @ISA = qw(Exporter);
our @EXPORT = qw(c_err c_fullscr c_pad_str c_prompt_ch c_prompt_str
		c_statusline c_title_win c_warn caught_sigint clean_exit
		downloader hlsearch
		init_cursesui render $main_win $status_win $title_win
);

use Curses;
use Encode qw(encode);
use List::Util qw(max);
use Porcelain::Format;
use Porcelain::Porcelain;

our $main_win;
our $title_win;
our $status_win;

use constant MAX_VROWS => 1024 * 1024;	# max virtual rows used in curses pads
use constant MAX_VCOLS => 1024;		# maximum virtual columns used in curses pads

sub clean_exit {
	delwin($main_win);
	delwin($title_win);
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
		addstr($fullscr, center_text($_[1]));
		attroff($fullscr, A_BOLD);
		getyx($fullscr, my $y, my $x);
		move($fullscr, $y + 2, 0);
	}
	addstr($fullscr, $_[0]);
	refresh($fullscr);
	return $fullscr;
}

sub c_prompt_str {	# Curses prompt for string: prompt string --> user string
	my $prompt_win = newwin(0,0,$LINES - 1, 0);
	bkgd($prompt_win, COLOR_PAIR(2) | A_REVERSE);
	addstr($prompt_win, $_[0]);
	refresh($prompt_win);
	echo;
	my $s = getstring($prompt_win);
	noecho;
	delwin($prompt_win);
	return $s;
}

sub c_pad_str {	# PADDED Curses prompt for string: prompt string --> user string
	# TODO: allow backspace etc
	my $prompt_pad = newpad(1, MAX_VCOLS);
	bkgd($prompt_pad, COLOR_PAIR(2) | A_REVERSE);
	addstr($prompt_pad, $_[0]);
	prefresh($prompt_pad, 0, 0, $LINES - 1, 0, $LINES - 1, $COLS - 1);
	my $s = '';
	while (1) {
		my $c = getch;
		if (ord($c) == 13) {
			last;
		}
		$s .= $c;
		addch($prompt_pad, $c);
		prefresh($prompt_pad, 0, max(length($_[0]) + length($s) - $COLS, 0), $LINES - 1, 0, $LINES - 1, $COLS - 1);
	}
	delwin($prompt_pad);
	return $s;
}

sub c_prompt_ch {	# Curses prompt for char: prompt char --> user char
	my $prompt_win = newwin(0,0,$LINES - 1, 0);
	bkgd($prompt_win, COLOR_PAIR(2) | A_REVERSE);
	addstr($prompt_win, $_[0]);
	refresh($prompt_win);
	echo;
	my $c = getchar($prompt_win);
	flushinp;
	noecho;
	delwin($prompt_win);
	return $c;
}

sub c_statusline {	# Curses status line. Stays until refresh. Status text --> undef
	if (defined $status_win) {
		delwin($status_win);
	}
	$status_win = newwin(0, 0, $LINES - 1, 0);
	bkgd($status_win, COLOR_PAIR(2) | A_REVERSE);
	addstr($status_win, $_[0]);
	refresh($status_win);
}

sub c_title_win {	# modify $title_win. in: domainname
	my ($x509, $addr, $valcert, $valdate) = @_;
	my $sec_status = undef;
	if (defined $x509) {
		if ($valcert == 3) {
			bkgd($title_win, COLOR_PAIR(4) | A_REVERSE);
			$sec_status = "Server identity verified on $valdate";
		} elsif ($valcert == 2) {
			bkgd($title_win, COLOR_PAIR(1) | A_REVERSE);
			$sec_status = "TOFU okay; known since: $valdate";
		} elsif ($valcert == 1) {
			bkgd($title_win, COLOR_PAIR(1) | A_REVERSE);
			$sec_status = "New/unknown server";
		} elsif ($valcert == 0) {
			bkgd($title_win, COLOR_PAIR(7) | A_REVERSE);
			$sec_status = "SERVER CERT DOES NOT MATCH THE RECORDED CERT";
		} else {	# should not be reached
			die "invalid return status when trying to validate certificate";
		}
	} else {
		# This is encountered if local file
		bkgd($title_win, COLOR_PAIR(2) | A_REVERSE);
		$sec_status = "Local File";
	}
	clear($title_win);
	addstr($title_win, $addr . "\t" . $sec_status);
	refresh($title_win);
}

sub c_warn {	# Curses warning: prompt char, can be any key --> user char
	my $prompt_win = newwin(0,0,$LINES - 1, 0);
	bkgd($prompt_win, COLOR_PAIR(1) | A_REVERSE);
	addstr($prompt_win, $_[0]);
	refresh($prompt_win);
	echo;
	my $c = getchar($prompt_win);
	noecho;
	delwin($prompt_win);
	return $c;
}

sub c_err {	# Curses error: prompt char, can be any key --> user char
	my $prompt_win = newwin(0,0,$LINES - 1, 0);
	bkgd($prompt_win, COLOR_PAIR(7) | A_REVERSE);
	addstr($prompt_win, $_[0]);
	refresh($prompt_win);
	echo;
	my $c = getchar($prompt_win);
	noecho;
	delwin($prompt_win);
	return $c;
}

sub caught_sigint {
	clean_exit "Caught SIGINT - aborting...";
}

sub downloader {	# $url, $body --> 0: success, >0: failure
	# TODO: add timeout; progress bar
	my ($dlurl, $dlcont) = @_;
	my $dl_file = $dlurl =~ s|^.*/||r;
	$dl_file = $ENV{'HOME'} . "/Downloads/" . $dl_file;
	c_prompt_ch "Downloading $dlurl ...";
	open my $fh, '>:raw', $dl_file or clean_exit "error opening $dl_file for writing";
	binmode($fh);
	print $fh $dlcont or clean_exit "error writing to file $dl_file";
	close $fh;
	return 0;
}

sub hlsearch {	# highlight search match
	my ($ret, $searchstring) = @_;
	if (length($searchstring) > 0) {
		while ($ret =~ /$searchstring/i) {
			addstr($main_win, substr($ret, 0, $-[0]));
			attron($main_win, A_REVERSE);
			addstr($main_win, substr($ret, $-[0], $+[0] - $-[0]));
			attroff($main_win, A_REVERSE);
			$ret = substr($ret, $+[0]);
		}
	}
	return $ret;
}

sub init_cursesui {
	initscr;
	start_color;	# TODO: check if (has_colors)
	$title_win = newwin(1, 0, 0, 0);
	$main_win = newwin(0,0,1,0);
	refresh;
	noecho;
	nonl;
	cbreak;
	keypad(1);
	curs_set(0);
	init_pair(1, COLOR_YELLOW, COLOR_BLACK);
	init_pair(2, COLOR_WHITE, COLOR_BLACK);
	init_pair(3, COLOR_BLUE, COLOR_BLACK);
	init_pair(4, COLOR_GREEN, COLOR_BLACK);
	init_pair(5, COLOR_CYAN, COLOR_BLACK);
	init_pair(6, COLOR_MAGENTA, COLOR_BLACK);
	init_pair(7, COLOR_RED, COLOR_WHITE);
}

sub render {	# viewfrom, viewto, text/gemini (as array of lines!) => formatted text (to outarray)
	# call with "gmirender $viewfrom, $viewto, \@array"
	my ($renderformat, $hpos, $hstop, $inarray, $links, $searchstr) = @_;
	my $line;
	my $t_list = 0;	# toggle list
	my $y;
	my $x;
	my $line_type;
	clear($main_win);
	move($main_win, 0, 0);	# keep space for title_win
	while ($hpos <= $hstop) {
		$line = ${$inarray}[$hpos++];
		if ($renderformat eq 'gemini') {
			$line_type = substr $line, 0, 1;	# extract the line type marker which is first char
			$line = substr $line, 1;
			if ($line_type eq '`' || $line_type eq '~') {			# Preformatted
				# TODO: handle alt text?
				attrset($main_win, COLOR_PAIR(4));
			} elsif ($line_type eq '3' || $line_type eq 'C') {		# Heading 3
				attrset($main_win, COLOR_PAIR(2));
				attron($main_win, A_BOLD);
			} elsif ($line_type eq '2' || $line_type eq 'B') {		# Heading 2
				attrset($main_win, COLOR_PAIR(2));
				attron($main_win, A_BOLD);
				attron($main_win, A_UNDERLINE);
			} elsif ($line_type eq '1' || $line_type eq 'A') {		# Heading 1
				$line = center_text $line;
				attrset($main_win, COLOR_PAIR(2));
				attron($main_win, A_BOLD);
			} elsif ($line_type eq '=') {					# Link
				# TODO: style links according to same domain vs. other gemini domains
				my ($li_num) = $line =~ /\[(\d+)\]/;
				$li_num = int($li_num - 1);	# zero based
				if (uri_class(${$links}[$li_num]) eq 'gemini' || uri_class(${$links}[$li_num]) eq 'relative' || uri_class(${$links}[$li_num]) eq 'root') {
					attrset($main_win, COLOR_PAIR(5));	# cyan on black
				} elsif (uri_class(${$links}[$li_num]) eq 'gopher') {
					attrset($main_win, COLOR_PAIR(6));	# magenta on black
				} elsif (substr(uri_class(${$links}[$li_num]), 0, 4) eq 'http') {
					attrset($main_win, COLOR_PAIR(1));	# yellow on black
				} else {	# not sure what this is linking to
					attrset($main_win, COLOR_PAIR(2));
				}
				attron($main_win, A_UNDERLINE);
			} elsif ($line_type eq '+') {					# Continuation of Link
				attroff($main_win, A_UNDERLINE);
				addstr($main_win, $1);
				attron($main_win, A_UNDERLINE);
				$line = $2;
			} elsif ($line_type eq '*') {			# Unordered List Item
				$line =~ s/^\*/-/;
				attrset($main_win, COLOR_PAIR(2));
			} elsif ($line_type eq '-') {			# Unordered List Item (cont.)
				$line =~ s/^\-/ /;
				attrset($main_win, COLOR_PAIR(2));
			} elsif ($line_type eq '>' || $line_type eq '<') {		# Quote
				attrset($main_win, COLOR_PAIR(3));
			} elsif ($line_type eq ':' || $line_type eq ';') {		# Text line 
				attrset($main_win, COLOR_PAIR(2));
			}
		}
		$line = encode('UTF-8', $line);
		$line = hlsearch $line, $searchstr;
		addstr($main_win, $line);
		getyx($main_win, $y, $x);
		move($main_win, $y + 1, 0);
	}
	refresh($main_win);
}

1;
