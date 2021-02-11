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
#
#  NOT WORKING:
#  - gemini://playonbsd.com							-> returns "31 /"
#  - gemini://gemini.circumlunar.space/software/				-> 31 forwarding (not yet implemented)
#  - gemini://gmi.wikdict.com/							-> just returns 0
#  - gemini://translate.metalune.xyz/google/auto/en/das%20ist%20aber%20doof	-> returns "53 Proxy Requet Refused"

# TODO:
# - look up pledge and unveil examples and best practices
# - fix NOT WORKING sites above
# - keep testing with gemini://gemini.conman.org/test/torture/
# - implement a working pager (IO::Pager::Perl not working)
# - implement forwarding

use strict;
use warnings;
package Porcelain::Main;

#use IO::Pager::less;					# NOT WORKING
#use IO::Pager::Perl;					# 'q' key to quit not working; use Ctrl-C; NOT WORKING
require Net::SSLeay;					# p5-Net-SSLeay
Net::SSLeay->import(qw(sslcat));			# p5-Net-SSLeay
#$Net::SSLeay::trace = 5;				# enable for tracing details of p5-Net-SSLeay
use OpenBSD::Pledge;					# OpenBSD::Pledge(3p)
use OpenBSD::Unveil;					# OpenBSD::Unveil(3p)
use Term::ReadKey;					# for use with IO::Pager::Perl
#use URI;						# p5-URI - note: NO SUPPORT FOR 'gemini://'; could be used for http, gopher
use utf8;

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

# taken from sub sslcat in:
# /usr/local/libdata/perl5/site_perl/amd64-openbsd/Net/SSLeay.pm
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

Net::SSLeay::initialize();	# initialize ssl library once

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
unveil( "/usr/local/libdata/perl5/site_perl/IO/Pager", "rwx") || die "Unable to unveil: $!";
# ### LEAVE OUT ### unveil( "/usr/local/libdata/perl5/site_perl/URI", "r") || die "Unable to unveil: $!";
unveil( "/etc/resolv.conf", "r") || die "Unable to unveil: $!";
unveil( "/etc/termcap", "r") || die "Unable to unveil: $!";
unveil() || die "Unable to lock unveil: $!";

# setup
#my $t = IO::Pager::Perl->new();	# NOT WORKING

# process user input
my $url;
my $domain;

# validate input - is this correct gemini URI format?

$url = gem_uri("$ARGV[0]");
$domain = gem_host($url);

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
#
# ALTERNATIVES TO sslcat:
# 17:01 <solene>  printf "gemini://perso.pw/blog/index.gmi\r\n" | openssl s_client -tls1_2 -ign_eof -connect perso.pw:1965
#17:01 <solene> or printf "gemini://perso.pw/blog/index.gmi\r\n" | nc -T noverify -c perso.pw 1965
#($reply, $err, $server_cert) = sslcat($domain, 1965, $url);
($reply, $err, $server_cert)= sslcat_custom($domain, 1965, "$url\r\n");	# has to end with CRLF ('\r\n')
#$reply = `printf $url\r\n | openssl s_client -tls1_2 -ign_eof -connect $domain:1965`;
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

#print "Error code: $err\n";
#print "Server cert: $server_cert\n";
print $reply;
