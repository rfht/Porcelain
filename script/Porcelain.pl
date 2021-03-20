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
# - limit size of history; can be configurable in whatever config approach is later chosen
# - implement a hotkey to view history
# - implement subscribed option
# - allow theming (colors etc) via a config file?
# - see if some Perl modules may not be needed
# - review error handling - may not always need 'die'. Create a way to display warnings uniformly?
# - add option for "Content Warning" type use of preformatted text and alt text:
#	https://dragonscave.space/@devinprater/105782591455644854
# - implement logging messages, warnings, errors to file
# - add mouse support?!
# - implement 'N' to search backwards
# - implement '|' to pipe to external programs (like espeak)
# - update README, ideally as output from pod2usage
# - move documentation into porcelain.pod?
# - pledge after reading config; can get rid of rpath?? see https://marc.info/?l=openbsd-ports&m=161417431131260&w=2
# - remove non-printable terminal control characters; see https://lists.orbitalfox.eu/archives/gemini/2020/000390.html
# - implement TOFU recommendations:gemini://drewdevault.com/2020/09/21/Gemini-TOFU.gmi - PARTIALLY; NEED TEMP PERMISSIONS
# - fix supporting MIME text/plain: query: gemini://gemini.thebackupbox.net/IRIcheck
# - refactor sub validate_cert
# - implement client certs (for 6x codes)
# - add option to view raw text/gemini (or other?) file
# - fix newline in SYNOPSIS to separate different syntax
# - fix $reflow_text, $update_viewport mechanics in sub page_nav to keep viewport at stable position
#   (currently viewport moves down when increasing COLs, and up when decreasing)
# - add timeout to loading resources
# - ?add test suite?
# - when new certificate received, present fingerprint, potentially graphically, to the user for verification
# - add config option to mandate TLS >= 1.3
#   see specification (as of 2021-03-09): "Clients who wish to be "ahead of the curve MAY refuse to connect to servers using TLS version 1.2 or lower."
#   => test then what domains break
# - replace all uses of die with clean_die (?)
# - make it possible to use ':port' in URL like with gemini://rawtext.club:1965/~sloum/spacewalk.gmi
# - get OpenSSL version string with: print (Net::SSLeay::SSLeay_version() . "\n");
# - store protocol version with my $rv = Net::SSLeay::get_version($ssl); => can use to check TLSv1.3
# - fix underscore in front of link, header , see gemini://astrobotany.mozz.us
#	gemini://palm93.com/2021-03-07_Midgard.gmi 
# - implement geminispace search, like 's' in gemini://gmn.clttr.info/cgmnlm.gmi ?
# - c_prompt_str - enable backspace, arrow key navigation, cursor?
# - use newpad with $max_vrows and $max_vcols rather than simple window for the display
# - make sure not suring getstr, inchstr, instr because of potential for buffer overflow attacks; see https://metacpan.org/pod/Curses
# - make sure to escape dots and other RE chars in all uses of grep
# - investigate segfaults, e.g. 61		   start = win->_line[y].text; in wclear, when leaving Info page
# - turn the lower-case SHA-256 without ':' into a sub
# - implement caching of webpages
# - add the server response header (e.g. "20 text/gemini; lang=en-US;charset=utf-8") to Info page
# - other page to test with temporary certs: gemini://bestiya.duckdns.org/
# - check why cert mismatch with gemini://skyjake.fi/lagrange/ when following link from other domain (hyperborea.org)
# - add a print option (to a printer, e.g. via lpr)
# - add IRI support (see mailing list)
# - implement a way to preview links before following them
# - fix glitch of line continuation showing the internal leading characters e.g. gemini://thfr.info/gemini/modified-trust-verify.gmi list items when scrolling past initial line
# - fix opening files like *.png
# - remove need for rpath from sslcat_custom by preloading whatever is needed?
# - implement fork+exec
# - is 'our' instead of 'my' really needed for variables used by modules? e.g. $status_win
# - use sub lines more consistently

use strict;
use warnings;
use feature 'unicode_strings';
package Porcelain::Main;

$main::VERSION = "0.1-alpha";	# used by Getopt::Long auto_version

### Modules ###
use FindBin;
use lib "$FindBin::Bin/../lib";

use Any::URI::Escape;		# to handle percent encoding (uri_escape())
use Crypt::OpenSSL::X509;
use Curses;
use DateTime;
use Encode qw(encode decode);
use Getopt::Long qw(:config bundling require_order ); #auto_version auto_help);	# TODO: all of those needed?
use List::Util qw(min max);
require Net::SSLeay;
use Pod::Usage;
use Porcelain::Crypto;
use Porcelain::CursesUI;
use Porcelain::Porcelain;
use Porcelain::RandomArt;
use Text::CharWidth qw(mbswidth);
use Text::Wrap;

use open ':encoding(UTF-8)';
use subs qw(open_about);

### Variables ###
our $url;
our $url_cert;
my @back_history;
my @forward_history;
my %open_with;
my @links;		# array containing links in the pages
my @last_links;		# array list from last page, for next/previous (see gemini://gemini.circumlunar.space/users/solderpunk/gemlog/gemini-client-navigation.gmi)
my $chosen_link;	# holds a number of what link was chosen, refers to @last_links entries
our $win;
our $title_win;
our $status_win;
my $searchstr = '';		# search string
my @searchlns;		# lines with matches for search 
my $r;		# responses to prompts
our $max_vrows = 1024 * 1024;	# max virtual rows used in curses pads
our $max_vcols = 1024;	# maximum virtual columns used in curses pads

my $redirect_count = 0;
my $redirect_max = 5;	# TODO: allow setting this in the config

my $porcelain_dir = $ENV{'HOME'} . "/.porcelain";
our $idents_dir = $porcelain_dir . "/idents";
our $hosts_file = $porcelain_dir . "/known_hosts";
our @known_hosts;

# known_hosts entries
my $kh_domain;		# domain in known_hosts
my $kh_algo;		# hash algorithm of known_hosts entry (e.g. SHA-256)
our $kh_serv_hash;	# hash of the known server pubkey
our $kh_oob_hash;	# hash from out-of-band source
my $kh_oob_source;	# source of out-of-band hash
our $kh_oob_date;	# date of last out-of-band update

$SIG{INT} = \&caught_sigint;

### Subs ###
sub uri_class {	# URL string --> string of class ('gemini', 'https', etc.)
	if ($_[0] =~ m{^[[:alpha:]]+://}) {
		return $_[0] =~ s/^([[:alpha:]]+):\/\/.*$/$1/r;
	} elsif ($_[0] =~ m{^about:}) {
		return 'about';
	} elsif ($_[0] =~ m{^mailto:}) {
		return 'mailto';
	} elsif ($_[0] =~ m{://}) {		# '' ==  unsupported protocol
		return '';
	} elsif ($_[0] =~ m{^/}) {
		return 'root';
	} elsif ($_[0] =~ m{^[[:alnum:]]}) {
		return 'relative';
	} elsif ($_[0] =~ m{^\.}) {
		return 'relative';
	} else {
		return '';			# '' == unsupported protocol
	}
}

sub center_text {	# string --> string with leading space to position in center of terminal
	my $str = $_[0];
	my $colcenter = int($COLS / 2);
	my $strcenter = int(length($str) / 2);
	my $adjust = $colcenter - $strcenter;	# amount of space to move string by: $center - half the length of the string
	return (" " x $adjust) . $str;
}

sub url2absolute {	# current URL, new (potentially relative) URL -> new absolute URL
	my $cururl = $_[0];
	my $newurl = $_[1];
	if (uri_class($newurl) eq 'root') {
		$newurl = "gemini://" . gem_host($cururl) . $newurl;
	} elsif (uri_class($newurl) eq 'relative') {
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
	return $newurl;		# no change if $newurl is already absolute
}

sub gem_host {
	my $input = $_[0];
	my $out = substr $input, 9;	# remove leading 'gemini://'
	$out =~ s|/.*||;
	return $out;
}

sub sep {	# gmi string containing whitespace --> ($first, $rest)
	my $first =	$_[0] =~ s/[[:blank:]].*$//r;
	my $rest =	$_[0] =~ s/^[^[:blank:]]*[[:blank:]]*//r;
	return wantarray ? ($first, $rest) : $first;
}

sub lines {	# multi-line text scalar --> $first_line / @lines
	my @lines = (split /\n/, $_[0]);
	return wantarray ? @lines : $lines[0];
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
				my ($link_url, $link_descr) = sep $line;
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

sub gmirender {	# viewfrom, viewto, text/gemini (as array of lines!) => formatted text (to outarray)
	# call with "gmirender $viewfrom, $viewto, \@array"
	my $hpos = $_[0];
	my $hstop = $_[1];
	my $inarray = $_[2];
	my $line;
	my $t_list = 0;	# toggle list
	my $y;
	my $x;
	clear($win);
	move($win, 0, 0);	# keep space for title_win
	while ($hpos <= $hstop) {
		$line = ${$inarray}[$hpos++];
		if ($t_list && not $line =~ /^\*\*/) {
			$t_list = not $t_list;			# unordered list has not been continued. Reset the toggle.
		}
		if ($line =~ /^```/) {				# Preformatted
			# TODO: handle alt text?
			$line = substr $line, 3;
			attrset($win, COLOR_PAIR(4));
		} elsif ($line =~ /^###/) {			# Heading 3
			$line = substr $line, 3;
			attrset($win, COLOR_PAIR(2));
			attron($win, A_BOLD);
		} elsif ($line =~ /^##/) {			# Heading 2
			$line = substr $line, 2;
			attrset($win, COLOR_PAIR(2));
			attron($win, A_BOLD);
			attron($win, A_UNDERLINE);
		} elsif ($line =~ /^#/) {			# Heading 1
			$line = substr $line, 1;
			$line = center_text $line;
			attrset($win, COLOR_PAIR(2));
			attron($win, A_BOLD);
		} elsif ($line =~ /^=>\[/) {			# Link
			# TODO: style links according to same domain vs. other gemini domains
			$line = substr $line, 2;
			my @line_split = split(" ", $line);
			my $link_index = shift @line_split;
			my $li_num = $link_index;
			$li_num =~ tr/\[\]//d;
			$li_num = int($li_num - 1);	# zero based
			if (uri_class($links[$li_num]) eq 'gemini' || uri_class($links[$li_num]) eq 'relative' || uri_class($links[$li_num]) eq 'root') {
				attrset($win, COLOR_PAIR(5));	# cyan on black
			} elsif (uri_class($links[$li_num]) eq 'gopher') {
				attrset($win, COLOR_PAIR(6));	# magenta on black
			} elsif (substr(uri_class($links[$li_num]), 0, 4) eq 'http') {
				attrset($win, COLOR_PAIR(1));	# yellow on black
			} else {	# not sure what this is linking to
				attrset($win, COLOR_PAIR(2));
			}
			addstr($win, hlsearch($link_index . " ", $searchstr));	# TODO/limitation: highlighting can't traverse/match across $link_index to rest of the line (link description)
			attron($win, A_UNDERLINE);
			$line = join(" ", @line_split);
		} elsif ($line =~ /^=>(\s+)(.*)$/) {		# Continuation of Link
			attroff($win, A_UNDERLINE);
			addstr($win, $1);
			attron($win, A_UNDERLINE);
			$line = $2;
		} elsif ($line =~ /^\* /) {			# Unordered List Item
			$line =~ s/^\*/-/;
			$t_list = 1;
			attrset($win, COLOR_PAIR(2));
		} elsif ($line =~ /^\*\*/ && $t_list) {		# Continuation of List Item
			$line =~ s/^\*\*/  /;
			attrset($win, COLOR_PAIR(2));
		} elsif ($line =~ /^>/) {			# Quote
			attrset($win, COLOR_PAIR(3));
		} else {					# Text line
			attrset($win, COLOR_PAIR(2));
		}
		$line = encode('UTF-8', $line);
		$line = hlsearch $line, $searchstr;
		addstr($win, $line);
		getyx($win, $y, $x);
		move($win, $y + 1, 0);
	}
	refresh($win);
}

# see sslcat in /usr/local/libdata/perl5/site_perl/amd64-openbsd/Net/SSLeay.pm
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
	#warn "Cert `$crt_path' given without key" if $crt_path && !$key_path;
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

sub downloader {	# $body --> 0: success, >0: failure
	# TODO: add timeout; progress bar
	my $dl_file = $url =~ s|^.*/||r;
	$dl_file = $ENV{'HOME'} . "/Downloads/" . $dl_file;
	c_prompt_ch "Downloading $url ...";
	open my $fh, '>:raw', $dl_file or clean_exit "error opening $dl_file for writing";
	print $fh $_[0] or clean_exit "error writing to file $dl_file";
	close $fh;
	return 0;
}

sub next_match {	# scroll to next match in searchlns; \@sequence, $viewfrom, $displayrows, $render_length --> new $viewfrom
	my ($sequence, $fromln, $rows, $render_length) = @_; 
	if (scalar(@$sequence) < 1) {
		c_prompt_ch "No matches.";
		return undef;
	} else {
		my $centerline = $fromln + int(($rows + 1) / 2);
		if ($centerline >= ${$sequence}[-1]) {	# wrap to beginning of document
			$fromln = max(${$sequence}[0] - int(($rows + 1) / 2), 0);
		} else {
			foreach (@$sequence) {
				if ($_ > $centerline) {
					$fromln = min($_ - int(($rows + 1) / 2), $render_length - $rows - 1);
					last;
				}
			}
		}
		return $fromln;
	}
}

sub page_nav {
	my ($content) = @_;
	my @formatted;
	undef @links;

	my $viewfrom = 0;	# top line to be shown
	my $render_length;
	my $update_viewport;
	my $reflow_text = 1;

	my $domainname = gem_host($url);

	while (1) {
		if (defined $status_win) {
			delwin($status_win);
		}

		if ($reflow_text) {
			$reflow_text = 0;
			$update_viewport = 1;
			gmiformat $content, \@formatted, \@links;
			$render_length = scalar(@formatted);
		}

		my $displayrows = $LINES - 2;
		my $viewto = min($viewfrom + $displayrows, $render_length - 1);
		if ($update_viewport == 1) {
			c_title_win;
			gmirender $viewfrom, $viewto, \@formatted, \@links;
			refresh;
		}
		$update_viewport = 0;
		my ($c, $fn) = getchar;		# $fn: a function key, like arrow keys etc
		if (! defined $c) {	# do this dance so that $c and $fn are not undefined
			$c = '';
		}
		if (! defined $fn) {
			$fn = 0x0;	# TODO: double-check that this doesn't conflict with any KEY_*
		}
		if ($c eq 'H') {	# show history
			#my $histwin = c_fullscr join("\n", $url . " <-- CURRENT URL", reverse(@back_history)), "History";
			#undef $c;
			#$c = getchar;
			#delwin($histwin);
			open_about "about:history";
			#$update_viewport = 1;
			return;
		} elsif ($c eq 'i') {	# basic info (position in document, etc.	# TODO: expand, e.g. URL
			my $linesfrom = $viewfrom + 1;
			my $linesto = $viewto + 1;
			my $linespercent = int($linesto / $render_length * 100);
			c_prompt_ch "lines $linesfrom-$linesto/$render_length $linespercent%";
			$update_viewport = 1;
		} elsif ($c eq 'I') {	# advanced info
			# 7: out-of-band verification
			#	- type
			#	- date last renewed
			#	- time since last renewal
			my @info = ("Domain:\t\t\t" . $domainname, "Resource:\t\t" . $url);
			# TODO: order the output to match 'openssl x509 -text -noout -in <cert>'
			push @info, "Server Cert:";
			push @info, "\t\t\tSubject:\t\t" . $url_cert->subject();
			#push @info, "\t\t\tSubject Hash:\t\t" . $url_cert->hash();
			push @info, "\t\t\tEmail:\t\t\t" . $url_cert->email();
			push @info, "\t\t\tIssuer:\t\t\t" . $url_cert->issuer();
			#push @info, "\t\t\tIssuer Hash:\t" . $url_cert->issuer_hash();
			push @info, "\t\t\tNot Valid Before:\t" . $url_cert->notBefore();
			push @info, "\t\t\tNot Valid After:\t" . $url_cert->notAfter();
			#push @info, "\t\t\tModulus:\t\t" . $url_cert->modulus();		# TODO: how useful is modulus? Exponent?
			#push @info, "\t\t\tExponent:\t\t" . $url_cert->exponent();
			push @info, "\t\t\tFingerprint SHA-256:\n\t\t\t" . $url_cert->fingerprint_sha256(); # TODO: improve formatting
			push @info, "\t\t\tCertificate Version:\t" . $url_cert->version();
			push @info, "\t\t\tSignature Algorithm:\t" . $url_cert->sig_alg_name();
			push @info, "\t\t\tPublic Key Algorithm:\t" . $url_cert->key_alg_name();
			if ($url_cert->is_selfsigned()) {
				push @info, "\t\t\tSelf-signed?\t\tYes";
			} else {
				push @info, "\t\t\tSelf-signed?:\t\tNo";
			}
			push @info, "\n\n" . randomart(lc($url_cert->fingerprint_sha256() =~ tr/://dr));
			my $infowin = c_fullscr join("\n", @info), "Info";
			undef $c;
			$c = getchar;
			delwin($infowin);
			$update_viewport = 1;
		} elsif ($c eq 'q') {	# quit
			undef $url;
			return;
		} elsif ($c eq 'r') {	# go to domain root
			$url = "gemini://" . gem_host($url);
			return;
		} elsif ($c eq 'R') {	# reload page
			return;
		} elsif ($c eq 'u') {	# up in directories on domain
			my $slashcount = ($url =~ tr|/||);
			if ($slashcount > 3) {	# only go up if not at root of the domain
				$url =~ s|[^/]+/[^/]*$||;
				return;
			}
			# TODO: warn if can't go up
		} elsif ($c eq 'v') {	# verify server identity
			my $domain = gem_host $url;
			# ask for SHA-256, manual confirmation, or URL
			undef $r;
			until ($r) {
				$r = c_pad_str "Enter SHA-256, URL (for third-party verification), or [M] for manual mode: ";
			}
			chomp $r;
			$r = lc $r;
			if ($r eq "m") {			# manual mode
				my $match_win_width = max(int($COLS / 1.25), 22);
				my $match_win_height = max(int($displayrows / 1.25), 12);
				my $match_win = newwin($match_win_height, $match_win_width, int(($displayrows - $match_win_height) / 2), int(($COLS - $match_win_width) / 2)); 
				box($match_win, 0, 0);
				addstr($match_win, 1, 1, $url_cert->fingerprint_sha256());
				addstr($match_win, 3, 1, randomart(lc($url_cert->fingerprint_sha256() =~ tr/://dr)));
				addstr($match_win, $match_win_height - 2, 1, "Compare with SHA-256 fingerprint obtained from a credible source. Does it match?");
				refresh($match_win);
				$r = getch;
				unless (lc($r) eq 'y') {
					return;
				}
				# TODO: store the $sha256 (from $url_cert) in known_hosts
			} elsif ($r =~ tr/://dr =~ /^[0-9a-f]{64}$/) {	# SHA-256, can be 01:AB:... or 01ab...
				if ($r eq lc($url_cert->fingerprint_sha256() =~ tr/://dr)) {
					clean_exit "SHA-256 match";
				} else {
					clean_exit "SHA-256 mismatch";
				}
				# TODO:
				#	If it matches, should turn green (or stay green).
				#	If it doesn't match, show warning/error, and ask if user is sure that key entered is correct
				#	If entered key is correct, host will now be red
				#	If was not correct or not sure, offer entry of a new key or bail out and stay yellow
				#	Store host and user-entered SHA-256 if A) match, or B) confirmed correct key with mismatch
				#	otherwise, remove entry; staying yellow
			} elsif (not $r =~ /\s/) {		# URL	# TODO: refine?
				# TODO: implement fetching an SHA-256, pubkey (other?)
				clean_exit "Third-party OOB verification not yet implemented; URL provided: $r";
			} else {
				clean_exit "Invalid response: $r";
			}
			# TODO: implement creating the record and storing it
		} elsif ($c eq "]") {	# 'next' gemini://gemini.circumlunar.space/users/solderpunk/gemlog/gemini-client-navigation.gmi
			if (defined $chosen_link && $chosen_link < scalar(@last_links)-1 && defined $last_links[$chosen_link+1]) {
				$chosen_link++;
				$url = $last_links[$chosen_link];
				return;
			}	# TODO: warn/error if no such link
		} elsif ($c eq "[") {	# 'previous'
			if (defined $chosen_link && $chosen_link > 0 && defined $last_links[$chosen_link-1]) {
				$chosen_link--;
				$url = $last_links[$chosen_link];
				return;
			}	# TODO: warn/error if no such link
		} elsif ($c eq "\cH" || $fn == KEY_BACKSPACE) {
			if (scalar(@back_history) > 0) {
				push @forward_history, $url;
				$url = pop @back_history;
				return;
			}
		} elsif ($c eq "\cL") {	# forward in history
			if (scalar(@forward_history) > 0) {
				push @back_history, $url;
				$url = pop @forward_history;
				return;
			}
		} elsif ($fn eq KEY_RESIZE) {	# terminal has been resized
			$reflow_text = 1;
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
		} elsif ($c eq 'n') {
			my $viewfrom_new = next_match \@searchlns, $viewfrom, $displayrows, $render_length;
			if (defined $viewfrom_new) {
				$viewfrom = $viewfrom_new;
			}
			$update_viewport = 1;
		} elsif ($c eq 'o') {
			push @back_history, $url;	# save last url to back_history
			$url = c_prompt_str("url: ");	# not allowing relative links
			if (not $url =~ m{:}) {
				$url = "gemini://" . $url;
			}
			return;
		} elsif ($c eq ':') {	# TODO: implement long option commands, e.g. help...
			my $s = c_prompt_str(": ");
			# 'up'/'..'
			# 'root'/'/'
			# 'next', 'previous'
			# 'back', 'forward'
			addstr(0, 0, "You typed: " . $s);
			getch;
			$update_viewport = 1;
			clean_exit;
		} elsif ($c eq '/') {
			$searchstr = c_prompt_str("search: ");
			@searchlns = grep { $formatted[$_] =~ /$searchstr/i } 0..$#formatted;
			my $viewfrom_new = next_match \@searchlns, $viewfrom, $displayrows, $render_length;
			if (defined $viewfrom_new) {
				$viewfrom = $viewfrom_new;
			}
			$update_viewport = 1;
		} elsif ( $c =~ /\d/ ) {
			c_statusline "open link: $c - " . $links[$c-1];
			if (scalar(@links) >= 10) {
				timeout(500);
				my $keypress = getch;
				if (defined $keypress && $keypress =~ /\d/ && $keypress >= 0) {	# ignore non-digit input
					$c .= $keypress;
					c_statusline "open link: $c - " . $links[$c-1];
					if (scalar(@links) >= 100) {	# supports up to 999 links in a page
						undef $keypress;
						my $keypress = getch;
						if (defined $keypress && $keypress =~ /\d/ && $keypress >= 0) {
							$c .= $keypress;
						}
					}
				}
				timeout(-1);
			}
			unless ($c <= scalar(@links)) {
				delwin($status_win);
				c_err "link number outside of range of current page: $c";
				return;
			}
			$chosen_link = $c-1;
			@last_links = @links;	# TODO: last links needs to store absolute links, or use last url from history
			c_statusline "open link: $c - " . $last_links[$chosen_link];
			push @back_history, $url;	# save last url to back_history
			foreach (@last_links) {
				$_ = url2absolute($url, $_);
			}
			$url = $last_links[$chosen_link];
			return;
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

sub open_about {	# resource, e.g. 'about:history'
	my $about_page = substr $_[0], 6;	# remove leading 'about:'
	my @about_cont;				# content for the about page
	if ($about_page eq "history") {
		@about_cont = @back_history;
		unshift @about_cont, ("History", $url . " $url <-- CURRENT URL");
	} elsif ($about_page eq "bookmarks") {
	} elsif ($about_page eq "subscriptions") {
	} else {
		die "Invalid about address: $_[0]";
	}
	preformat_linklist \@about_cont;
	return page_nav \@about_cont;
}

sub open_file {		# opens a local file
	# get file MIME type with 'file -bi' command
	# if text/gemini, read file into variable, then render
	my $file = $_[0];
	my $raw_cont;
	if (substr($file, 0, 7) eq "file://") {
		$file = substr($file, 7);
	}
	open(my $fh, '<', $file) or die "cannot open $file";
	{
		local $/;
		$raw_cont = <$fh>;
	}
	close($fh);
	my @file_cont = split('\n', $raw_cont);
	return page_nav \@file_cont;
}

sub open_gemini {	# url, certpath (optional), keypath (optional)
	my ($resource, $certpath, $keypath) = @_;
	my $domain = gem_host($resource);
	# TODO: warn/error if $certpath but not $keypath

	undef $url_cert;
	(my $raw_response, my $err, $url_cert)= sslcat_custom($domain, 1965, "$resource\r\n", $certpath, $keypath);	# has to end with CRLF ('\r\n')
	# TODO: alert and prompt user if error obtaining cert or validating it.
	if ($err) {
		die "error while trying to establish TLS connection";
	}
	if (not defined $url_cert) {
		die "no certificate received from server";
	}
	# Transform $url_cert into usable format for Crypt::OpenSSL::X509
	$url_cert = Crypt::OpenSSL::X509->new_from_string(Net::SSLeay::PEM_get_string_X509($url_cert));
	if ($r = validate_cert($url_cert, $domain)) {
		my $last_r = $r;
		undef $r;
		do {
			$r = c_err "Error validating cert: $last_r. [C]ontinue anyway, or [A]bort?";
		} until ($r =~ /^[CcAa]$/);
		if ($r =~ /^[Aa]$/) {
			clean_exit;
		}
	}

	# TODO: enforce <META>: UTF-8 encoded, max 1024 bytes
	my @response =	lines(decode('UTF-8', $raw_response));	# TODO: allow non-UTF8 encodings?
	my $header =	shift @response;
	(my $full_status, my $meta) = sep $header;	# TODO: error if $full_status is not 2 digits
	chomp $meta;

	my $status = substr $full_status, 0, 1;
	$url =~ s/[^[:print:]]//g;
	$meta =~ s/[^[:print:]]//g;
	if ($status != 3) {
		$redirect_count = 0;	# reset the $redirect_count
	}
	if ($status == 1) {		# 1x: INPUT
		# TODO: 11: SENSITIVE INPUT (e.g. password entry) - don't echo
		$r = c_prompt_str $meta . ": ";	# TODO: other separator? check if $meta includes ':' at the end?
		$r = uri_escape $r;
		$url = $url . "?" . $r;		# query component is separated from the path by '?'.
		return;
	} elsif ($status == 2) {	# 2x: SUCCESS
		# <META>: MIME media type (apply to response body), DEFAULT TO "text/gemini; charset=utf-8"
		# TODO: process language, encoding

		# is content text/gemini or something else?
		# TODO: support text/plain
		if (not $meta =~ m{^text/gemini} && not $meta =~ m{^\s*$}) {
			# check if extension in %open_with
			my $f_ext = $url =~ s/.*\././r;
			if (defined $open_with{$f_ext}) {	# TODO: check MIME type primarily; suffix as fallback
				open(my $fh, '|-', "$open_with{$f_ext}") or c_warn "Error opening pipe to ogg123: $!";
				print $fh join("\n", @response) or clean_exit "error writing to pipe";
				close $fh;
			} else {
				$r = '';
				until ($r =~ /^[YyNn]$/) {
					$r = c_prompt_ch "Unknown MIME type in resource $url. Download? [y/n]";
				}
				if ($r =~ /^[Yy]$/) {
					downloader(join("\n", @response)) && c_warn "Download of $url failed!";
				}
			}
			if (scalar(@back_history) > 0) {
				$url = pop @back_history;
			} else {
				clean_exit "unable to open $url";
			}
		}
		return page_nav \@response
	} elsif ($status == 3) {	# 3x: REDIRECT
		# 30: TEMPORARY, 31: PERMANENT: indexers, aggregators should update to the new URL, update bookmarks
		chomp $url;
		$redirect_count++;
		if ($redirect_count > $redirect_max) {
			die "ERROR: more than maximum number of $redirect_max redirects";
		}
		# TODO: allow option to ask for confirmation before all redirects
		$url = url2absolute($url, $meta);
		if (not $url =~ m{^gemini://}) {
			die "ERROR: cross-protocol redirects not allowed";	# TODO: instead ask for confirmation?
		}
		return;
	} elsif ($status == 4) {	# 4x: TEMPORARY FAILURE
		# TODO: implement proper error message without dying
		# <META>: additional information about the failure. Client should display this to the user.
		# 40: TEMPORARY FAILURE, 41: SERVER UNAVAILABLE, 42: CGI ERROR, 43: PROXY ERROR, 44: SLOW DOWN
		do {
			$r = c_err "4x: Temporary Failure: $meta. [B]ack, [R]etry, [O]ther URL or [Q]uit?"; # TODO: [B]ack not working
		} until ($r =~ /^[BbRrOoQq]$/);
		if ($r =~ /^[Oo]$/) {
			$url = c_prompt_str("url: gemini://");	# TODO: allow relative links??
			$url = 'gemini://' . $url;
			return;
		} elsif ($r =~ /^[Bb]$/) {
			if (scalar(@back_history) > 0) {
				$url = pop @back_history;
				return;
			}
		} elsif ($r =~ /^[Qq]$/) {
			clean_exit;
		}
	} elsif ($status == 5) {	# 5x: PERMANENT FAILURE
		# TODO: implement proper error message without dying
		# <META>: additional information, client to display this to the user
		# 50: PERMANENT FAILURE, 51: NOT FOUND, 52: GONE, 53: PROXY REQUEST REFUSED, 59: BAD REQUEST
		do {
			$r = c_err "5x: Permanent Failure: $meta. [B]ack, [R]etry, [O]ther URL or [Q]uit?"; # TODO: [B]ack not working
		} until ($r =~ /^[BbRrOoQq]$/);
		if ($r =~ /^[Oo]$/) {
			$url = c_prompt_str("url: gemini://");	# TODO: allow relative links??
			$url = 'gemini://' . $url;
			return;
		} elsif ($r =~ /^[Bb]$/) {
			if (scalar(@back_history) > 0) {
				$url = pop @back_history;
				return;
			} else {
				clean_exit "error invalid url: $url";
			}
		} elsif ($r =~ /^[Qq]$/) {
			clean_exit;
		}
	} elsif ($status == 6) {	# 6x: CLIENT CERTIFICATE REQUIRED
		# <META>: _may_ provide additional information on certificate requirements or why a cert was rejected
		# 60: CLIENT CERTIFICATE REQUIRED, 61: CERTIFICATE NOT AUTHORIZED, 62: CERTIFICATE NOT VALID
		c_prompt_ch $meta;
		# check what identities exist
		opendir my $dh, $idents_dir or die "Could not open '$idents_dir' for reading: $!\n";
		my @ident_files = grep(/\.crt$/, readdir($dh));	# read only .crt files; each should have a matching .key
		closedir $dh;
		my $sha;
		# TODO: link an identity to a resource (and all paths underneath it)
		if (scalar(@ident_files) == 0) {
			$r = c_prompt_ch "Identity has been requested, but none found. Create new certificate for $url? [Y/n]";
			if ($r =~ /^[Yy]$/) {
				$sha = gen_identity 30;	# TODO: ask for certificate lifetime
			} else {
				clean_exit "No certificate; aborting.";
			}
		} else {
			$sha = c_prompt_str "Please enter identity to continue: ";
		}
		my $crt_key = $idents_dir . "/" . $sha;
		if (-e $crt_key . ".crt" && -e $crt_key . ".key") {
			open_gemini($url, $crt_key . ".crt", $crt_key . ".key");
		} else {
			c_err "Identity $r not found!";
		}
	} else {
		die "Invalid status code in response";
	}
}

sub open_custom {
	if (defined $open_with{$_[0]}) {
		system("$open_with{$_[0]} $_[1]");
		$url = pop @back_history;
	} else {
		if ($_[0] eq 'file') {
			open_file $url;
		} else {
			clean_exit "Not implemented.";
		}
	}
}

sub open_url {
	# TODO: read from %open_with, open with 'gemini' protocol or other modality
	# TODO: then determine the resource MIME type and call appropriate resource sub
	c_statusline "Loading $url ...";
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
	} elsif (uri_class($_[0]) eq 'about') {
		open_about $_[0];		# TODO: don't log about pages in history
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

### Process CLI Options ###
my $configfile = $porcelain_dir . "/porcelain.conf";
my $opt_dump =		'';	# dump page to STDOUT
my $opt_pledge =	'';	# use pledge
my $stdio;			# contains STDIN via '-'
my $opt_unveil =	'';	# use unveil

if ($^O eq 'openbsd') {	# pledge and unveil by default
	$opt_pledge = 1;
	$opt_unveil = 1;
}

GetOptions (
		"conf|c=s"	=> \$configfile,
		"dump|d"	=> \$opt_dump,
		"help|h"	=> sub { Getopt::Long::HelpMessage() },
		"man|m"		=> sub { pod2usage(-exitval => 0, -verbose => 2) },
		"pledge!"	=> \$opt_pledge,	# --nopledge disables
		''		=> \$stdio,
		"unveil!"	=> \$opt_unveil,	# --nounveil disables
		"version|v"	=> sub { Getopt::Long::VersionMessage() },
);
# Note: auto_version provides '--version' via $main::VERSION
#	auto_help provides '--help' via Pod::Usage;

### Set up and read config ###
if (! -d $porcelain_dir) {
	mkdir $porcelain_dir || die "Unable to create $porcelain_dir";
}
if (! -d $idents_dir) {
	mkdir $idents_dir || die "Unable to create $idents_dir";
}
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

# Init: ssl, pledge, unveil
# TODO: separate out into init sub or multiple subs
Net::SSLeay::initialize();	# initialize ssl library once

# Curses init
if (not $opt_dump) {
	initscr;
	start_color;	# TODO: check if (has_colors)
	$title_win = newwin(1, 0, 0, 0);
	$win = newwin(0,0,1,0);
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

if ($opt_pledge) {
	use OpenBSD::Pledge;
	# TODO: tighten pledge later, e.g. remove wpath rpath after config is read
	# TODO: remove cpath by creating the files with the installer?
	#	sslcat_custom:			rpath inet dns
	#	system (for external programs)	exec proc
	#	Curses				tty
	# prot_exec is needed, as sometimes abort trap gets triggered when loading pages without it
	pledge(qw ( exec tty cpath rpath wpath inet dns proc prot_exec unveil ) ) || die "Unable to pledge: $!";
}

if ($opt_unveil) {
	use OpenBSD::Unveil;
	# TODO: tighten unveil later
	unveil( "$ENV{'HOME'}/Downloads", "rwc") || die "Unable to unveil: $!";
	unveil( "/usr/local/libdata/perl5/site_perl/amd64-openbsd/auto/Net/SSLeay", "r") || die "Unable to unveil: $!";
	unveil( "/usr/libdata/perl5", "r") || die "Unable to unveil: $!";	# TODO: tighten this one more
	unveil( "/etc/resolv.conf", "r") || die "Unable to unveil: $!";		# needed by sslcat(r)
	unveil( "/etc/termcap", "r") || die "Unable to unveil: $!";
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

if (scalar @ARGV == 0) {	# no URI passed
	$url = "gemini://gemini.circumlunar.space/";
} else {
	if (not $ARGV[0] =~ m{://}) {
		$url = 'gemini://' . $ARGV[0];
	} else {
		$url = "$ARGV[0]";
	}
}

# Main loop
while ($url) {
	open_url $url;
}

clean_exit;

__END__

=head1 NAME

Porcelain - a gemini browser

=head1 SYNOPSIS

porcelain [-hmv]
porcelain [-d] [--nopledge] [--nounveil] [url|-]

Options:
  -h/--help	brief help message
  -m/--man	full documentation
  -v/--version	version information
  -d/--dump	dump rendered page to STDOUT
  --nopledge	disable pledge system call restrictions
  --nounveil	disable unveil file hierarchy restrictions

=head1 DESCRIPTION

B<Porcelain> is a text-based browser for gemini pages. It uses
OpenBSD's pledge and unveil technologies. The goal of Porcelain is to
be a "spec-preserving" gemini browser, meaning no support for
non-spec extension attempts (like favicons, metadata). Automatic opening
or inline display of non-gemini/text content is opt-in.

If you open a URL (either passed from CLI or opened in Porcelain),
Porcelain will determine the protocol for the connection and try to
obtain the resource. The 'gemini' and 'file' protocols are supported
by default. You can specify applications to open other protocols like
'https' in ~/.porcelain/open.conf.

If the protocol is supported, Porcelain will try to determine the MIME
type of the resource. MIME type text/gemini is supported natively.
Other MIME types like 'image/png' can be opened with external programs
specified in ~/.porcelain/open.conf.

If the MIME type is not known or cannot be determined, Porcelain will
try to find the extension (like '.gmi') in ~/.porcelain/open.conf.

=head1 KEYS

=over

=item H

Display browsing history.

=item o

Open a new link (prompts for link)

=item i

Show short info.

=item I

Show detailed info.

=item q

Quit the application.

=item Backspace/Ctrl-H

Go back in browsing history.

=item Ctrl-L

Go forward in browsing history.

=item n

Next matching text.

=item u

Go up in the domain hierarchy.

=item r

Go to root of the domain. 

=item R

Reload/refresh page.

=item Space/PageDown

Scroll down page-wise.

=item b/PageUp

Scroll up page-wise.

=item j/Down

Scroll down line-wise.

=item k/Up

Scroll up line-wise.

=item K/Home

Go to the beginning of the page.

=item J/End

Go to the end of the page.

=item v

Verification for server identity. Prompts for manual comparison, SHA-256 hash, or a third-party resource.

=item 1,2,3,...

Open link with that number.

=item /

Search page for text.

=item :

Command entry.

=back

=head1 FILES

~/.porcelain/open.conf

=cut
