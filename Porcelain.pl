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

use strict;
use warnings;
package Porcelain::Main;

use IO::Pager::Perl;					# 'q' key to quit not working; use Ctrl-C
use Net::SSLeay qw(sslcat);				# p5-Net-SSLeay
use OpenBSD::Pledge;					# OpenBSD::Pledge(3p)
use OpenBSD::Unveil;					# OpenBSD::Unveil(3p)
use Term::ReadKey;					# for use with IO::Pager::Perl
#use URI;						# p5-URI - note: NO SUPPORT FOR 'gemini://'; could be used for http, gopher

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

# TODO: tighten pledge later
# stdio promise is always implied by OpenBSD::Pledge
# needed promises:
#	sslcat:			rpath inet dns
# 	IO::Pager::Perl:	tty
# 	URI (no support for 'gemini://':			prot_exec (for re engine)
pledge(qw ( rpath inet dns tty unveil ) ) || die "Unable to pledge: $!";
#pledge(qw ( rpath inet dns tty unix exec tmppath proc route wpath cpath dpath fattr chown getpw sendfd recvfd tape prot_exec settime ps vminfo id pf route wroute mcast unveil ) ) || die "Unable to pledge: $!";
#pledge(qw ( rpath inet dns tty unix exec tmppath proc route wpath cpath dpath fattr ps vminfo id pf route wroute mcast unveil ) ) || die "Unable to pledge: $!";

# TODO: tighten unveil later
# needed paths for sslcat: /etc/resolv.conf (r)
# needed paths for IO::Pager::Perl: /etc/termcap (r)
unveil( "$ENV{'HOME'}/Downloads", "rw") || die "Unable to unveil: $!";
unveil( "/usr/local/libdata/perl5/site_perl/amd64-openbsd/auto/Net/SSLeay", "r") || die "Unable to unveil: $!";
unveil( "/usr/local/libdata/perl5/site_perl/URI", "r") || die "Unable to unveil: $!";
#unveil( "/usr/local/libdata/", "rx") || die "Unable to unveil: $!";
#unveil( "/usr/libdata/", "rx") || die "Unable to unveil: $!";
#unveil( "/usr/bin/host", "rx") || die "Unable to unveil: $!";
unveil( "/etc/resolv.conf", "r") || die "Unable to unveil: $!";
unveil( "/etc/termcap", "r") || die "Unable to unveil: $!";
unveil() || die "Unable to lock unveil: $!";

# setup
my $t = IO::Pager::Perl->new();

# process user input
my $url;
my $domain;

# validate input - is this correct gemini URI format?

$url = gem_uri("gemini://gemini.circumlunar.space/docs/specification.gmi");
$domain = gem_host($url);

print "ARGV0: $ARGV[0]\n";
print "URL: $url, Domain: $domain\n";
print "Press 'Return' to continue...\n";
my $input = <STDIN>;	# alternatively for any key with: use Term::ReadKey;

# sslcat request
my $reply;
my $err;
my $server_cert;

# response variables
my $body;
my $header;
my $status;
my $meta;

# TODO: avoid sslcat if viewing local file
($reply, $err, $server_cert) = sslcat("gemini.circumlunar.space", 1965, "gemini://gemini.circumlunar.space/docs/specification.gmi");
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
# Response Bodies
# ===============
#
# Raw text or binary content. Server closes connection after the final byte. No "end of response" signal.
# Only after SUCCESS (2x) header.

# process basic reply elements: header (status, meta), body (if applicable)
# divide $reply into $header and $body
# divide $header into $status and $meta
# process language

# transform response body
# - link lines into links
# - optionally: autorecognize types of links, e.g. .png, .jpg, .mp4, .ogg, and offer to open (inline vs. dedicated program?)
# - compose relative links into whole links
# - style links according to same domain vs. other gemini domain vs. http[,s] vs. gopher
# - style headers 1-3
# - style bullet points
# - style preformatted mode
# - style quote lines

$t->add_text( $reply );

# display page
$t->more();		# 'q' key to quit not working; use Ctrl-C
