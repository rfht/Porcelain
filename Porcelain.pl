#!/usr/bin/env perl

# Copyright (c) 2021 Thomas Frohwein
#
# Permission to use, copy, modify, and distribute this software for any
# purpose with or without fee is hereby granted, provided that the above
# copyright notice and this permission notice appear in all copies.
#
# THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
# WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
# MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
# ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
# WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
# ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
# OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.

# TODO:
# - look up pledge and unveil examples and best practices
# - keep testing with gemini://gemini.conman.org/test/torture/
# - search "TODO" in comments
# - import perl modules in mystuff/misc to ports
# - check number of terminal columns and warn if too few (< 80) ?
# - intercept Ctrl-C and properly exit when it's pressed
# - limit size of history; can be configurable in whatever config approach is later chosen
# - remove problematic unveils, e.g. /bin/sh that could be used to do almost anything
# - implement a hotkey to view history
# - implement subscribed option
# - mandate 1 and only 1 empty line after all headers?
# - implement a way to handle image and audio file links, e.g. on gemini://chriswere.uk/trendytalk/
# - allow theming (colors etc) via a config file?
# - see if some Perl modules may not be needed
# - review error handling - may not always need 'die'. Create a way to display warnings uniformly?
# - if going back in history, don't add link to the end of history
# - add option for "Content Warning" type use of preformatted text and alt text:
#	https://dragonscave.space/@devinprater/105782591455644854
# - adjust output size when terminal is resized
# - implement logging messages, warnings, errors to file
# - center preformatted text? at least if marked as ascii art?

use strict;
use warnings;
use feature 'unicode_strings';
package Porcelain::Main;

use Crypt::OpenSSL::X509;
use Curses;
use DateTime;
use DateTime::Format::x509;	# TODO: lots of dependencies. Find a less bulky alternative.
#use IO::Select;					# https://stackoverflow.com/questions/33973515/waiting-for-a-defined-period-of-time-for-the-input-in-perl
use List::Util qw(min max);
require Net::SSLeay;					# p5-Net-SSLeay
use OpenBSD::Pledge;					# OpenBSD::Pledge(3p)
use OpenBSD::Unveil;					# OpenBSD::Unveil(3p)
use Pod::Usage;
use utf8;						# TODO: really needed?

# Curses init
initscr;
start_color;	# TODO: check if (has_colors)
my $win = newwin(0,0,0,0);
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

my $url;
my @history;
my $history_pointer = 0;
my %open_with;
my @links;		# array containing links in the pages

my $redirect_count = 0;
my $redirect_max = 5;	# TODO: allow setting this in the config

my $porcelain_dir = $ENV{'HOME'} . "/.porcelain";
if (! -d $porcelain_dir) {
	mkdir $porcelain_dir || die "Unable to create $porcelain_dir";
}
my $hosts_file = $porcelain_dir . "/known_hosts";
my @known_hosts;
if (-e $hosts_file) {
	my $raw_hosts;
	open(my $fh, '<', $hosts_file) or die "cannot open $hosts_file";
	{
		local $/;
		$raw_hosts = <$fh>;
	}
	close($fh);
	@known_hosts = split('\n', $raw_hosts);
}

sub clean_exit {
	endwin;
	# TODO: clear screen on exit? ($scr->clrscr())
	#	Or just clear the last line at the bottom?
	if ($_[0]) {
		print $_[0] . "\n";
	}
	exit;
}

sub uri_class {	# URL string --> string of class ('gemini', 'https', etc.)
	if ($_[0] =~ m{^[[:alpha:]]+://}) {
		return $_[0] =~ s/^([[:alpha:]]+):\/\/.*$/$1/r;
	} elsif ($_[0] =~ m{^mailto:}) {
		return 'mailto';
	} elsif ($_[0] =~ m{://}) {		# unsupported protocol
		return '';
	} elsif ($_[0] =~ m{^/}) {
		return 'relative';
	} elsif ($_[0] =~ m{^[[:alnum:]]}) {
		return 'relative';
	} elsif ($_[0] =~ m{^\.}) {
		return 'relative';
	} else {
		return '';			# unsupported protocol
	}
}

sub c_prompt_str {	# Curses prompt for string: prompt string --> user string
	my $prompt_win = newwin(0,0,$LINES - 1, 0);
	bkgd($prompt_win, COLOR_PAIR(2) | A_REVERSE);
	addstr($prompt_win, $_[0]);
	refresh($prompt_win);
	echo;
	curs_set(1);
	my $s = getstring($prompt_win);
	noecho;
	curs_set(0);
	return $s;
}

sub c_prompt_ch {	# Curses prompt for char: prompt char --> user char
	my $prompt_win = newwin(0,0,$LINES - 1, 0);
	bkgd($prompt_win, COLOR_PAIR(2) | A_REVERSE);
	addstr($prompt_win, $_[0]);
	refresh($prompt_win);
	echo;
	curs_set(1);
	my $c = getchar($prompt_win);
	noecho;
	curs_set(0);
	return $c;
}

sub c_warn {	# Curses warning: prompt char, can be any key --> user char
	my $prompt_win = newwin(0,0,$LINES - 1, 0);
	bkgd($prompt_win, COLOR_PAIR(1) | A_REVERSE);
	addstr($prompt_win, $_[0]);
	refresh($prompt_win);
	echo;
	curs_set(1);
	my $c = getchar($prompt_win);
	noecho;
	curs_set(0);
	return $c;
}

sub center_text {	# string --> string with leading space to position in center of terminal
	my $str = $_[0];
	my $colcenter = int($COLS / 2);
	my $strcenter = int(length($str) / 2);
	my $adjust = $colcenter - $strcenter;	# amount of space to move string by: $center - half the length of the string
	return (" " x $adjust) . $str;
}

sub expand_url {	# current URL, new (potentially relative) URL -> new absolute URL
			# no change if $newurl is already absolute
	my $cururl = $_[0];
	my $newurl = $_[1];
	if (uri_class($newurl) eq 'relative') {
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
	return $newurl;
}

sub gem_host {
	my $input = $_[0];
	my $out = substr $input, 9;	# remove leading 'gemini://'
	$out =~ s|/.*||;
	return $out;
}

sub sep {	# gmi string containing whitespace --> ($first, $rest)
	# TODO: is leading whitespace allowed in the spec at all?
	# Note this function applies to both text/gemini (links, headers, unordered list, quote)
	my $first =	$_[0] =~ s/[[:blank:]].*$//r;
	my $rest =	$_[0] =~ s/^[^[:blank:]]*[[:blank:]]*//r;
	return ($first, $rest);
}

sub lines {	# multi-line text scalar --> $first_line / @lines
	my @lines = (split /\n/, $_[0]);
	return wantarray ? @lines : $lines[0];
}

sub gmiformat {	# break down long lines, space correctly: inarray  => outarray (with often different number of lines)
		# ANYTHING that affects the number of lines to be rendered needs to be decided here!
	my $inarray = $_[0];
	my $outarray = $_[1];
	my $linkarray = $_[2];
	undef @$outarray;
	undef @$linkarray;
	my $t_preform = 0;
	my $line;
	my $link_url;
	my $link_descr;
	my $num_links = 0;
	my $splitpos;
	foreach (@$inarray) {
		undef $splitpos;
		if ($_ =~ /^```/) {
			$t_preform = not $t_preform;
			next;
		}
		if ($t_preform) {	# preformatted text. Don't format.
			$line = "```" . $_;	# TODO: Truncate to $COLS? This breaks hexdsl.co.uk ASCII art. use e.g. pad to allow lateral scrolling?
		} else {
			# TODO: transform tabs into single space?
			# TODO: collapse multiple blank chars (e.g. '  ') into a single space?
			# TODO: add blank line after all headers and changes in content type
			$line = $_ =~ s/\s*$//r;	# bye bye trailing whitespace TODO: apply to all lines incl preformatted?
			if ($line =~ /^###\s*[^\s]/) {		# Heading 3	# are there any characters to print at all?
				$line =~ s/^###\s*//;
				while (length($line) > $COLS) {
					$splitpos = rindex($line, ' ', $COLS - 1);
					push @$outarray, "###" . substr($line, 0, $splitpos);
					$line = substr($line, $splitpos + 1);
				}
				$line = "###" . $line;
			} elsif ($line =~ /^##\s*[^\s]/) {	# Heading 2
				$line =~ s/^##\s*//;
				while (length($line) > $COLS) {
					$splitpos = rindex($line, ' ', $COLS - 1);
					push @$outarray, "##" . substr($line, 0, $splitpos);
					$line = substr($line, $splitpos + 1);
				}
				$line = "##" . $line;
			} elsif ($line =~ /^#\s*[\s]/) {	# Heading 1
				$line =~ s/^#\s*//;
				while (length($line) > $COLS) {
					$splitpos = rindex($line, ' ', $COLS - 1);
					push @$outarray, "#" . substr($line, 0, $splitpos);
					$line = substr($line, $splitpos + 1);
				}
				$line = "#" . $line;
			} elsif ($line =~ /^=>\s/) {		# Link
				$num_links++;
				$line =~ s/^=>\s+//;
				($link_url, $link_descr) = sep $line;
				push @$linkarray, $link_url;
				if ($link_descr =~ /^\s*$/) {	# if $link_descr is empty, use $link_url
					$line = $link_url;
				} else {
					$line = $link_descr;
				}
				$line = "=>[" . $num_links . "] " . $line;	# No length check. Should NOT be wrapped.
			} elsif ($line =~ /^\* /) {		# Unordered List
				$line =~ s/^\*\s+/* /;
				while (length($line) > $COLS) {
					$splitpos = rindex($line, ' ', $COLS - 1);
					push @$outarray, substr($line, 0, $splitpos);
					# TODO: ensure no whitespace after '**'
					$line = "**" . substr($line, $splitpos + 1);	# '**' is the marker for continuation of same unordered list item. TODO: is there a better one to avoid conflicts with other text?
				}
			} elsif ($line =~ /^>/) {		# Quote
				$line =~ s/^>\s*/> /;
				while (length($line) > $COLS) {
					$splitpos = rindex($line, ' ', $COLS - 1);
					push @$outarray, substr($line, 0, $splitpos);
					$line = "> " . substr($line, $splitpos + 1);
				}
			} else {				# Regular Text
				$line =~ s/^\s*//;	# remove leading whitespace
				while (length($line) > $COLS) {
					$splitpos = rindex($line, ' ', $COLS - 1);
					push @$outarray, substr($line, 0, $splitpos);
					$line = substr($line, $splitpos + 1);
				}
			}
		}
		push @$outarray, $line;
	}
}

sub gmirender {	# viewfrom, viewto, text/gemini (as array of lines!) => formatted text (to outarray)
	# call with "gmirender $viewfrom, $viewto, \@array"
	my $hpos = $_[0];
	my $hstop = $_[1];
	my $inarray = $_[2];
	my $line;
	my $t_list = 0;	# toggle list
	my $y;
	my $x;
	clear;
	move(0, 0);
	while ($hpos <= $hstop) {
		$line = ${$inarray}[$hpos++];
		if ($t_list && not $line =~ /^\*\*/) {
			$t_list = not $t_list;		# unordered list has not been continued. Reset the toggle.
		}
		if ($line =~ /^```/) {				# Preformatted
			# TODO: handle alt text?
			$line = substr $line, 3;
			attrset(COLOR_PAIR(4));
			getyx($y, $x);
			addstr($y, $x, $line);
			move($y + 1, 0);
		} elsif ($line =~ /^###/) {			# Heading 3
			$line = substr $line, 3;
			attrset(COLOR_PAIR(2));
			attron(A_BOLD);
			getyx($y, $x);
			addstr($y, $x, $line);
			move($y + 1, 0);
		} elsif ($line =~ /^##/) {			# Heading 2
			$line = substr $line, 2;
			attrset(COLOR_PAIR(2));
			attron(A_BOLD);
			attron(A_UNDERLINE);
			getyx($y, $x);
			addstr($y, $x, $line);
			move($y + 1, 0);
		} elsif ($line =~ /^#/) {			# Heading 1
			$line = substr $line, 1;
			$line = center_text $line;
			attrset(COLOR_PAIR(1));
			attron(A_BOLD);
			getyx($y, $x);
			addstr($y, $x, $line);
			move($y + 1, 0);
		} elsif ($line =~ /^=>/) {			# Link
			# TODO: style links according to same domain vs. other gemini domain vs. http[,s] vs. gopher
			# TODO: links should NOT be wrapped!!!
			$line = substr $line, 2;
			my @line_split = split(" ", $line);
			my $link_index = shift @line_split;
			my $li_num = $link_index;
			$li_num =~ tr/\[\]//d;
			$li_num = int($li_num - 1);	# zero based
			if (uri_class($links[$li_num]) eq 'gemini' || uri_class($links[$li_num]) eq 'relative') {
				attrset(COLOR_PAIR(5));	# cyan on black
			} elsif (uri_class($links[$li_num]) eq 'gopher') {
				attrset(COLOR_PAIR(6));	# magenta on black
			} elsif (substr(uri_class($links[$li_num]), 0, 4) eq 'http') {
				attrset(COLOR_PAIR(1));	# yellow on black
			} else {	# not sure what this is linking to
				attrset(COLOR_PAIR(2));
			}
			attroff(A_BOLD);
			getyx($y, $x);
			addstr($y, $x, $link_index . " ");
			attron(A_UNDERLINE);
			getyx($y, $x);
			addstr($y, $x, join(" ", @line_split));
			attroff(A_UNDERLINE);
			move($y + 1, 0);
		} elsif ($line =~ /^\* /) {			# Unordered List Item
			$line =~ s/^\*/-/;
			$t_list = 1;
			attrset(COLOR_PAIR(2));
			getyx($y, $x);
			addstr($y, $x, $line);
			move($y + 1, 0);
		} elsif ($line =~ /^\*\*/ && $t_list) {		# Continuation of List Item
			$line =~ s/^\*\*/  /;
			attrset(COLOR_PAIR(2));
			getyx($y, $x);
			addstr($y, $x, $line);
			move($y + 1, 0);
		} elsif ($line =~ /^>/) {			# Quote
			attrset(COLOR_PAIR(3));
			getyx($y, $x);
			addstr($y, $x, $line);
			move($y + 1, 0);
		} else {					# Text line
			attrset(COLOR_PAIR(2));
			getyx($y, $x);
			addstr($y, $x, $line);
			move($y + 1, 0);
		}
	}
}

# see sslcat in /usr/local/libdata/perl5/site_perl/amd64-openbsd/Net/SSLeay.pm
# TODO: rewrite/simplify sslcat_custom
sub sslcat_custom { # address, port, message, $crt, $key --> reply / (reply,errs,cert)
	my ($dest_serv, $port, $out_message, $crt_path, $key_path) = @_;
	my ($ctx, $ssl, $got, $errs, $written);

	($got, $errs) = Net::SSLeay::open_proxy_tcp_connection($dest_serv, $port);
	return (wantarray ? (undef, $errs) : undef) unless $got;

	### SSL negotiation
	$ctx = Net::SSLeay::new_x_ctx();
	goto cleanup2 if $errs = Net::SSLeay::print_errs('CTX_new') or !$ctx;
	Net::SSLeay::CTX_set_options($ctx, &Net::SSLeay::OP_ALL);
	goto cleanup2 if $errs = Net::SSLeay::print_errs('CTX_set_options');
	warn "Cert `$crt_path' given without key" if $crt_path && !$key_path;
	Net::SSLeay::set_cert_and_key($ctx, $crt_path, $key_path) if $crt_path;
	$ssl = Net::SSLeay::new($ctx);
	goto cleanup if $errs = Net::SSLeay::print_errs('SSL_new') or !$ssl;

	# set up SNI (Server Name Indication), see specification item 4
	Net::SSLeay::set_tlsext_host_name($ssl, $dest_serv) || die "failed to set SSL host name for Server Name Indication";

	Net::SSLeay::set_fd($ssl, fileno(Net::SSLeay::SSLCAT_S));
	goto cleanup if $errs = Net::SSLeay::print_errs('set_fd');
	$got = Net::SSLeay::connect($ssl);
	goto cleanup if $errs = Net::SSLeay::print_errs('SSL_connect');
	my $server_cert = Net::SSLeay::get_peer_certificate($ssl);
	Net::SSLeay::print_errs('get_peer_certificate');

	### Connected. Exchange some data (doing repeated tries if necessary).
	($written, $errs) = Net::SSLeay::ssl_write_all($ssl, $out_message);
	goto cleanup unless $written;
	sleep $Net::SSLeay::slowly if $Net::SSLeay::slowly;  # Closing too soon can abort broken servers # TODO: remove?
	($got, $errs) = Net::SSLeay::ssl_read_all($ssl);
	CORE::shutdown Net::SSLeay::SSLCAT_S, 1;  # Half close --> No more output, send EOF to server
cleanup:
	Net::SSLeay::free ($ssl);
	$errs .= Net::SSLeay::print_errs('SSL_free');
cleanup2:
	Net::SSLeay::CTX_free ($ctx);
	$errs .= Net::SSLeay::print_errs('CTX_free');
	close Net::SSLeay::SSLCAT_S;
	return wantarray ? ($got, $errs, $server_cert) : $got;
}

sub validate_cert {	# certificate -> 0: ok, >= 1: ERROR
	my $PEM = Net::SSLeay::PEM_get_string_X509($_[0]);
	my $x509 = Crypt::OpenSSL::X509->new_from_string($PEM);
	my $common_name = $x509->subject();	# TODO: does $common_name match the domain?
	my $f = DateTime::Format::x509->new();
	if (DateTime->today() < $f->parse_datetime($x509->notBefore())) {
	        return 1;	# cert is not yet valid
	}
	if (DateTime->today() > $f->parse_datetime($x509->notAfter())) {
	        return 1;	# cert has expired
	}
	if (scalar(grep(/^$common_name/, @known_hosts)) > 0) {
		# cert is known, does cert still match (TOFU)?
		my $local_cert;
		my $found_cert = 0;
		my $cert_body = 0;
		# TODO: check the stored expiration date? see gemini://gemini.circumlunar.space/docs/specification.gmi
		foreach (@known_hosts) {
			if ($_ eq $common_name) {
				$found_cert = 1;
			}
			if (not $found_cert) {
				next;
			}
			if ($_ eq '-----BEGIN CERTIFICATE-----') {
				$cert_body = 1;
			}
			if ($cert_body) {
				$local_cert .= $_;
				if ($_ eq '-----END CERTIFICATE-----') {
					last;
				}
			}
		}
		$PEM = join('', split("\n", $PEM));
		if ($local_cert eq $PEM) {
			return 0;
		} else {
			return 1;
		}
	} else {
		# Host is not known. TOFU: add to $hosts_file
		open (my $fh, '>>', $hosts_file) or die "Could not open file $hosts_file";
		$fh->say($common_name);
		$fh->say($x509->notAfter());
		$fh->print($PEM);
		close $fh;
		return 0;
	}
}

sub downloader {	# $body --> 0: success, >0: failure
	my $dl_file = $url =~ s|^.*/||r;
	$dl_file = $ENV{'HOME'} . "/Downloads/" . $dl_file;
	c_prompt_ch "Downloading $url ...";
	open my $fh, '>:raw', $dl_file or clean_exit "error opening $dl_file for writing";
	print $fh $_[0] or clean_exit "error writing to file $dl_file";
	close $fh;
	return 0;
}

sub open_gemini {	# url
	my $domain = gem_host($_[0]);

	# sslcat request
	# TODO: avoid sslcat if viewing local file
	(my $raw_response, my $err, my $server_cert)= sslcat_custom($domain, 1965, "$_[0]\r\n");	# has to end with CRLF ('\r\n')
	if ($err) {
		die "error while trying to establish TLS connection";
	}
	if (not defined $server_cert) {
		die "no certificate received from server";
	}
	validate_cert($server_cert) && clean_exit "Error while checking server certificate";

	# TODO: enforce <META>: UTF-8 encoded, max 1024 bytes
	my @response =	lines($raw_response);
	my $header =	shift @response;
	(my $full_status, my $meta) = sep $header;	# TODO: error if $full_status is not 2 digits
	my $status = substr $full_status, 0, 1;
	my @formatted;		# array of rendered lines
	undef @links;
	$url =~ s/[^[:print:]]//g;
	if ($status != 3) {
		$redirect_count = 0;	# reset the $redirect_count
	}
	if ($status == 1) {		# 1x: INPUT
		# TODO: implement
		# <META> is a prompt to display to the user
		# after user input, request the same resource again with the user input as the query component
		# query component is separated from the path by '?'. Reserved characters including spaces must be "percent-encoded"
		# 11: SENSITIVE INPUT (e.g. password entry) - don't echo
		print "INPUT\n";
	} elsif ($status == 2) {	# 2x: SUCCESS
		# <META>: MIME media type (apply to response body), DEFAULT TO "text/gemini; charset=utf-8"
		# TODO: process language, encoding

		# is content text/gemini or something else?
		chomp $meta;
		if (not $meta =~ m{^text/gemini} && not $meta =~ m{^\s*$}) {
			# check if extension in %open_with
			my $f_ext = $url =~ s/.*\././r;
			if (defined $open_with{$f_ext}) {
				open(my $fh, '|-', "$open_with{$f_ext}") or c_warn "Error opening pipe to ogg123: $!";
				print $fh join("\n", @response) or clean_exit "error writing to pipe";
				close $fh;
			} else {
				my $r = '';
				until ($r =~ /[YyNn]/) {
					$r = c_prompt_ch "Unknown MIME type in resource $url. Download? [y/n]";
				}
				if ($r eq 'y') {
					downloader(join("\n", @response)) && c_warn "Download of $url failed!";
				}
			}
			if ($history_pointer > 0) {
				$url = $history[$history_pointer];
				return;
			}	# TODO: warn if trying to go back when at $history_pointer == 0?
		}

		if ($history[$history_pointer] ne $url) {	# $url and @history at pointer are not equal if we are NOT browsing back in history
			if (scalar(@history) > $history_pointer + 1) {
				splice @history, $history_pointer + 1;	# remove history after pointer in case we've gone back in history and this is a new site
			}
			push @history, $url;			# log to @history
			$history_pointer = scalar(@history) - 1;
		}
		gmiformat \@response, \@formatted, \@links;
		my $displayrows = $LINES - 1;
		my $viewfrom = 0;	# top line to be shown
		my $viewto;
		my $render_length = scalar(@formatted);
		my $update_viewport = 1;
		while (1) {
			$viewto = min($viewfrom + $displayrows, $render_length - 1);
			if ($update_viewport == 1) {
				gmirender $viewfrom, $viewto, \@formatted, \@links;
				refresh($win);
			}
			$update_viewport = 0;
			my ($c, $fn) = getchar;		# $fn: a function key, like arrow keys etc
			if (defined $fn) {	# do this dance so that $c and $fn are not undefined
				$c = '';
			} else {
				$fn = 0x0;	# TODO: double-check that this doesn't conflict with any KEY_*
			}
			if ($c eq 'H') {	# history
				#$scr->puts(join(' ', @history));
			#} elsif ($c =~ /\aH/) {	# home
				#$url = "gemini://gemini.circumlunar.space/";
				#return;
			} elsif ($c eq 'I') {	# info
				#$scr->at($displayrows + 1, 0)->puts("displayrows: $displayrows, viewfrom: $viewfrom, viewto: $viewto, links: " . scalar(@links) . ", history length: " . scalar(@history));
			} elsif ($c eq 'q') {	# quit
				undef $url;
				return;
			} elsif ($c eq "\cH" || $fn == KEY_BACKSPACE) {
				if ($history_pointer > 0) {
					$history_pointer--;
					$url = $history[$history_pointer];
					return;
				}	# TODO: warn if trying to go back when at $history_pointer == 0?
			} elsif ($c eq ' ' || $fn == KEY_NPAGE) {
				if ($viewto < $render_length - 1) {
					$update_viewport = 1;
					$viewfrom = min($viewfrom + $displayrows, $render_length - $displayrows - 1);
				}
			} elsif ($c eq 'b' || $fn == KEY_PPAGE) {
				if ($viewfrom > 0) {
					$update_viewport = 1;
					$viewfrom = max($viewfrom - $displayrows, 0);
				}
			} elsif ($c eq 'j' || $fn == KEY_DOWN) {
				if ($viewto < $render_length - 1) {
					$update_viewport = 1;
					$viewfrom++;
				}
			} elsif ($c eq 'k' || $fn == KEY_UP) {
				if ($viewfrom > 0) {
					$update_viewport = 1;
					$viewfrom--;
				}
			} elsif ($c eq 'K' || $fn == KEY_HOME) {
				if ($viewfrom > 0) {
					$update_viewport = 1;
					$viewfrom = 0;
				}
			} elsif ($c eq 'J' || $fn == KEY_END) {
				if ($viewto < $render_length - 1) {
					$update_viewport = 1;
					$viewfrom = $render_length - $displayrows - 1;
				}
			} elsif ($c eq 'o') {
				$url = c_prompt_str("url: gemini://");	# TODO: allow relative links??
				$url = 'gemini://' . $url;
				return;
			} elsif ($c eq ':') {	# TODO: implement long option commands, e.g. help...
				my $s = c_prompt_str(": ");
				addstr(0, 0, "You typed: " . $s);
				getch;
				clean_exit;
			} elsif ( $c =~ /\d/ ) {
				addch($LINES - 1, 0, $c);
=pod
				if (scalar(@links) >= 10) {
					# TODO: allow infinitely long digits by using do ... while? https://www.perlmonks.org/?node_id=282322
					my $keypress = getch;
					if (defined $keypress && $keypress =~ /\d/) {	# ignore non-digit input
						$c .= $keypress;
						if (scalar(@links) >= 100) {	# supports up to 999 links in a page
							undef $keypress;
							my $keypress = getch;
							if (defined $keypress && $keypress =~ /\d/) {
								$c .= $keypress;
							}
						}
					}
				}
=cut
				unless ($c <= scalar(@links)) {
					clean_exit "link number outside of range of current page: $c";
				}
				$url = expand_url($url, $links[$c - 1]);
				return;
			}
		}
	} elsif ($status == 3) {	# 3x: REDIRECT
		# 30: TEMPORARY, 31: PERMANENT: indexers, aggregators should update to the new URL, update bookmarks
		chomp $url;
		chomp $meta;
		$redirect_count++;
		if ($redirect_count > $redirect_max) {
			die "ERROR: more than maximum number of $redirect_max redirects";
		}
		# TODO: allow option to ask for confirmation before all redirects
		$url = expand_url($url, $meta);
		if (not $url =~ m{^gemini://}) {
			die "ERROR: cross-protocol redirects not allowed";	# TODO: instead ask for confirmation?
		}
		return;
	} elsif ($status == 4) {	# 4x: TEMPORARY FAILURE
		# TODO: implement proper error message without dying
		# <META>: additional information about the failure. Client should display this to the user.
		# 40: TEMPORARY FAILURE, 41: SERVER UNAVAILABLE, 42: CGI ERROR, 43: PROXY ERROR, 44: SLOW DOWN
		print "TEMPORARY FAILURE\n";
	} elsif ($status == 5) {	# 5x: PERMANENT FAILURE
		# TODO: implement proper error message without dying
		# <META>: additional information, client to display this to the user
		# 50: PERMANENT FAILURE, 51: NOT FOUND, 52: GONE, 53: PROXY REQUEST REFUSED, 59: BAD REQUEST
		print "PERMANENT FAILURE\n";
	} elsif ($status == 6) {	# 6x: CLIENT CERTIFICATE REQUIRED
		# TODO: implement
		# <META>: _may_ provide additional information on certificate requirements or why a cert was rejected
		# 60: CLIENT CERTIFICATE REQUIRED, 61: CERTIFICATE NOT AUTHORIZED, 62: CERTIFICATE NOT VALID
		print "CLIENT CERTIFICATE REQUIRED\n";
	} else {
		die "Invalid status code in response";
	}
}

sub open_custom {
	if (defined $open_with{$_[0]}) {
		system("$open_with{$_[0]} $_[1]");
		$url = $history[$history_pointer];
	} else {
		clean_exit "Not implemented.";
	}
}

sub open_url {
	if (uri_class($_[0]) eq 'gemini') {
		open_gemini $_[0];
	} elsif (uri_class($_[0]) eq 'https' or uri_class($_[0]) eq 'http') {
		open_custom 'html', $_[0] ;
	} elsif (uri_class($_[0]) eq 'gopher') {
		open_custom 'gopher', $_[0];
	} elsif (uri_class($_[0]) eq 'file') {
		open_custom 'file', $_[0];
	} elsif (uri_class($_[0]) eq 'mailto') {
		open_custom 'mailto', $_[0];
	} else {
		clean_exit "Protocol not supported.";
	}
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

# Init: ssl, pledge, unveil
Net::SSLeay::initialize();	# initialize ssl library once

if ($^O eq 'openbsd') {
	# TODO: tighten pledge later, e.g. remove wpath rpath after config is read
	#	sslcat_custom:			rpath inet dns
	#	system (for external programs)	exec proc
	#	Curses				tty
	#
	# prot_exec is needed, as sometimes abort trap gets triggered when loading pages without it
	pledge(qw ( exec tty cpath rpath wpath inet dns proc prot_exec unveil ) ) || die "Unable to pledge: $!";
	## ALL PROMISES FOR TESTING ##pledge(qw ( rpath inet dns tty unix exec tmppath proc route wpath cpath dpath fattr chown getpw sendfd recvfd tape prot_exec settime ps vminfo id pf route wroute mcast unveil ) ) || die "Unable to pledge: $!";

	# TODO: tighten unveil later
	unveil( "$ENV{'HOME'}/Downloads", "rwc") || die "Unable to unveil: $!";
	unveil( "/usr/local/libdata/perl5/site_perl/amd64-openbsd/auto/Net/SSLeay", "r") || die "Unable to unveil: $!";
	unveil( "/usr/local/libdata/perl5/site_perl/IO/Pager", "rwx") || die "Unable to unveil: $!";
	unveil( "/usr/libdata/perl5", "r") || die "Unable to unveil: $!";	# TODO: tighten this one more
	unveil( "/etc/resolv.conf", "r") || die "Unable to unveil: $!";		# needed by sslcat(r)
	# TODO: unveiling /bin/sh is problematic
	### LEAVE OUT ###unveil( "/bin/sh", "x") || die "Unable to unveil: $!";	# Term::Screen needs access to /bin/sh to hand control back to the shell
	unveil( "/etc/termcap", "r") || die "Unable to unveil: $!";
	### LEAVE OUT ###unveil( "/usr/local/libdata/perl5/site_perl/Curses", "x") || die "Unable to unveil: $!";	# for Curses TODO: tighten more?
	unveil( "$ENV{'HOME'}/.porcelain", "rwc") || die "Unable to unveil: $!";
	if (-f $porcelain_dir . '/open.conf') {
		%open_with = readconf($porcelain_dir . '/open.conf');
	}
	for my $v (values %open_with) {
		# TODO: implement paths with whitespace, eg. in quotes? like: "/home/user/these programs/launch"
		my $unveil_bin = $v =~ s/\s.*$//r;	# this way parameters to the programs will not mess up the call.
		unveil( $unveil_bin, "x") || die "Unable to unveil: $!";
	}
	unveil() || die "Unable to lock unveil: $!";
}

# process user input
# TODO: allow and process CLI flags
if (scalar @ARGV == 0) {	# no URI passed
	$url = "gemini://gemini.circumlunar.space/";
} else {
	if (not $ARGV[0] =~ m{://}) {
		$url = 'gemini://' . $ARGV[0];
	} else {
		$url = "$ARGV[0]";
	}
}

while ($url) {
	open_url $url;
}

clean_exit;

__END__

=head1 NAME

Porcelain - a gemini browser

=head1 SYNOPSIS

Porcelain.pl [url]

=head1 DESCRIPTION

B<Porcelain> is a text-based browser for gemini pages. It uses
OpenBSD's pledge and unveil technologies. The goal of Porcelain is to
be a "spec-conservative" gemini browser, meaning no support for
non-spec extension attempts (like favicons, metadata). Automatic opening
or inline display of non-gemini/text content is opt-in.

=head1 KEYS

=over

=item h

Display browsing history.

=item H

Return to home page.

=item I

Print infos (mostly for debugging).

=item q

Quit the application.

=item Ctrl-H

Go back in browsing history.

=item Space/Page Down

Scroll down page-wise.

=item B/Page Up

Scroll up page-wise.

=item Down

Scroll down line-wise.

=item Up

Scroll up line-wise.

=item Home

Go to the beginning of the page.

=item End

Go to the end of the page.

=item 1,2,3,...

Open link with that number.

=back

=head1 FILES

~/.porcelain/open.conf

=cut
