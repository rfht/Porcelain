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

# TODO:
# - look up pledge and unveil examples and best practices
# - fix NOT WORKING sites above
# - keep testing with gemini://gemini.conman.org/test/torture/
# - implement a working pager (IO::Pager::Perl not working)
# - implement forwarding
# - search "TODO" in comments

use strict;
use warnings;
use feature 'unicode_strings';
package Porcelain::Main;

#use IO::Pager::less;					# NOT WORKING
#use IO::Pager::Perl;					# 'q' key to quit not working; use Ctrl-C; NOT WORKING
use List::Util qw(min max);
require Net::SSLeay;					# p5-Net-SSLeay
Net::SSLeay->import(qw(sslcat));			# p5-Net-SSLeay
#$Net::SSLeay::trace = 5;				# enable for tracing details of p5-Net-SSLeay
use OpenBSD::Pledge;					# OpenBSD::Pledge(3p)
use OpenBSD::Unveil;					# OpenBSD::Unveil(3p)
#use Term::ReadKey;					# for use with IO::Pager::Perl
use Term::ScreenColor;
use Text::Format;					# p5-Text-Format
#use URI;						# p5-URI - note: NO SUPPORT FOR 'gemini://'; could be used for http, gopher
use utf8;

# terminal: width in chars, height in chars, width in pixels, height in pixels
#(my $wchar, my $hchar, my $wpix, my $hpix) = GetTerminalSize();	# from Term::ReadKey

my $scr = new Term::ScreenColor;
$scr->colorizable(1);
$scr->clrscr();

# text formatter (Text::Format)
my $text = Text::Format->new;
$text->columns($scr->cols);

sub gem_uri {
	# TODO: error if not a valid URI
	my $input = $_[0];
	my $out = $input;
	return $out;
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

sub bold {	# string --> string(but bold)
	return "\033[1m".$_[0]."\033[0m";
}

sub lines {	# multi-line text scalar --> $first_line / @lines
	my @lines = (split /\n/, $_[0]);
	return wantarray ? @lines : $lines[0];
}

sub gmitxt {	# text/gemini (as array of lines!) => formatted text
	# note: this will manipulate the passed array, rather than return a new one
	# call with "gmitxt \@array"
	# TODO: what to do with the link targets?
	# TODO: process "alt text" of initial preformat marker (text that follows)
	# Note: Any text following the leading "```" of a preformat toggle line which
	#	toggles preformatted mode off MUST be ignored by clients.
	# TODO: should alt txt after ``` include any whitespace between ``` and alnum string?
	# TODO: should quote lines disregard whitespace between '>' and the first printable characters?
	my $aref = $_[0];
	my $t_preform = 0;	# toggle for preformatted text
	my $t_list = 0;		# toggle unordered list - TODO
	my $t_quote = 0;	# toggle quote - TODO
	my $line;
	foreach (@$aref) {
		# TODO: ignore formatting if $t_preform
		if ($_ =~ /^###/) {			# Heading 3
			$_ =~ s/^###[[:blank:]]+(.*)/H3: $1/;
		} elsif ($_ =~ /^##/) {			# Heading 2
			$_ =~ s/^##[[:blank:]]*//;
			$_ = bold $_;
			$_ = $scr->colored('white', $_);
		} elsif ($_ =~ /^#/) {			# Heading 1
			$line = $_ =~ s/^#[[:blank:]]*//r;
			$line = bold $line;
			$line = $scr->colored('white on blue', $line);
			$line = $text->center($line);
			$_ =~ s/.*/$line/;
		} elsif ($_ =~ /^=>[[:blank:]]/) {	# Link
			$_ =~ s/^=>[[:blank:]]+(.*)/L: $1/;
		} elsif ($_ =~ /^```/) {		# Preformat toggle marker
			if (not $t_preform) {
				$t_preform = 1;
				$_ =~ s/^```/PREFORM ON, ALT TEXT (IF ANY): /;
			} else {
				$t_preform = 0;
				$_ =~ s/^```.*$/PREFORM OFF/;
			}
		} elsif ($_ =~ /^\* /) {		# Unordered List Item
			$_ =~ s/^\* [[:blank:]]*(.*)/- $1/;
		} elsif ($_ =~ /^>/) {			# Quote
			$_ =~ s/^>[[:blank:]]*(.*)/> $1/;
		} else {				# Text line
			$_ =~ s/^[[:blank:]]*//;
		}
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

# init
Net::SSLeay::initialize();	# initialize ssl library once

# TODO: tighten pledge later
# stdio promise is always implied by OpenBSD::Pledge
# needed promises:
#	sslcat:			rpath inet dns
# 	IO::Pager::Perl:	tty	- NOT USING
# 	URI (no support for 'gemini://':			prot_exec (for re engine)
#	Term::Screen		proc
#pledge(qw ( rpath inet dns unveil ) ) || die "Unable to pledge: $!";
pledge(qw ( rpath inet dns proc unveil ) ) || die "Unable to pledge: $!";
## ALL PROMISES FOR TESTING ##pledge(qw ( rpath inet dns tty unix exec tmppath proc route wpath cpath dpath fattr chown getpw sendfd recvfd tape prot_exec settime ps vminfo id pf route wroute mcast unveil ) ) || die "Unable to pledge: $!";
#pledge(qw ( rpath inet dns tty unix exec tmppath route wpath cpath dpath fattr chown getpw sendfd recvfd tape prot_exec settime ps vminfo id pf route wroute mcast unveil ) ) || die "Unable to pledge: $!";

# TODO: tighten unveil later
# needed paths for sslcat: /etc/resolv.conf (r)
# ### LEAVE OUT UNTIL USING ### unveil( "$ENV{'HOME'}/Downloads", "rw") || die "Unable to unveil: $!";
unveil( "/usr/local/libdata/perl5/site_perl/amd64-openbsd/auto/Net/SSLeay", "r") || die "Unable to unveil: $!";
unveil( "/usr/local/libdata/perl5/site_perl/IO/Pager", "rwx") || die "Unable to unveil: $!";
unveil( "/etc/resolv.conf", "r") || die "Unable to unveil: $!";
unveil( "/bin/sh", "x") || die "Unable to unveil: $!";	# Term::Screen needs access to /bin/sh to hand control back to the shell
# ### LEAVE OUT UNLESS WILL USE ###unveil( "/usr/bin/clear", "x") || die "Unable to unveil: $!";
# ### LEAVE OUT ### unveil( "/usr/local/libdata/perl5/site_perl/URI", "r") || die "Unable to unveil: $!";
# ### LEAVE OUT WITHOUT IO::Pager::Perl ### unveil( "/etc/termcap", "r") || die "Unable to unveil: $!";
unveil() || die "Unable to lock unveil: $!";

# process user input
my $url;
my $domain;

# validate input - is this correct gemini URI format?
$url = gem_uri("$ARGV[0]");
$domain = gem_host($url);

# sslcat request
# TODO: avoid sslcat if viewing local file
#
# ALTERNATIVES TO sslcat:
# printf "gemini://perso.pw/blog/index.gmi\r\n" | openssl s_client -tls1_2 -ign_eof -connect perso.pw:1965
# printf "gemini://perso.pw/blog/index.gmi\r\n" | nc -T noverify -c perso.pw 1965
(my $raw_response, my $err, my $server_cert)= sslcat_custom($domain, 1965, "$url\r\n");	# has to end with CRLF ('\r\n')
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
#		* <META>: _may_ provide additional information on certificat requirements or why a cert was rejected
#		* 60: CLIENT CERTIFICATE REQUIRED
#		* 61: CERTIFICATE NOT AUTHORIZED
#		* 62: CERTIFICATE NOT VALID
# <META>: UTF-8 encoded, max 1024 bytes
# The distinction between 4x and 5x is mostly for "well-behaved automated clients"
#
# Response Body
# =============
# Raw text or binary content. Server closes connection after the final byte. No "end of response" signal.
# Only after SUCCESS (2x) header.

# process basic reply elements: header (status, meta), body (if applicable)
# TODO: process language, encoding

my @response =	lines($raw_response);
my $header =	shift @response;
(my $full_status, my $meta) = sep $header;	# TODO: error if $full_status is not 2 digits

my $status = substr $full_status, 0, 1;

#$scr->puts("Status: $status\n");
#$scr->puts("Meta: $meta\n");
#my $testcols = $scr->cols;
#$scr->puts("Cols: $testcols\n");

# Process $status
if ($status == 1) {		# 1x: INPUT
	print "INPUT\n";
} elsif ($status == 2) {	# 2x: SUCCESS
	$scr->puts("SUCCESS\n");
	gmitxt \@response;
	$scr->noecho();
	$scr->clrscr();
	my $displayrows = $scr->rows - 2;
	my $quit = 0;
	my $viewport = 0;	# where in the page are we? (row)
	while (not $quit) {
		for (0..$displayrows) {
			$scr->at($_, 0);
			$scr->puts($response[$_]);
		}

		my $c = $scr->getch();
		print "You pressed: $c\n";
		if ($c eq 'q') {
			$quit = 1;
		}
	}
	$scr->at($scr->rows, 0);
} elsif ($status == 3) {	# 3x: REDIRECT
	print "REDIRECT\n";
} elsif ($status == 4) {	# 4x: TEMPORARY FAILURE
	print "TEMPORARY FAILURE\n";
} elsif ($status == 5) {	# 5x: PERMANENT FAILURE
	print "PERMANENT FAILURE\n";
} elsif ($status == 6) {	# 6x: CLIENT CERTIFICATE REQUIRED
	print "CLIENT CERTIFICATE REQUIRED\n";
} else {
	die "Invalid status code in response";
}

# transform response body
# - link lines into links
# - optionally: autorecognize types of links, e.g. .png, .jpg, .mp4, .ogg, and offer to open (inline vs. dedicated program?)
# - compose relative links into whole links
# - style links according to same domain vs. other gemini domain vs. http[,s] vs. gopher
# - style headers 1-3
# - style bullet points
# - style preformatted mode
# - style quote lines
