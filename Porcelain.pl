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

# STATUS:
#  WORKING DOMAINS:
#  - gemini://gemini.circumlunar.space/docs/specification.gmi
#  - gemini://loomcom.com/thoughts.gmi
#  - gemini://medusae.space/
#  - gemini://playonbsd.com/index.gmi		-> fixed with sub sslcat_custom
#  - gemini://gus.guru/				-> fixed with sub sslcat_custom
#  - gemini://perso.pw/blog/articles/limit.gmi	-> fixed with sub sslcat_custom
#  - gemini://gemini.circumlunar.space/software/
#
#  NOT WORKING:
#  - gemini://playonbsd.com							-> returns "31 /"
#  - gemini://gmi.wikdict.com/							-> just returns 0
#  - gemini://translate.metalune.xyz/google/auto/en/das%20ist%20aber%20doof	-> returns "53 Proxy Requet Refused"
#  - gemini://gemini.circumlunar.space/software/				-> header1 not displayed
#  - gemini://chriswere.uk/gemserver.gmi					-> in half terminal window misses first few lines

# TODO:
# - look up pledge and unveil examples and best practices
# - fix NOT WORKING sites above
# - keep testing with gemini://gemini.conman.org/test/torture/
# - implement a working pager (IO::Pager::Perl not working)
# - implement forwarding
# - search "TODO" in comments
# - import IO::Stty to ports
# - check number of columns and warn if too few (< 80) ?
# - intercept Ctrl-C and properly exit when it's pressed
# - line break at work boundaries rather than in the middle of a word.
# - deal with terminal line wrap. Make sure subsequent content isn't printed *over* wrapped lines.
#	Example: gemini://hexdsl.co.uk/
# - implement server certificate check
# - xdg-open or other config for using external programs (browser, mpv etc.) for protocol/content types
# - limit size of history; can be configurable in whatever config approach is later chosen
# - when last line in display is end of text and I press down arrow, the last line disappears. E.g. chriswere.uk/

# DEPENDENCIES:
# - xdg-utils for xdg-open

use strict;
use warnings;
use feature 'unicode_strings';
package Porcelain::Main;

#use IO::Prompter;					# misc/p5-IO-Prompter; for prompt()
#use IO::Select;					# https://stackoverflow.com/questions/33973515/waiting-for-a-defined-period-of-time-for-the-input-in-perl
use IO::Stty;
my $stty_restore = IO::Stty::stty(\*STDIN, '-g');
use List::Util qw(min max);
require Net::SSLeay;					# p5-Net-SSLeay
Net::SSLeay->import(qw(sslcat));			# p5-Net-SSLeay
use OpenBSD::Pledge;					# OpenBSD::Pledge(3p)
use OpenBSD::Unveil;					# OpenBSD::Unveil(3p)
use Term::ReadKey;					# for use with IO::Pager::Perl; 'ReadMode 0;' resets tty, but not reliably
#use Term::Cap;						# for ->Tputs?? To reset terminal?
use Term::ScreenColor;
use Text::Format;					# p5-Text-Format
#use URI;						# p5-URI - note: NO SUPPORT FOR 'gemini://'; could be used for http, gopher
use utf8;						# TODO: really needed?

my $scr = new Term::ScreenColor;
$scr->colorizable(1);
$scr->clrscr();

# text formatter (Text::Format)
my $text = Text::Format->new;
$text->columns($scr->cols);

my $url;
my @history;

sub clean_exit {
	IO::Stty::stty(\*STDIN, $stty_restore);
	# TODO: clear screen on exit? ($scr->clrscr())
	#	Or just clear the last line at the bottom?
	if ($_[0]) {
		print $_[0] . "\n";
	}
	exit;
}

sub uri_class {	# URL string --> string of class ('gemini', 'https', etc.)
	# TODO: just return protocol before '://'?
	if ($_[0] =~ m{^gemini://}) {
		return 'gemini';
	} elsif ($_[0] =~ m{^https://}) {
		return 'https';
	} elsif ($_[0] =~ m{^http://}) {
		return 'http';
	} elsif ($_[0] =~ m{^gopher://}) {
		return 'gopher';
	} elsif ($_[0] =~ m{^file://}) {
		return 'file';
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
		return '';
	}
}

sub expand_url {	# current URL, new (potentially relative) URL -> new absolute URL
			# no change if URL is already absolute
	my $cururl = $_[0];
	my $newurl = $_[1];

	# TODO: check that $cururl is absolute (e.g. uri_class is 'gemini', 'https', 'http', 'gopher', 'file')

	if (uri_class($newurl) eq 'relative') {
		my $curdir;
		$curdir = substr($cururl, 0, rindex($cururl, '/') + 1);
		$newurl =~ s/^\/+//;
		while ($newurl =~ m{^\.{1,2}/?}) {
			$newurl =~ s/^\.\///;
			if ($newurl =~ m{^\.\./?}) {
				$curdir =~ s/[^\/]*\/$//;
				$newurl =~ s/^\.\.\/?//;
			}
		}
		$newurl = $curdir . $newurl;
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

sub bold {	# string --> string (but bold)
	return "\033[1m".$_[0]."\033[0m";
}

sub underscore {	# string --> string (but underscored)
	return "\033[4m".$_[0]."\033[0m";
}

sub lines {	# multi-line text scalar --> $first_line / @lines
	my @lines = (split /\n/, $_[0]);
	return wantarray ? @lines : $lines[0];
}

sub gmirender {	# text/gemini (as array of lines!), outarray, linkarray => formatted text (to outarray), linkarray
	# note: this will manipulate the passed array, rather than return a new one
	# call with "gmirender \@array \@outarray \@linkarray"
	# TODO: what to do with the link targets?
	# TODO: process "alt text" of initial preformat marker (text that follows)
	# Note: Any text following the leading "```" of a preformat toggle line which
	#	toggles preformatted mode off MUST be ignored by clients.
	# TODO: should alt txt after ``` include any whitespace between ``` and alnum string?
	# TODO: should quote lines disregard whitespace between '>' and the first printable characters?
	my $inarray = $_[0];
	my $outarray = $_[1];
	my $linkarray = $_[2];
	undef @$outarray;	# empty outarray
	undef @$linkarray;	# empty linkarray
	my $t_preform = 0;	# toggle for preformatted text
	my $t_list = 0;		# toggle unordered list - TODO
	my $t_quote = 0;	# toggle quote - TODO
	my $line;
	my $link_url;
	my $link_descr;
	my $num_links = 0;
	my $skipline = 0;
	foreach (@$inarray) {
		# TODO: ignore formatting if $t_preform
		if ($_ =~ /^```/) {		# Preformat toggle marker
			if (not $t_preform) {
				$t_preform = 1;
				# don't display
				# TODO: handle alt text?
			} else {
				$t_preform = 0;
			}
			$skipline = 1;
		} elsif (not $t_preform) {
			if ($_ =~ /^###/) {			# Heading 3
				$line = $_ =~ s/^###[[:blank:]]*//r;
				$line = bold $line;
			} elsif ($_ =~ /^##/) {			# Heading 2
				$line = $_ =~ s/^##[[:blank:]]*//r;
				$line = bold $line;
				$line = underscore $line;
				$line = $scr->colored('white', $line);
			} elsif ($_ =~ /^#/) {			# Heading 1
				$line = $_ =~ s/^#[[:blank:]]*//r;
				$line = bold $line;
				$line = $scr->colored('yellow', $line);
				$line = $text->center($line);
			} elsif ($_ =~ /^=>[[:blank:]]/) {	# Link
				$num_links++;
				$line = $_ =~ s/^=>[[:blank:]]+//r;
				($link_url, $link_descr) = sep $line;
				push @$linkarray, $link_url;
				$line = $link_descr;
				$line = underscore $line;
				$line = "[" . $num_links . "]\t" . $line;
				# TODO: interface to link, e.g. number
				#	Consider storing $num_links and $link_url in a hash
			} elsif ($_ =~ /^\* /) {		# Unordered List Item
				$line = $_ =~ s/^\* [[:blank:]]*(.*)/- $1/r;
			} elsif ($_ =~ /^>/) {			# Quote
				$line = $_ =~ s/^>[[:blank:]]*(.*)/> $1/r;
			} else {				# Text line
				$line = $_ =~ s/^[[:blank:]]*//r;
				# TODO: collapse multiple whitespace characters into one space?
				my $splitpos;
				undef $splitpos;
				while (length($line) > $scr->cols) {
					$splitpos = rindex($line, ' ', $scr->cols - 1);
					substr($line, $splitpos, 1) = '|';
					push @$outarray, substr($line, 0, $splitpos);
					$line = substr($line, $splitpos + 1);
				}
			}
		} else {					# display preformatted text
			$line = substr($_, 0, $scr->cols);	# TODO: disable the terminal's linewrap rather than truncating
			$line = $line . (" " x ($scr->cols - length($line)));
			$line = $scr->colored('black on cyan', $line);
		}
		if ($skipline == 0) {
			push @$outarray, $line;
		}
		$skipline = 0;
	}
}

# taken from sub sslcat in:
# /usr/local/libdata/perl5/site_perl/amd64-openbsd/Net/SSLeay.pm
# TODO: rewrite/simplify sslcat_custom
sub sslcat_custom { # address, port, message, $crt, $key --> reply / (reply,errs,cert)
	my ($dest_serv, $port, $out_message, $crt_path, $key_path) = @_;
	my ($ctx, $ssl, $got, $errs, $written);

	($got, $errs) = Net::SSLeay::open_proxy_tcp_connection($dest_serv, $port);
	return (wantarray ? (undef, $errs) : undef) unless $got;

	### Do SSL negotiation stuff

	$ctx = Net::SSLeay::new_x_ctx();
	goto cleanup2 if $errs = Net::SSLeay::print_errs('CTX_new') or !$ctx;
	Net::SSLeay::CTX_set_options($ctx, &Net::SSLeay::OP_ALL);
	goto cleanup2 if $errs = Net::SSLeay::print_errs('CTX_set_options');
	warn "Cert `$crt_path' given without key" if $crt_path && !$key_path;
	Net::SSLeay::set_cert_and_key($ctx, $crt_path, $key_path) if $crt_path;
	$ssl = Net::SSLeay::new($ctx);
	goto cleanup if $errs = Net::SSLeay::print_errs('SSL_new') or !$ssl;
	Net::SSLeay::set_fd($ssl, fileno(Net::SSLeay::SSLCAT_S));
	goto cleanup if $errs = Net::SSLeay::print_errs('set_fd');
	$got = Net::SSLeay::connect($ssl);
	goto cleanup if $errs = Net::SSLeay::print_errs('SSL_connect');
	my $server_cert = Net::SSLeay::get_peer_certificate($ssl);
	Net::SSLeay::print_errs('get_peer_certificate');

	### Connected. Exchange some data (doing repeated tries if necessary).

	($written, $errs) = Net::SSLeay::ssl_write_all($ssl, $out_message);
	goto cleanup unless $written;
	sleep $Net::SSLeay::slowly if $Net::SSLeay::slowly;  # Closing too soon can abort broken servers
	#($got, $errs) = Net::SSLeay::ssl_read_until($ssl, "EOF", 1024);
	($got, $errs) = Net::SSLeay::ssl_read_all($ssl);
	CORE::shutdown Net::SSLeay::SSLCAT_S, 1;  # Half close --> No more output, send EOF to server
cleanup:
	Net::SSLeay::free ($ssl);
	$errs .= Net::SSLeay::print_errs('SSL_free');
cleanup2:
	Net::SSLeay::CTX_free ($ctx);
	$errs .= Net::SSLeay::print_errs('CTX_free');
	#close Net::SSLeay::SSLCAT_S;
	return wantarray ? ($got, $errs, $server_cert) : $got;
}

sub open_gmi {	# url
	# log to @history
	push @history, $_[0];

	my $domain = gem_host($_[0]);

	# sslcat request
	# TODO: avoid sslcat if viewing local file
	#
	# ALTERNATIVES TO sslcat:
	# printf "gemini://perso.pw/blog/index.gmi\r\n" | openssl s_client -tls1_2 -ign_eof -connect perso.pw:1965
	# printf "gemini://perso.pw/blog/index.gmi\r\n" | nc -T noverify -c perso.pw 1965
	(my $raw_response, my $err, my $server_cert)= sslcat_custom($domain, 1965, "$_[0]\r\n");	# has to end with CRLF ('\r\n')
												# $err, $server_cert not usable IME

	# gemini://gemini.circumlunar.space/docs/specification.gmi
	# first line of reply is the header: '<STATUS> <META>' (ends with CRLF)
	# <STATUS>: 2-digit numeric; only the first digit may be needed for the client
	#	- 1x:	INPUT
	#		* <META> is a prompt to display to the user
	#		* after user input, request the same resource again with the user input as the query component
	#		* query component is separated from the path by '?'. Reserved characters including spaces must be "percent-encoded"
	#		* 11: SENSITIVE INPUT (e.g. password entry) - don't echo
	#	- 2x:	SUCCESS
	#		* <META>: MIME media type (apply to response body)
	#		* if <META> is empty string, MUST DEFAULT TO "text/gemini; charset=utf-8"
	#	- 3x:	REDIRECT
	#		* <META>: new URL
	#		* 30: REDIRECT - TEMPORARY
	#		* 31: REDIRECT - PERMANENT: indexers, aggregators should update to the new URL, update bookmarks
	#	- 4x:	TEMPORARY FAILURE
	#		* <META>: additional information about the failure. Client should display this to the user.
	#		* 40: TEMPORARY FAILURE
	#		* 41: SERVER UNAVAILABLE (due to overload or maintenance)
	#		* 42: CGI ERROR
	#		* 43: PROXY ERROR
	#		* 44: SLOW DOWN
	#	- 5x:	PERMANENT FAILURE
	#		* <META>: additional information, client to display this to the user
	#		* 50: PERMANENT FAILURE
	#		* 51: NOT FOUND
	#		* 52: GONE
	#		* 53: PROXY REQUEST REFUSED
	#		* 59: BAD REQUEST
	#	- 6x:	CLIENT CERTIFICATE REQUIRED
	#		* <META>: _may_ provide additional information on certificate requirements or why a cert was rejected
	#		* 60: CLIENT CERTIFICATE REQUIRED
	#		* 61: CERTIFICATE NOT AUTHORIZED
	#		* 62: CERTIFICATE NOT VALID
	# <META>: UTF-8 encoded, max 1024 bytes
	# The distinction between 4x and 5x is mostly for "well-behaved automated clients"

	# TODO: process basic reply elements: header (status, meta), body (if applicable)
	# TODO: process language, encoding

	my @response =	lines($raw_response);
	my $header =	shift @response;
	(my $full_status, my $meta) = sep $header;	# TODO: error if $full_status is not 2 digits
	my $status = substr $full_status, 0, 1;
	my @render;	# render array
	my @links;	# array containing links in the page
	$url =~ s/[^[:print:]]//g;

	# Process $status
	if ($status == 1) {		# 1x: INPUT
		print "INPUT\n";
	} elsif ($status == 2) {	# 2x: SUCCESS
		$scr->puts("SUCCESS\n");
		gmirender \@response, \@render, \@links;	# TODO: add second, empty array, and fill that one up (will likely have different line number)
		$scr->noecho();
		$scr->clrscr();
		my $displayrows = $scr->rows - 2;
		my $viewfrom = 0;	# top line to be shown
		my $viewto;
		my $render_length = scalar(@render);
		my $update_viewport = 1;
		while (1) {
			$viewto = min($viewfrom + $displayrows, $render_length - 1);
			if ($update_viewport == 1) {
				# TODO: set 'opost' outside of the loop?
				IO::Stty::stty(\*STDIN, 'opost');	# opost is turned off by Term::ScreenColor, but I need it
				$scr->puts(join("\n", @render[$viewfrom..$viewto]));
			}
			$update_viewport = 0;

			$scr->at($displayrows + 1, 0);
			my $c = $scr->getch();

			if ($c eq 'h') {	# history
				$scr->puts(join(' ', @history));
				clean_exit;
			} elsif ($c eq 'H') {	# home
				$url = "gemini://gemini.circumlunar.space/";
				return;
			} elsif ($c eq 'q') {	# quit
				undef $url;
				return;
			} elsif ( $c =~ /\cH/ ) {	# Ctrl-H: back navigation (TODO: not sure how backspace can be used)
				$url = $history[-2];
				return;
			} elsif ($c eq ' ' || $c eq 'pgdn') {
				if ($viewto < $render_length - 1) {
					$update_viewport = 1;
				}
				$viewfrom = min($viewfrom + $displayrows, $render_length - $displayrows - 1);
			} elsif ($c eq 'b' || $c eq 'pgup') {
				if ($viewfrom > 0) {
					$update_viewport = 1;
				}
				$viewfrom = max($viewfrom - $displayrows, 0);
			} elsif ($c eq 'kd') {
				if ($viewto < $render_length - 1) {
					$update_viewport = 1;
					$viewfrom++;
				}
			} elsif ($c eq 'ku') {
				if ($viewfrom > 0) {
					$update_viewport = 1;
					$viewfrom--;
				}
			} elsif ( $c =~ /\d/ ) {
				# supports up to 999 links in a page
				if (scalar(@links) >= 10) {
					# TODO: allow infinitely long digits by using do ... while? https://www.perlmonks.org/?node_id=282322
					my $keypress = ReadKey(1);
					if (defined $keypress && $keypress =~ /\d/) {	# ignore non-digit input
						$c .= $keypress;
						if (scalar(@links) >= 100) {
							undef $keypress;
							my $keypress = ReadKey(1);
							if (defined $keypress && $keypress =~ /\d/) {
								$c .= $keypress;
							}
						}
					}
				}
				unless ($c <= scalar(@links)) {
					clean_exit "link number outside of range of current page: $c";
				}
				# open link with new URL request
				$scr->at($displayrows - 2, 0);
				$url = expand_url($url, $links[$c - 1]);
				$scr->puts($url);
				return;
			}

			if ($update_viewport == 1) {
			$scr->clrscr();
			}
			$scr->at($displayrows + 1, 0);
			$scr->clreol();
			#$scr->puts("viewfrom: $viewfrom, viewto: $viewto, render_length: $render_length, update_viewport: $update_viewport");
		}
		$scr->at($scr->rows, 0);	# TODO: is this really needed?
	} elsif ($status == 3) {	# 3x: REDIRECT
		print "REDIRECT\n";
		# TODO: limit redirects? or warn?
		$url = expand_url($url, $meta);
		print $url;
		exit;
		return;
	} elsif ($status == 4) {	# 4x: TEMPORARY FAILURE
		print "TEMPORARY FAILURE\n";
	} elsif ($status == 5) {	# 5x: PERMANENT FAILURE
		print "PERMANENT FAILURE\n";
	} elsif ($status == 6) {	# 6x: CLIENT CERTIFICATE REQUIRED
		print "CLIENT CERTIFICATE REQUIRED\n";
	} else {
		die "Invalid status code in response";
	}

	# - optionally: autorecognize types of links, e.g. .png, .jpg, .mp4, .ogg, and offer to open (inline vs. dedicated program?)
	# - compose relative links into whole links
	# - style links according to same domain vs. other gemini domain vs. http[,s] vs. gopher
	# - style headers 1-3
	# - style bullet points
	# - style preformatted mode
	# - style quote lines
}

sub open_html {
	system("xdg-open $_[0]");
	# return to gemini url
	$url = $history[-1];
}

sub open_gopher {
	clean_exit "Not implemented.";
}

sub open_file {
	clean_exit "Not implemented.";
}

sub open_mailto {
	clean_exit "Not implemented.";
}

sub open_url {
	if (uri_class($_[0]) eq 'gemini') {
		open_gmi $_[0];
	} elsif (uri_class($_[0]) eq 'https' or uri_class($_[0]) eq 'http') {
		open_html $_[0];
	} elsif (uri_class($_[0]) eq 'gopher') {
		open_gopher $_[0];
	} elsif (uri_class($_[0]) eq 'file') {
		open_file $_[0];
	} elsif (uri_class($_[0]) eq 'mailto') {
		open_mailto $_[0];
	} else {
		clean_exit "Protocol not supported.";
	}
}

# init
Net::SSLeay::initialize();	# initialize ssl library once

# TODO: tighten pledge later
# stdio promise is always implied by OpenBSD::Pledge
# needed promises:
#	sslcat:			rpath inet dns
# 	IO::Pager::Perl:	tty	- NOT USING
# 	URI (no support for 'gemini://':			prot_exec (for re engine)
#	Term::Screen		proc
#	Term::ReadKey - ReadMode 0	tty	- NOT USING
#	IO::Stty::stty		tty
#	system (for xdg-open)	exec
pledge(qw ( exec tty rpath inet dns proc unveil ) ) || die "Unable to pledge: $!";
## ALL PROMISES FOR TESTING ##pledge(qw ( rpath inet dns tty unix exec tmppath proc route wpath cpath dpath fattr chown getpw sendfd recvfd tape prot_exec settime ps vminfo id pf route wroute mcast unveil ) ) || die "Unable to pledge: $!";

# TODO: tighten unveil later
# needed paths for sslcat: /etc/resolv.conf (r)
# ### LEAVE OUT UNTIL USING ### unveil( "$ENV{'HOME'}/Downloads", "rw") || die "Unable to unveil: $!";
unveil( "/usr/local/libdata/perl5/site_perl/amd64-openbsd/auto/Net/SSLeay", "r") || die "Unable to unveil: $!";
unveil( "/usr/local/libdata/perl5/site_perl/IO/Pager", "rwx") || die "Unable to unveil: $!";
unveil( "/etc/resolv.conf", "r") || die "Unable to unveil: $!";
unveil( "/bin/sh", "x") || die "Unable to unveil: $!";	# Term::Screen needs access to /bin/sh to hand control back to the shell
unveil( "/etc/termcap", "r") || die "Unable to unveil: $!";
unveil( "/usr/local/bin/xdg-open", "x") || die "Unable to unveil: $!";
# ### LEAVE OUT ### unveil( "/usr/local/libdata/perl5/site_perl/URI", "r") || die "Unable to unveil: $!";
unveil() || die "Unable to lock unveil: $!";

# process user input
if (scalar @ARGV == 0) {	# no URI passed
	$url = "gemini://gemini.circumlunar.space/";
} else {
	$url = "$ARGV[0]";
}

while ($url) {
	open_url $url;
}

clean_exit;
