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
# - limit size of history; can be configurable in whatever config approach is later chosen
# - implement subscribed option
# - allow theming (colors etc) via a config file?
# - see if some Perl modules may not be needed
# - review error handling - may not always need 'die'. Create a way to display warnings uniformly?
# - replace all uses of die with clean_die (?)
# - add option for "Content Warning" type use of preformatted text and alt text:
#	https://dragonscave.space/@devinprater/105782591455644854
# - implement logging messages, warnings, errors to file
# - add mouse support?!
# - implement 'N' to search backwards
# - implement '|' to pipe to external programs (like espeak)
# - update README, ideally as output from pod2usage
# - pledge after reading config; can get rid of rpath?? see https://marc.info/?l=openbsd-ports&m=161417431131260&w=2
# - remove non-printable terminal control characters; see https://lists.orbitalfox.eu/archives/gemini/2020/000390.html
# - implement TOFU recommendations:gemini://drewdevault.com/2020/09/21/Gemini-TOFU.gmi - PARTIALLY; NEED TEMP PERMISSIONS
# - fix supporting MIME text/plain: query: gemini://gemini.thebackupbox.net/IRIcheck
# - gemini://gemini.thebackupbox.net/IRIcheck: strip non-printable characters from $meta - displays: ": bmit something and I'll tell you if it is an IRI."
# - fix newline in SYNOPSIS to separate different syntax
# - fix $reflow_text, $update_viewport mechanics in sub page_nav to keep viewport at stable position
#   (currently viewport moves down when increasing COLs, and up when decreasing)
# - add timeout to loading resources
# - ?add test suite?
# - add config option to mandate TLS >= 1.3
#   see specification (as of 2021-03-09): "Clients who wish to be "ahead of the curve MAY refuse to connect to servers using TLS version 1.2 or lower."
#   => test then what domains break
# - store protocol version with my $rv = Net::SSLeay::get_version($ssl); => can use to check TLSv1.3
# - fix underscore in front of link, header , see gemini://astrobotany.mozz.us
#	gemini://palm93.com/2021-03-07_Midgard.gmi 
# - implement geminispace search, like 's' in gemini://gmn.clttr.info/cgmnlm.gmi ?
# - c_prompt_str - enable backspace, arrow key navigation, cursor?
# - use newpad with $max_vrows and $max_vcols rather than simple window for the display
# - make sure not using getstr, inchstr, instr because of potential for buffer overflow attacks; see https://metacpan.org/pod/Curses
# - make sure to escape dots and other RE chars in all uses of grep
# - add the server response header (e.g. "20 text/gemini; lang=en-US;charset=utf-8") to Info page
# - other page to test with temporary certs: gemini://bestiya.duckdns.org/
# - check why cert mismatch with gemini://skyjake.fi/lagrange/ when following link from other domain (hyperborea.org)
# - add IRI support (see mailing list)
# - implement a way to preview links before following them
# - fix glitch of line continuation showing the internal leading characters e.g. gemini://thfr.info/gemini/modified-trust-verify.gmi list items when scrolling past initial line
# - remove need for rpath from sslcat_porcelain by preloading whatever is needed?
# - check POD documentation with podchecker(1)
# - go through '$ perldoc perlpodstyle'
# - enable --conf/-c config file support; see GetOptions
# - implement '.' to see raw page (like Elpher, apparently; see https://www.youtube.com/watch?v=Dy4IWoGbm6g)
# - implement Tab key to select links in page
# - clean up module usage between script and Porcelain modules

use strict;
use warnings;
use feature 'unicode_strings';
package Porcelain::Main;

$main::VERSION = "0.1-alpha";	# used by Getopt::Long auto_version

### Modules ###
use FindBin;
use lib "$FindBin::Bin/../lib";

use Cwd qw(abs_path);
use File::Spec;			# for splitpath, canonpath
use Getopt::Long qw(:config bundling require_order );
use Pod::Usage;
use Porcelain::Crypto;	# TODO: really needed in Porcelain::Main ??
use Porcelain::CursesUI;	# TODO: really needed in Porcelain::Main ??
use Porcelain::Format;	# TODO: really needed in Porcelain::Main ??
use Porcelain::Nav;	# TODO: really needed in Porcelain::Main ??
use Porcelain::Porcelain;	# TODO: really needed in Porcelain::Main ??
use Porcelain::RandomArt;	# TODO: really needed in Porcelain::Main ??
use Porcelain::RequestHandler;

use open ':encoding(UTF-8)';

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
our $searchstr = '';		# search string
our @searchlns;		# lines with matches for search 
my $r;		# responses to prompts
our $max_vrows = 1024 * 1024;	# max virtual rows used in curses pads
our $max_vcols = 1024;	# maximum virtual columns used in curses pads

my $redirect_count = 0;
my $redirect_max = 5;	# TODO: allow setting this in the config

my $porcelain_dir = $ENV{'HOME'} . "/.porcelain";
our $idents_dir = $porcelain_dir . "/idents";

my $podfile = "$FindBin::Bin/../pod/Porcelain.pod";

my @bookmarks;
my @client_certs;
my @config;
my @history;
our @known_hosts;
my @subscriptions;
my %text_stores = (
	"bookmarks"		=> \@bookmarks,
	"client_certs"		=> \@client_certs,
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
sub gem_host {
	my $input = $_[0];
	my $out = substr $input, 9;	# remove leading 'gemini://'
	$out =~ s|/.*||;
	return $out;
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
		"man|m"		=> sub { pod2usage(-input => $podfile, -exitval => 0, -verbose => 2) },
		"pledge!"	=> \$opt_pledge,	# --nopledge disables
		"file|f=s"	=> \$file_in,
		"unveil!"	=> \$opt_unveil,	# --nounveil disables
		"version|v"	=> sub { Getopt::Long::VersionMessage() },
);

### Set up and read config, known_hosts, bookmarks, history, open_with ###
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

if (-f $porcelain_dir . '/open.conf') {
	%open_with = readconf($porcelain_dir . '/open.conf');
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

### Inits ###
init_cursesui unless $opt_dump;
init_crypto;

# Make pod2usage text usable in about:pod/about:man
open my $fh, '>', \my $text;
pod2usage(-input => $podfile, -output => $fh, -exitval => 'NOEXIT', -verbose => 2);
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
	#	sslcat_porcelain:		rpath inet dns
	#	system (for external programs)	exec proc
	#	Curses				tty
	# prot_exec is needed, as sometimes abort trap gets triggered when loading pages without it - TODO: investigate why
	pledge(qw ( exec tty cpath rpath wpath inet dns proc prot_exec ) ) || die "Unable to pledge: $!";
}

### Request loop ###
init_request \@pod, \@bookmarks, \@history, \@subscriptions, \@client_certs;
# TODO: empty/undef all these arrays after init_request?
while (defined $rq_addr) {	# $rq_addr must be fully qualified: '<protocol>:...' or '-'
	$rq_addr = request $rq_addr, \@stdin;
}
clean_exit "Bye...";
