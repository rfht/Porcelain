package Porcelain::CursesUI;

use strict;
use warnings;

require Exporter;
our @ISA = qw(Exporter);
our @EXPORT = qw(c_err c_fullscr c_pad_str c_prompt_ch c_prompt_str c_statusline c_title_win c_warn clean_exit render hlsearch);

use Curses;
use Encode qw(encode);
use List::Util qw(min max);
use Porcelain::Format;
use Porcelain::Porcelain;

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
	my $prompt_pad = newpad(1, $Porcelain::Main::max_vcols);
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
	if (defined $Porcelain::Main::status_win) {
		delwin($Porcelain::Main::status_win);
	}
	$Porcelain::Main::status_win = newwin(0, 0, $LINES - 1, 0);
	bkgd($Porcelain::Main::status_win, COLOR_PAIR(2) | A_REVERSE);
	addstr($Porcelain::Main::status_win, $_[0]);
	refresh($Porcelain::Main::status_win);
}

sub c_title_win {	# modify $title_win. in: domainname
	my $sec_status = undef;
	if (defined $Porcelain::Main::host_cert) {
		# TODO: simplify the branching; find a way to combine the "red" results
		if (lc($Porcelain::Main::host_cert->fingerprint_sha256() =~ tr/://dr) eq $Porcelain::Main::kh_serv_hash) {
			if ($Porcelain::Main::kh_oob_hash) {
				if ($Porcelain::Main::kh_serv_hash eq $Porcelain::Main::kh_oob_hash) {			# green: all match
					bkgd($Porcelain::Main::title_win, COLOR_PAIR(4) | A_REVERSE);
					$sec_status = "Server identity verified on $Porcelain::Main::kh_oob_date";
				} else {						# red: kh_oob and kh_serv don't match
					bkgd($Porcelain::Main::title_win, COLOR_PAIR(7) | A_REVERSE);
					$sec_status = "SERVER IDENTITY MISMATCH (last update on $Porcelain::Main::kh_oob_date). CAUTION!";
				}
			} else {							# yellow: host_cert and kh_serv match; no oob
				bkgd($Porcelain::Main::title_win, COLOR_PAIR(1) | A_REVERSE);
				$sec_status = "TOFU okay; server identity not confirmed";
			}
		} else {
			bkgd($Porcelain::Main::title_win, COLOR_PAIR(7) | A_REVERSE);
			$sec_status = "SERVER CERT DOES NOT MATCH THE RECORDED CERT";
		}
	} else {
		# This is encountered if local file
		bkgd($Porcelain::Main::title_win, COLOR_PAIR(2) | A_REVERSE);
		$sec_status = "Local File";
	}
	clear($Porcelain::Main::title_win);
	addstr($Porcelain::Main::title_win, $Porcelain::Main::rq_addr . "\t" . $sec_status);
	refresh($Porcelain::Main::title_win);
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

sub hlsearch {	# highlight search match
	my ($ret, $searchstring) = @_;
	if (length($searchstring) > 0) {
		while ($ret =~ /$searchstring/i) {
			addstr($Porcelain::Main::win, substr($ret, 0, $-[0]));
			attron($Porcelain::Main::win, A_REVERSE);
			addstr($Porcelain::Main::win, substr($ret, $-[0], $+[0] - $-[0]));
			attroff($Porcelain::Main::win, A_REVERSE);
			$ret = substr($ret, $+[0]);
		}
	}
	return $ret;
}

sub render {	# viewfrom, viewto, text/gemini (as array of lines!) => formatted text (to outarray)
	# call with "gmirender $viewfrom, $viewto, \@array"
	my ($renderformat, $hpos, $hstop, $inarray, $links, $searchstr) = @_;
	my $line;
	my $t_list = 0;	# toggle list
	my $y;
	my $x;
	my $line_type;
	clear($Porcelain::Main::win);
	move($Porcelain::Main::win, 0, 0);	# keep space for title_win
	while ($hpos <= $hstop) {
		$line = ${$inarray}[$hpos++];
		if ($renderformat eq 'gemini') {
			$line_type = substr $line, 0, 1;	# extract the line type marker which is first char
			$line = substr $line, 1;
			if ($line_type eq '`' || $line_type eq '~') {			# Preformatted
				# TODO: handle alt text?
				attrset($Porcelain::Main::win, COLOR_PAIR(4));
			} elsif ($line_type eq '3' || $line_type eq 'C') {		# Heading 3
				attrset($Porcelain::Main::win, COLOR_PAIR(2));
				attron($Porcelain::Main::win, A_BOLD);
			} elsif ($line_type eq '2' || $line_type eq 'B') {		# Heading 2
				attrset($Porcelain::Main::win, COLOR_PAIR(2));
				attron($Porcelain::Main::win, A_BOLD);
				attron($Porcelain::Main::win, A_UNDERLINE);
			} elsif ($line_type eq '1' || $line_type eq 'A') {		# Heading 1
				$line = center_text $line;
				attrset($Porcelain::Main::win, COLOR_PAIR(2));
				attron($Porcelain::Main::win, A_BOLD);
			} elsif ($line_type eq '=') {					# Link
				# TODO: style links according to same domain vs. other gemini domains
				my ($li_num) = $line =~ /\[(\d+)\]/;
				$li_num = int($li_num - 1);	# zero based
				if (uri_class(${$links}[$li_num]) eq 'gemini' || uri_class(${$links}[$li_num]) eq 'relative' || uri_class(${$links}[$li_num]) eq 'root') {
					attrset($Porcelain::Main::win, COLOR_PAIR(5));	# cyan on black
				} elsif (Porcelain::Main::uri_class(${$links}[$li_num]) eq 'gopher') {
					attrset($Porcelain::Main::win, COLOR_PAIR(6));	# magenta on black
				} elsif (substr(Porcelain::Main::uri_class(${$links}[$li_num]), 0, 4) eq 'http') {
					attrset($Porcelain::Main::win, COLOR_PAIR(1));	# yellow on black
				} else {	# not sure what this is linking to
					attrset($Porcelain::Main::win, COLOR_PAIR(2));
				}
				attron($Porcelain::Main::win, A_UNDERLINE);
			} elsif ($line_type eq '+') {					# Continuation of Link
				attroff($Porcelain::Main::win, A_UNDERLINE);
				addstr($Porcelain::Main::win, $1);
				attron($Porcelain::Main::win, A_UNDERLINE);
				$line = $2;
			} elsif ($line_type eq '*') {			# Unordered List Item
				$line =~ s/^\*/-/;
				attrset($Porcelain::Main::win, COLOR_PAIR(2));
			} elsif ($line_type eq '-') {			# Unordered List Item (cont.)
				$line =~ s/^\-/ /;
				attrset($Porcelain::Main::win, COLOR_PAIR(2));
			} elsif ($line_type eq '>' || $line_type eq '<') {		# Quote
				attrset($Porcelain::Main::win, COLOR_PAIR(3));
			} elsif ($line_type eq ':' || $line_type eq ';') {		# Text line 
				attrset($Porcelain::Main::win, COLOR_PAIR(2));
			}
		}
		$line = encode('UTF-8', $line);
		$line = hlsearch $line, $searchstr;
		addstr($Porcelain::Main::win, $line);
		getyx($Porcelain::Main::win, $y, $x);
		move($Porcelain::Main::win, $y + 1, 0);
	}
	refresh($Porcelain::Main::win);
}

1;
