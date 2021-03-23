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
# - add Copyright/license to modules
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
# - remove need for rpath from sslcat_porcelain by preloading whatever is needed?
# - implement fork+exec
# - use sub lines more consistently
# - check POD documentation with podchecker(1)
# - go through '$ perldoc perlpodstyle'
# - enable --conf/-c config file support; see GetOptions

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
use Cwd qw(abs_path);
use DateTime;
use Encode qw(encode decode);
use File::Spec;
use Getopt::Long qw(:config bundling require_order ); #auto_version auto_help);	# TODO: all of those needed?
use List::Util qw(min max);
use Net::SSLeay;
use Pod::Usage;
use Porcelain::Crypto;	# TODO: really needed in Porcelain::Main ??
use Porcelain::CursesUI;	# TODO: really needed in Porcelain::Main ??
use Porcelain::Format;	# TODO: really needed in Porcelain::Main ??
use Porcelain::Nav;	# TODO: really needed in Porcelain::Main ??
use Porcelain::Porcelain;	# TODO: really needed in Porcelain::Main ??
use Porcelain::RandomArt;	# TODO: really needed in Porcelain::Main ??
use Porcelain::RequestHandler;

use open ':encoding(UTF-8)';
use subs qw(open_about);

### Variables ###
my $rq_addr;		# address of the request (URI, IRI, local, internal)
my @stdin;		# only used if pipe/STDIN are used
my ($vol, $dir, $fil);	# for local file location
our $host_cert;
our @back_history;
our @forward_history;
our %open_with;
our @links;		# array containing links in the pages
our @last_links;		# array list from last page, for next/previous (see gemini://gemini.circumlunar.space/users/solderpunk/gemlog/gemini-client-navigation.gmi)
our $chosen_link;	# holds a number of what link was chosen, refers to @last_links entries
our $win;
our $title_win;
our $status_win;
our $searchstr = '';		# search string
our @searchlns;		# lines with matches for search 
my $r;		# responses to prompts
our $max_vrows = 1024 * 1024;	# max virtual rows used in curses pads
our $max_vcols = 1024;	# maximum virtual columns used in curses pads

my $redirect_count = 0;
my $redirect_max = 5;	# TODO: allow setting this in the config

my $porcelain_dir = $ENV{'HOME'} . "/.porcelain";
our $idents_dir = $porcelain_dir . "/idents";

my @bookmarks;
my @config;
my @history;
our @known_hosts;
my @subscriptions;
my %text_stores = (
	"bookmarks"		=> \@bookmarks,
	"config"		=> \@config,
	"history"		=> \@history,
	"known_hosts"		=> \@known_hosts,
	"subscriptions"		=> \@subscriptions,
);
our $hosts_file = $porcelain_dir . "/known_hosts";	# obsolete; still used in Crypto.pm.

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

sub open_about {	# resource, e.g. 'about:history'
	my $about_page = substr $_[0], 6;	# remove leading 'about:'
	my @about_cont;				# content for the about page
	if ($about_page eq "history") {
		@about_cont = @back_history;
		unshift @about_cont, ("History", $rq_addr . " $rq_addr <-- CURRENT URL");
	} elsif ($about_page eq "bookmarks") {
	} elsif ($about_page eq "subscriptions") {
	} else {
		die "Invalid about address: $_[0]";
	}
	# TODO: move this formatting into Format.pm
	preformat_linklist \@about_cont;
	return page_nav \@about_cont;
}

sub open_file {		# opens a local file
	# TODO: get file MIME type with 'file -bi' command
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

	undef $host_cert;
	(my $raw_response, my $err, $host_cert)= sslcat_porcelain($domain, 1965, "$resource\r\n", $certpath, $keypath);	# has to end with CRLF ('\r\n')
	if ($err) {
		die "error while trying to establish TLS connection";
	}
	if (not defined $host_cert) {
		die "no certificate received from server";
	}
	# Transform $host_cert into usable format for Crypt::OpenSSL::X509
	$host_cert = Crypt::OpenSSL::X509->new_from_string(Net::SSLeay::PEM_get_string_X509($host_cert));
	if ($r = validate_cert($host_cert, $domain)) {
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
	$rq_addr =~ s/[^[:print:]]//g;
	$meta =~ s/[^[:print:]]//g;
	if ($status != 3) {
		$redirect_count = 0;	# reset the $redirect_count
	}
	if ($status == 1) {		# 1x: INPUT
		# TODO: 11: SENSITIVE INPUT (e.g. password entry) - don't echo
		$r = c_prompt_str $meta . ": ";	# TODO: other separator? check if $meta includes ':' at the end?
		$r = uri_escape $r;
		$rq_addr = $rq_addr . "?" . $r;		# query component is separated from the path by '?'.
		return;
	} elsif ($status == 2) {	# 2x: SUCCESS
		# <META>: MIME media type (apply to response body), DEFAULT TO "text/gemini; charset=utf-8"
		# TODO: process language, encoding

		# is content text/gemini or something else?
		# TODO: support text/plain
		if (not $meta =~ m{^text/gemini} && not $meta =~ m{^\s*$}) {
			# check if extension in %open_with
			my $f_ext = $rq_addr =~ s/.*\././r;
			if (defined $open_with{$f_ext}) {	# TODO: check MIME type primarily; suffix as fallback
				open(my $fh, '|-', "$open_with{$f_ext}") or c_warn "Error opening pipe to ogg123: $!";
				print $fh join("\n", @response) or clean_exit "error writing to pipe";
				close $fh;
			} else {
				$r = '';
				until ($r =~ /^[YyNn]$/) {
					$r = c_prompt_ch "Unknown MIME type in resource $rq_addr. Download? [y/n]";
				}
				if ($r =~ /^[Yy]$/) {
					downloader($rq_addr, join("\n", @response)) && c_warn "Download of $rq_addr failed!";
				}
			}
			if (scalar(@back_history) > 0) {
				$rq_addr = pop @back_history;
			} else {
				clean_exit "unable to open $rq_addr";
			}
		}
		return page_nav \@response
	} elsif ($status == 3) {	# 3x: REDIRECT
		# 30: TEMPORARY, 31: PERMANENT: indexers, aggregators should update to the new URL, update bookmarks
		chomp $rq_addr;
		$redirect_count++;
		if ($redirect_count > $redirect_max) {
			die "ERROR: more than maximum number of $redirect_max redirects";
		}
		# TODO: allow option to ask for confirmation before all redirects
		$rq_addr = url2absolute($rq_addr, $meta);
		if (not $rq_addr =~ m{^gemini://}) {
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
			$rq_addr = c_prompt_str("url: gemini://");	# TODO: allow relative links??
			$rq_addr = 'gemini://' . $rq_addr;
			return;
		} elsif ($r =~ /^[Bb]$/) {
			if (scalar(@back_history) > 0) {
				$rq_addr = pop @back_history;
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
			$rq_addr = c_prompt_str("url: gemini://");	# TODO: allow relative links??
			$rq_addr = 'gemini://' . $rq_addr;
			return;
		} elsif ($r =~ /^[Bb]$/) {
			if (scalar(@back_history) > 0) {
				$rq_addr = pop @back_history;
				return;
			} else {
				clean_exit "error invalid url: $rq_addr";
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
			$r = c_prompt_ch "Identity has been requested, but none found. Create new certificate for $rq_addr? [Y/n]";
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
			open_gemini($rq_addr, $crt_key . ".crt", $crt_key . ".key");
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
		$rq_addr = pop @back_history;
	} else {
		if ($_[0] eq 'file') {
			open_file $rq_addr;
		} else {
			clean_exit "Not implemented.";
		}
	}
}

sub open_url {
	# TODO: read from %open_with, open with 'gemini' protocol or other modality
	# TODO: then determine the resource MIME type and call appropriate resource sub
	c_statusline "Loading $rq_addr ...";
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

### Process CLI Options ###
my $configfile = $porcelain_dir . "/porcelain.conf";
my $opt_dump =		'';	# dump page to STDOUT
my $opt_pledge =	'';	# use pledge
my $file_in;			# local file; STDIN via '-'
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
		"file|f=s"	=> \$file_in,
		"unveil!"	=> \$opt_unveil,	# --nounveil disables
		"version|v"	=> sub { Getopt::Long::VersionMessage() },
);

### Set up and read config, known_hosts, bookmarks, history ###
if (! -d $porcelain_dir) {
	mkdir $porcelain_dir || die "Unable to create $porcelain_dir";
}
if (! -d $idents_dir) {
	mkdir $idents_dir || die "Unable to create $idents_dir";
}

foreach (keys %text_stores) {
	my $store_key = $_;
	my $store_file = $porcelain_dir . "/" . $store_key;
	if (-f $store_file) {
		@{$text_stores{$store_key}} = readtext $store_file;
	}
}

### Determine Starting Address ###
if (not defined $file_in) {		# most common case - no local file passed
	if (scalar @ARGV == 0) {	# no address and no file passed => open default address
		$rq_addr = "gemini://gemini.circumlunar.space/";	# TODO: about:new? Allow setting home page? Resume session?
	} else {
		if (not $ARGV[0] =~ m{:}) {		# TODO: refine to allow specifying port without specifying domain: "thfr.info:1965/"
			$rq_addr = 'gemini://' . $ARGV[0];
		} else {
			$rq_addr = "$ARGV[0]";
		}
	}
} else {
	if ($file_in ne "-") {
		die "No such file: $file_in" unless (-f $file_in);		# ensure $file_in is a plain file
		$rq_addr = "file:" . abs_path(File::Spec->canonpath($file_in));	# the file URI scheme 'file:...' is only used internally
		($vol, $dir, $fil) = File::Spec->splitpath(abs_path(File::Spec->canonpath($file_in)));
	} else {
		$rq_addr = "-";		# TODO: redundant? just pass @stdin instead of rq_addr?
		while (<>) {
			chomp;
			push @stdin, $_;
		}
	}
}

### Init: SSLeay, Curses, about pages ###
Net::SSLeay::initialize();	# initialize ssl library once

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

# Make pod2usage text usable in about:pod/about:man
open my $fh, '>', \my $text;
pod2usage(-output => $fh, -exitval => 'NOEXIT', -verbose => 2);
close $fh;
my @pod = split "\n", $text;
undef $text;

### Secure: unveil, pledge ###
if ($opt_unveil) {
	use OpenBSD::Unveil;
	# TODO: tighten unveil later
	unveil("$ENV{'HOME'}/Downloads", "rwc") || die "Unable to unveil: $!";	# TODO: remove rc?
	unveil("/usr/local/libdata/perl5/site_perl/amd64-openbsd/auto/Net/SSLeay", "r") || die "Unable to unveil: $!";
	unveil("/usr/libdata/perl5", "r") || die "Unable to unveil: $!";	# TODO: tighten this one more
	unveil("/etc/resolv.conf", "r") || die "Unable to unveil: $!";		# needed by sslcat_porcelain(r)
	unveil("/etc/termcap", "r") || die "Unable to unveil: $!";
	unveil("/usr/local/lib/libmagic.so.5.0", "r") || die "Unable to unveil: $!";	# TODO: find the version number and make this resilient to version updates
	unveil("/usr/local/share/misc/magic.mgc", "r") || die "Unable to unveil: $!";
	unveil("$ENV{'HOME'}/.porcelain", "rwc") || die "Unable to unveil: $!";	# TODO: remove rc?
	if (-f $porcelain_dir . '/open.conf') {
		%open_with = readconf($porcelain_dir . '/open.conf');
	}
	if (defined $file_in && $file_in ne "-") {
		unveil($dir, "r") || die "Unable to unveil: $!";
	}
	for my $v (values %open_with) {
		# TODO: implement paths with whitespace, eg. in quotes? like: "/home/user/these programs/launch"
		my $unveil_bin = $v =~ s/\s.*$//r;	# this way parameters to the programs will not mess up the call.
		unveil($unveil_bin, "x") || die "Unable to unveil: $!";
	}
	unveil() || die "Unable to lock unveil: $!";
}
if ($opt_pledge) {
	use OpenBSD::Pledge;
	# TODO: tighten pledge later, e.g. remove wpath rpath after config is read
	# TODO: remove cpath by creating the files with the installer or before unveil/pledge?
	# TODO: can tty pledge be removed after Curses has been initialized?
	#	sslcat_porcelain:		rpath inet dns
	#	system (for external programs)	exec proc
	#	Curses				tty
	# prot_exec is needed, as sometimes abort trap gets triggered when loading pages without it
	pledge(qw ( exec tty cpath rpath wpath inet dns proc prot_exec ) ) || die "Unable to pledge: $!";
}

### Request loop ###

init_request \@pod, \@bookmarks, \@history, \@subscriptions;
# TODO: empty/undef all these arrays after init_request?
while (defined $rq_addr) {	# $rq_addr must be fully qualified: '<protocol>:...' or '-'
	$rq_addr = request $rq_addr, \@stdin;
}

clean_exit "Bye...";

__END__

=head1 NAME

B<Porcelain> - a gemini browser

=head1 SYNOPSIS

porcelain [-hmv]

porcelain [-d] [--nopledge] [--nounveil] [url|-f file]

Options:
  -h/--help	brief help message
  -m/--man	full documentation
  -v/--version	version information
  -d/--dump	dump rendered page to standard output
  --nopledge	disable pledge system call restrictions
  --nounveil	disable unveil file hierarchy restrictions
  -f/--file	open file (use '-' for standard input)

=head1 DESCRIPTION

B<Porcelain> is a text-based browser for gemini pages. It uses
OpenBSD's pledge and unveil technologies. The goal of B<Porcelain> is to
be a "spec-preserving" gemini browser, meaning no support for
non-spec extension attempts (like favicons, metadata). Automatic opening
or inline display of non-gemini/text content is opt-in.

If you open a URL (either passed from CLI or opened in B<Porcelain>),
B<Porcelain> will determine the protocol for the connection and try to
obtain the resource. The 'gemini' protocols are supported
by default. You can specify applications to open other protocols like
'https' in ~/.porcelain/open.conf.

If the protocol is supported, B<Porcelain> will try to determine the
MIME type of the resource. MIME type text/gemini is supported natively.
Other MIME types like 'image/png' can be opened with external programs
specified in ~/.porcelain/open.conf.

If the MIME type is not known or cannot be determined, B<Porcelain> will
try to find the extension (like '.gmi') in ~/.porcelain/open.conf.

If the --file/-f option is used, B<Porcelain> will unveil the directory
containing the file (including all subdirectories).

=head2 KEYS

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

=head1 EXIT STATUS

=head1 CONFIGURATION

=head1 DEPENDENCIES

=head1 FILES

~/.porcelain/known_hosts

~/.porcelain/open.conf

=head1 BUGS AND LIMITATIONS

=head1 AUTHOR

=head1 LICENSE AND COPYRIGHT

=head1 DISCLAIMER OF WARRANTY

=cut
